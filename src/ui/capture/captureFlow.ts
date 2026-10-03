import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import { strings } from '@/i18n/strings';
import type { FastSessionSummary } from '@/services/capture/fastReview';
import { spellCode, type PlaceLike } from '@/ui/a11y';

/*
 * The decisions behind the capture, review and drop-zone screens, kept pure
 * (no React Native) so they are tested in Node. The camera mechanics they
 * report on live in the capture screen; only what is said and where the
 * person lands is decided here.
 */

/** Fast-mode counters as the camera keeps them: shutter presses, finished pipelines, names. */
export interface FastTallies {
  captured: number;
  completed: number;
  recognized: number;
}

/**
 * The fast-mode status pill. The counters stay separate on purpose
 * (`111b579:app/capture/index.tsx:55-58`): reporting completions as
 * identifications would claim work the recogniser did not do. `settled` is
 * false while photos are still being saved or identified.
 */
export function fastStatus({ captured, completed, recognized }: FastTallies): {
  text: string;
  settled: boolean;
} {
  const pending = captured - completed;
  const unnamed = completed - recognized;
  const text =
    pending > 0
      ? strings.capture.identifying(pending)
      : unnamed === 0
        ? strings.capture.identified(recognized)
        : recognized === 0
          ? strings.capture.savedUnnamed(unnamed)
          : strings.capture.identifiedPartly(recognized, unnamed);
  return { text, settled: pending <= 0 };
}

/**
 * Where ✕ and Android back go. A fast set with shots in it always ends on the
 * review, so a batch can never skip it; otherwise the camera
 * simply closes and the person is back where they started.
 */
export function leaveCamera(mode: 'single' | 'fast', captured: number): 'review' | 'back' {
  return mode === 'fast' && captured > 0 ? 'review' : 'back';
}

/** The "Into" pill, spoken: where the photos will go. */
export function intoA11y(containerId: string, place: PlaceLike | null): string {
  if (containerId === DROP_ZONE_CONTAINER_ID || !place) return strings.capture.intoDropZoneA11y;
  const spelled = spellCode(place.containerShortCode);
  return place.containerName
    ? strings.capture.intoContainerA11y(place.containerName, place.spaceName, spelled)
    : strings.capture.intoSpaceA11y(place.spaceName, spelled);
}

/**
 * The image picker refuses with an error that mentions permissions when photo
 * access is off; anything else is a photo that could not be opened.
 */
export function isPermissionError(cause: unknown): boolean {
  if (!(cause instanceof Error)) return false;
  const code = (cause as Error & { code?: unknown }).code;
  return /permission/i.test(`${typeof code === 'string' ? code : ''} ${cause.message}`);
}

export type ReviewStatus = 'pending' | 'maybeLost' | 'toName' | 'allNamed';

/**
 * The line under the review's title. Photos still on their way are "Saving N
 * more…" only while the set is still changing: `expected` is frozen when the
 * camera closes, so a shot that failed afterwards would otherwise leave it
 * saying "Saving…" for ever. `stalled` is true once the list
 * has not changed for a while.
 */
export function reviewStatus(summary: FastSessionSummary, stalled: boolean): ReviewStatus {
  if (summary.pending > 0) return stalled ? 'maybeLost' : 'pending';
  return summary.unnamed > 0 ? 'toName' : 'allNamed';
}

export function reviewStatusText(status: ReviewStatus, summary: FastSessionSummary): string {
  switch (status) {
    case 'pending':
      // Under "Saving 2 photos…" (nothing landed yet), "2 more" would repeat it.
      return summary.saved === 0
        ? strings.review.savingFirst
        : strings.review.pending(summary.pending);
    case 'maybeLost':
      return strings.review.maybeLost;
    case 'toName':
      return strings.review.toName(summary.unnamed);
    case 'allNamed':
      return strings.review.allNamed;
  }
}

/**
 * What the set's rows have to say about their container. Every row of a set is
 * in the same container, so the first one names it; an unnamed container is
 * called by its label code, as it is written on the box.
 */
export function containerLabel(
  items: readonly { containerName: string | null; containerShortCode: string }[],
): string | null {
  const first = items[0];
  if (!first) return null;
  return first.containerName ?? first.containerShortCode;
}

/**
 * "4 saved to the drop zone" / "4 saved to Tool chest". Until the first row
 * lands it says what is happening ("Saving 2 photos…"), never "0 saved", a
 * failure that has not happened. A container's name comes from its rows, so
 * otherwise there is no title rather than a wrong one.
 */
export function reviewTitle(
  summary: FastSessionSummary,
  status: ReviewStatus,
  containerId: string,
  label: string | null,
): string | null {
  const { saved } = summary;
  if (saved === 0 && status === 'pending') return strings.review.savingTitle(summary.pending);
  if (containerId === DROP_ZONE_CONTAINER_ID) return strings.review.savedToDropZone(saved);
  return label === null ? null : strings.review.savedTo(saved, label);
}

/**
 * The toast after "Done": the drop zone offers to show the set, a container
 * does not (the person is back on it). Nothing saved, nothing to say.
 */
export function reviewDoneToast(
  saved: number,
  containerId: string,
  label: string | null,
): { message: string; viewDropZone: boolean } | null {
  if (saved === 0) return null;
  if (containerId === DROP_ZONE_CONTAINER_ID) {
    return { message: strings.review.doneDropZone(saved), viewDropZone: true };
  }
  return label === null
    ? null
    : { message: strings.review.doneContainer(saved, label), viewDropZone: false };
}

/**
 * Every row the set has shown so far, by id. A row that has since left the
 * list (deleted here or on its item screen, filed out of the drop zone, moved)
 * has landed all the same: it is not a photo still on its way. Returns the
 * same set when nothing is new, so state built on it does not churn.
 */
export function withLanded(
  landed: ReadonlySet<string>,
  items: readonly { id: string }[],
): ReadonlySet<string> {
  if (items.every((item) => landed.has(item.id))) return landed;
  const next = new Set(landed);
  for (const item of items) next.add(item.id);
  return next;
}

/**
 * The `expected` to measure what is shown against: the camera's count less the
 * rows that landed and have left since. Without this, every row filed in a
 * filing run started from the review, or deleted, read as "Saving 1 more…"
 * and then "Some photos may not have been saved." (`summarizeSession` takes
 * `pending` as `expected - saved`.)
 */
export function expectedStillShown(expected: number, landed: number, shown: number): number {
  return Math.max(0, expected - Math.max(0, landed - shown));
}

/**
 * A fingerprint of a set's rows: it changes when a row lands, is named or
 * goes, and not when the same rows are simply read again (every focus and
 * write re-reads them).
 */
export function sessionSignature(items: readonly { id: string; updatedAt: number }[]): string {
  return items.map((item) => `${item.id}:${item.updatedAt}`).join('|');
}

/**
 * Rows hidden the moment they were filed or deleted, so they leave the list
 * at once (with the layout animation) instead of when the refetch lands. The
 * hiding belongs to the list it was made against: a fresh read replaces it,
 * so an item moved back by Undo shows again.
 */
export interface HiddenRows {
  source: readonly unknown[];
  ids: ReadonlySet<string>;
}

export function hideRow(
  previous: HiddenRows | null,
  source: readonly unknown[],
  id: string,
): HiddenRows {
  const ids = new Set(previous && previous.source === source ? previous.ids : []);
  ids.add(id);
  return { source, ids };
}

export function visibleRows<T extends { id: string }>(items: T[], hidden: HiddenRows | null): T[] {
  if (!hidden || hidden.source !== items) return items;
  return items.filter((item) => !hidden.ids.has(item.id));
}
