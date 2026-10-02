import type { ReactElement } from 'react';
import { StyleSheet, View } from 'react-native';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';

import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import { useInventoryQuery } from '@/hooks/useInventoryQuery';
import { useMove } from '@/hooks/useMove';
import { strings } from '@/i18n/strings';
import { useRepositories } from '@/providers/DatabaseProvider';
import { Banner } from '@/ui/components/Banner';
import { ErrorState } from '@/ui/components/ErrorState';
import { PlacePicker } from '@/ui/components/PlacePicker';
import { ScreenFrame } from '@/ui/components/ScreenFrame';
import { Skeleton } from '@/ui/components/Skeleton';
import { GUTTER, space } from '@/ui/theme';

function sheetTitle(name: string, filing: boolean): string {
  if (filing) return name ? strings.move.titleFile(name) : strings.move.titleFileUnnamed;
  return name ? strings.move.titleMove(name) : strings.move.titleMoveUnnamed;
}

/**
 * Move or File one item (spec §5.12): the one place picker, grouped by space
 * and filterable, with the item's own container shown as "Here now" and
 * unavailable, so "moving" it where it already is cannot happen (§15.8).
 *
 * Opened from the item screen ("Move…", "File it…") and from the Drop zone's
 * "File…", usually with a `request` that the opener awaits; the toast with
 * Undo comes from here either way, and the sheet always closes back to where
 * it was opened (it used to replace itself with the destination container).
 * `filing=1` marks a filing run from the item screen, which goes on to the
 * next waiting item, so the toast says "Next one."
 */
export default function MoveItemScreen() {
  const params = useLocalSearchParams<{ id: string; filing?: string; request?: string }>();
  const { id } = params;
  const filing = params.filing === '1';
  const repos = useRepositories();
  const router = useRouter();

  const itemQuery = useInventoryQuery(() => repos.items.getById(id), `item:${id}`);
  // Only a filing run needs the drop zone, to know whether another item waits.
  const dropZone = useInventoryQuery(
    () => (filing ? repos.items.listUnsorted() : Promise.resolve(null)),
    filing ? 'drop-zone' : 'drop-zone:unused',
  );
  // Until the list has loaded, assume the run goes on; the item screen
  // decides for itself once the move is done.
  const moreWaiting = dropZone.data?.some((waiting) => waiting.id !== id) ?? true;

  const move = useMove({ item: itemQuery.data, request: params.request, filing, moreWaiting });
  const item = move.item;
  const inDropZone = item?.containerId === DROP_ZONE_CONTAINER_ID;

  let body: ReactElement;
  if (item === null) {
    if (itemQuery.cause) {
      body = <ErrorState cause={itemQuery.cause} subject="item" onRetry={itemQuery.reload} />;
    } else if (itemQuery.loading) {
      body = (
        <View style={styles.skeleton}>
          <Skeleton variant="options" />
        </View>
      );
    } else {
      // Deleted on another phone before the sheet opened: say so, write nothing.
      body = (
        <ErrorState
          cause={null}
          subject="item"
          secondary={{ label: strings.common.close, onPress: () => router.back() }}
        />
      );
    }
  } else {
    body = (
      <>
        {/* Above the picker rather than in its list, so it is seen however far the list was scrolled. */}
        {move.notice ? (
          <View style={styles.notice}>
            <Banner
              tone="warning"
              message={move.notice.message}
              live="assertive"
              action={
                move.notice.kind === 'gone'
                  ? { label: strings.common.close, onPress: () => router.back() }
                  : undefined
              }
            />
          </View>
        ) : null}
        <PlacePicker
          mode={inDropZone ? 'file' : 'move'}
          currentContainerId={item.containerId}
          busyId={move.busyId}
          onPick={move.pick}
        />
      </>
    );
  }

  return (
    <ScreenFrame kind="modal">
      <Stack.Screen options={{ title: item ? sheetTitle(item.name, inDropZone || filing) : '' }} />
      {body}
    </ScreenFrame>
  );
}

const styles = StyleSheet.create({
  skeleton: {
    paddingHorizontal: GUTTER,
    paddingTop: space.md,
  },
  notice: {
    paddingHorizontal: GUTTER,
    paddingTop: space.md,
  },
});
