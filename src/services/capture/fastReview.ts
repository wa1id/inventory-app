import type { ItemWithContext } from '@/db/types';

/**
 * What the review screen can honestly say about a fast-capture session.
 *
 * `pending` is derived from the shutter count the camera screen reported, not
 * from pipeline state — the pipeline keeps running after the camera unmounts,
 * so rows the screen has not seen yet are exactly `expected - saved`.
 */
export interface FastSessionSummary {
  saved: number;
  named: number;
  unnamed: number;
  pending: number;
}

/**
 * The items belonging to one fast-capture session, in the order they were
 * shot. `listByContainer` returns newest-first for browsing; a review of a
 * shooting session reads top-to-bottom in shutter order.
 */
export function sessionItems(items: ItemWithContext[], since: number): ItemWithContext[] {
  return items.filter((item) => item.createdAt >= since).sort((a, b) => a.createdAt - b.createdAt);
}

export function summarizeSession(items: ItemWithContext[], expected: number): FastSessionSummary {
  const saved = items.length;
  const named = items.filter((item) => item.name.trim().length > 0).length;
  return {
    saved,
    named,
    unnamed: saved - named,
    // Clamped: a row that failed to write after the camera reported it would
    // otherwise push this negative once later rows land.
    pending: Math.max(0, expected - saved),
  };
}
