import { useEffect, useRef, useState } from 'react';
import { router, useNavigation } from 'expo-router';

import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import type { ItemWithContext } from '@/db/types';
import { strings } from '@/i18n/strings';
import { useDatabase, useRepositories } from '@/providers/DatabaseProvider';
import { useToast } from '@/providers/ToastProvider';
import { rememberPlace } from '@/services/places/recentPlaces';
import { logError, logEvent } from '@/services/telemetry';
import type { PickedPlace } from '@/ui/components/PlacePicker';
import { describeError } from '@/ui/errors';
import { haptics } from '@/ui/haptics';
import {
  afterFiling,
  attemptMove,
  attemptUndo,
  containerLabel,
  moveFailedMessage,
  movedElsewhereMessage,
  movedMessage,
  undoFailedMessage,
  type RunMoveResult,
} from '@/ui/item/moveFlow';
import type { MoveResult } from '@/ui/navigation';
import { abandonResult, deliverResult } from '@/ui/routeResult';

export interface UseMoveOptions {
  /** The item as the screen last read it; `null` while loading or once it is gone. */
  item: ItemWithContext | null;
  /**
   * The opener's `routeResult` request, answered with a `MoveResult` (in a
   * filing run, a `RunMoveResult`).
   */
  request?: string;
  /** Part of a filing run from the item screen (`filing=1`). */
  filing: boolean;
}

/** Why the last pick did not move anything. */
export interface MoveNotice {
  kind: 'gone' | 'movedElsewhere' | 'failed';
  message: string;
}

export interface MoveState {
  /** The item as last known; re-read when another phone moved it first. */
  item: ItemWithContext | null;
  /** The container being moved into, which shows a spinner; the picker is locked meanwhile. */
  busyId: string | null;
  notice: MoveNotice | null;
  pick: (place: PickedPlace) => Promise<void>;
}

/** The newer of two reads of the same item. */
function newer(a: ItemWithContext | null, b: ItemWithContext | null): ItemWithContext | null {
  if (!a || !b || a.id !== b.id) return a ?? b;
  return b.updatedAt > a.updatedAt ? b : a;
}

/**
 * Moving or filing one item: the desk's `chooseMove`/`afterMove`
 * (`home-server/web/app.js:1517-1592`) on the phone.
 *
 * A pick writes with the item's lock. Success closes the sheet, hands the
 * opener a `MoveResult` and says where it went in a toast with Undo, so the
 * person stays where they were instead of being sent into the destination
 * container. A failure keeps the sheet open with a notice and writes
 * nothing more: an item deleted elsewhere is said to be gone (the household
 * answers `null`, which used to read as success), and an item another phone
 * moved first shows where it is now, with "Here now" following it.
 */
export function useMove({ item, request, filing }: UseMoveOptions): MoveState {
  const repos = useRepositories();
  const { invalidate } = useDatabase();
  const navigation = useNavigation();
  const toast = useToast();
  const [reread, setReread] = useState<ItemWithContext | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [notice, setNotice] = useState<MoveNotice | null>(null);
  // The double-submit guard; state would let a second tap in before re-render.
  const busyRef = useRef(false);

  const current = newer(item, reread);

  // Closing without a pick answers the opener with nothing. After a delivery
  // this does nothing, so it is safe on every unmount.
  useEffect(() => () => abandonResult(request), [request]);

  async function undo(move: MoveResult) {
    const outcome = await attemptUndo(repos.items, move);
    if (outcome.kind === 'undone') {
      logEvent('item_move_undone');
      invalidate();
      haptics.undo();
      toast.show({ message: strings.move.undone });
      return;
    }
    if (outcome.kind === 'conflict') haptics.warning();
    else haptics.error();
    logError(
      'item_move_undo_failed',
      outcome.kind === 'failed'
        ? { outcome: outcome.kind, errorClass: describeError(outcome.cause, 'move').kind }
        : { outcome: outcome.kind },
    );
    toast.show({ message: undoFailedMessage(outcome), tone: 'error' });
    // Whatever stopped it, the screen in front should show where the item really is.
    invalidate();
  }

  async function pick(place: PickedPlace) {
    // The drop zone is not offered when moving; filing out of it is the point.
    if (place.kind !== 'container' || !current || busyRef.current) return;
    const before = current;
    const target = place.option;
    if (target.id === before.containerId) return;

    busyRef.current = true;
    setBusyId(target.id);
    setNotice(null);
    const outcome = await attemptMove(repos.items, before, target.id);

    if (outcome.kind === 'moved') {
      const name = before.name;
      const fromDropZone = before.containerId === DROP_ZONE_CONTAINER_ID;
      const move: RunMoveResult = {
        itemId: before.id,
        from: before.containerId,
        to: target.id,
        updatedAt: outcome.updatedAt,
      };
      logEvent('item_moved');
      haptics.success();
      void rememberPlace(target.id);
      // A filing step reads the drop zone once, while the spinner still
      // shows: the toast below and the run's next item both come from it.
      let moreWaiting: boolean | null = null;
      if (filing && fromDropZone) {
        const after = await afterFiling(repos.items, before.id);
        move.waiting = after.waiting;
        moreWaiting = after.moreWaiting;
      }
      deliverResult(request, move);
      // Back first: the closing sheet is no longer focused, so the refresh
      // does not redraw it with the item already "Here now" in its new place.
      // Not if it was closed while writing (the header Cancel): going back
      // then would pop the item screen underneath, or switch the tab bar
      // from the Drop zone to Home. The toast and its Undo show either way.
      if (navigation.isFocused()) router.back();
      invalidate();
      toast.show({
        message: movedMessage({
          fromDropZone,
          filing,
          moreWaiting,
          container: containerLabel(target),
          space: target.spaceName,
        }),
        action: {
          label: strings.common.undo,
          accessibilityLabel: name ? strings.move.undoA11y(name) : strings.move.undoA11yUnnamed,
          onPress: () => void undo(move),
        },
      });
      return;
    }

    busyRef.current = false;
    setBusyId(null);
    // Nothing was written, so nothing is invalidated: the screens underneath
    // re-read when they are back in front.
    if (outcome.kind === 'gone') {
      setNotice({ kind: 'gone', message: strings.move.gone });
      haptics.error();
    } else if (outcome.kind === 'movedElsewhere') {
      setReread(outcome.fresh);
      setNotice({ kind: 'movedElsewhere', message: movedElsewhereMessage(outcome.fresh) });
      haptics.warning();
    } else {
      logError('item_move_failed', { errorClass: describeError(outcome.cause, 'move').kind });
      setNotice({ kind: 'failed', message: moveFailedMessage(outcome.cause) });
      haptics.error();
    }
  }

  return { item: current, busyId, notice, pick };
}
