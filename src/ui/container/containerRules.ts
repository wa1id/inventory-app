import { strings } from '@/i18n/strings';
import type { ScanOutcome } from '@/repositories/qr';
import { describeError } from '@/ui/errors';

/**
 * The rules behind the container screen, its QR label and sticker linking,
 * kept pure (no React Native) so they are tested in Node.
 */

interface Named {
  name: string | null;
  shortCode: string;
}

/**
 * What a sentence calls a container: its name, or else the code on its label,
 * which is what is written on the box.
 */
export function labelOf(container: Named): string {
  return container.name?.trim() ? container.name : container.shortCode;
}

/** "Box", "Drawer"…; an unknown stored type reads as "Container". */
export function typeNameOf(visualType: string): string {
  return strings.entities.typeNames[visualType] ?? strings.entities.typeNames.other ?? visualType;
}

/** The container's title: its name, or "Unnamed box" (the desk's container view). */
export function titleOf(container: { name: string | null; visualType: string }): string {
  return container.name?.trim()
    ? container.name
    : strings.entities.unnamedContainer(typeNameOf(container.visualType));
}

function byContents(
  a: { name: string; createdAt: number },
  b: { name: string; createdAt: number },
): number {
  const nameA = a.name.trim();
  const nameB = b.name.trim();
  if (nameA && nameB) {
    return nameA.localeCompare(nameB, 'en', { sensitivity: 'base' }) || a.createdAt - b.createdAt;
  }
  if (nameA) return -1;
  if (nameB) return 1;
  return a.createdAt - b.createdAt;
}

/**
 * What is in a box, in the order people look for it: by name, ignoring case
 * and accents (desk order), with the items still waiting for a name last, in
 * the order they were photographed. The repository returns newest first,
 * which made a full box hard to scan.
 */
export function sortContents<T extends { name: string; createdAt: number }>(
  items: readonly T[],
): T[] {
  return [...items].sort(byContents);
}

/** How recently an item must have been added to count as just arrived from Add. */
export const FRESH_ARRIVAL_MS = 10_000;

/**
 * Whether a row has just arrived (from Add or the camera) and should be
 * picked out for a moment. Either side of `now`: a paired phone's clock and
 * the home server's are never quite the same.
 */
export function isFreshArrival(createdAt: number, now: number): boolean {
  return Math.abs(now - createdAt) < FRESH_ARRIVAL_MS;
}

export interface ConfirmCopy {
  title: string;
  body: string;
  confirmLabel: string;
}

/** What scanning a sticker for a container leads to. */
export type StickerPlan =
  | { kind: 'invalid' }
  /** It already opens this container: nothing to write. */
  | { kind: 'already' }
  /** Bind `token` to the container, asking first when `confirm` is set. */
  | { kind: 'link'; token: string; confirm: ConfirmCopy | null };

/**
 * Decides what a scanned sticker does to `target`.
 *
 * A new sticker links straight away unless the container already has a
 * label, whose old sticker would stop working. A sticker that opens another
 * container is moved only after saying which one loses it. Both are asked
 * as questions with the impact spelled out (the old title "Move this
 * label?" for a replacement was wrong).
 */
export function planSticker(
  outcome: ScanOutcome,
  target: Named & { id: string; qrToken: string | null },
): StickerPlan {
  if (outcome.kind === 'invalid') return { kind: 'invalid' };

  const label = labelOf(target);
  const replacing = target.qrToken !== null && target.qrToken !== outcome.token;

  if (outcome.kind === 'bound') {
    if (outcome.container.id === target.id) return { kind: 'already' };
    const moveBody = strings.link.moveBody(labelOf(outcome.container), label);
    return {
      kind: 'link',
      token: outcome.token,
      confirm: {
        title: strings.link.moveTitle(label),
        // Moving it here also retires this container's own sticker, if it has one.
        body: replacing ? `${moveBody} ${strings.link.replaceBody(label)}` : moveBody,
        confirmLabel: strings.link.move,
      },
    };
  }

  return {
    kind: 'link',
    token: outcome.token,
    confirm: replacing
      ? {
          title: strings.link.replaceTitle(label),
          body: strings.link.replaceBody(label),
          confirmLabel: strings.link.replace,
        }
      : null,
  };
}

/** The label the QR screen has just written (`null` after a remove). */
export interface WrittenLabel {
  token: string | null;
  /** The read the write set off has started. */
  reloading: boolean;
}

/**
 * What the QR screen keeps showing after its own make, replace or remove,
 * given the state of the label's read.
 *
 * The written label holds until a read that started after the write has come
 * back, so the old state never flashes in between. If that read fails, the
 * query keeps its last good data, which is the label from before the write: a
 * retired sticker, or one just removed. So the written label holds on until a
 * later read succeeds, instead of offering the old sticker for printing.
 * Returns `written` itself when nothing changes.
 */
export function settleWrittenLabel(
  written: WrittenLabel | null,
  read: { loading: boolean; failed: boolean },
): WrittenLabel | null {
  if (!written) return null;
  if (!written.reloading) return read.loading ? { ...written, reloading: true } : written;
  if (read.loading) return written;
  return read.failed ? { ...written, reloading: false } : null;
}

export type LabelAction = 'make' | 'replace' | 'remove';

/**
 * The error toast for a label change that did not happen, in plain words and
 * saying what still holds: until a replace or remove succeeds, the sticker on
 * the box keeps working.
 */
export function labelFailureMessage(action: LabelAction, cause: unknown): string {
  const { kind } = describeError(cause, 'label', 'container');
  if (kind === 'gone') return strings.qr.containerGone;
  const offline = kind === 'offline';
  if (action === 'make') return strings.qr.makeFailed(offline);
  if (action === 'replace') return strings.qr.replaceFailed(offline);
  return strings.qr.removeFailed(offline);
}

/**
 * What the share sheet carries besides the picture. Android cannot attach a
 * file through React Native's `Share`, so there the link itself goes too and
 * the label can still be opened from a message (as before the redesign).
 */
export function shareText(
  container: Named,
  payload: string,
  options: { withPayload: boolean },
): string {
  const message = strings.qr.shareMessage(labelOf(container), container.shortCode);
  return options.withPayload ? `${message}\n${payload}` : message;
}
