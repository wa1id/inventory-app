import { ConflictError } from '@/core/conflict';
import { DROP_ZONE_CONTAINER_ID } from '@/db/constants';
import { strings } from '@/i18n/strings';
import { describeError } from '@/ui/errors';

/*
 * The pure half of Move and File: the desk's
 * `chooseMove`/`afterMove` (`home-server/web/app.js:1517-1592`) as plain
 * functions over the two repository calls they make, so every outcome is
 * tested in Node. `useMove` and the item screen wire them to the screen.
 */

/** The item as it was when the move started. */
export interface MoveSubject {
  id: string;
  containerId: string;
  updatedAt: number;
}

/** The repository calls a move makes; `repos.items` fits. */
export interface MoveItems<Fresh extends MoveSubject> {
  update(
    id: string,
    input: { containerId: string; expectedUpdatedAt: number },
  ): Promise<{ updatedAt: number } | null>;
  getById(id: string): Promise<Fresh | null>;
}

export type MoveOutcome<Fresh> =
  /** Written; `updatedAt` is the item's new stamp, which Undo expects. */
  | { kind: 'moved'; updatedAt: number }
  /**
   * Deleted on another phone. A household update answers 404 as `null`
   * rather than throwing, so without this check a move of a vanished item
   * would be reported as done (missed by all three drafts).
   */
  | { kind: 'gone' }
  /** Someone moved it first; nothing was written, `fresh` is where it is now. */
  | { kind: 'movedElsewhere'; fresh: Fresh }
  | { kind: 'failed'; cause: unknown };

/**
 * Moves `before` into `target`, carrying the optimistic lock.
 *
 * On a conflict it re-reads the item, as the desk does: if it is now
 * somewhere else, another phone moved it and the person should see that
 * rather than have it silently overruled; if it is still where it was (a
 * rename or a quantity changed), the move is retried once with the new stamp.
 */
export async function attemptMove<Fresh extends MoveSubject>(
  items: MoveItems<Fresh>,
  before: MoveSubject,
  target: string,
): Promise<MoveOutcome<Fresh>> {
  try {
    const updated = await items.update(before.id, {
      containerId: target,
      expectedUpdatedAt: before.updatedAt,
    });
    return updated ? { kind: 'moved', updatedAt: updated.updatedAt } : { kind: 'gone' };
  } catch (cause) {
    if (!(cause instanceof ConflictError)) return { kind: 'failed', cause };
  }

  try {
    const fresh = await items.getById(before.id);
    if (!fresh) return { kind: 'gone' };
    if (fresh.containerId !== before.containerId) return { kind: 'movedElsewhere', fresh };
    const updated = await items.update(before.id, {
      containerId: target,
      expectedUpdatedAt: fresh.updatedAt,
    });
    return updated ? { kind: 'moved', updatedAt: updated.updatedAt } : { kind: 'gone' };
  } catch (cause) {
    return { kind: 'failed', cause };
  }
}

export type UndoOutcome =
  | { kind: 'undone' }
  | { kind: 'gone' }
  | { kind: 'conflict' }
  /** Kept, so the toast blames the connection only when it was the connection. */
  | { kind: 'failed'; cause: unknown };

/**
 * Puts the item back where it came from, but only if nothing touched it
 * since the move: the lock is the stamp the move itself left. A later change
 * on another phone wins over an Undo, never the other way round.
 */
export async function attemptUndo(
  items: Pick<MoveItems<MoveSubject>, 'update'>,
  move: { itemId: string; from: string; updatedAt: number },
): Promise<UndoOutcome> {
  try {
    const restored = await items.update(move.itemId, {
      containerId: move.from,
      expectedUpdatedAt: move.updatedAt,
    });
    return restored ? { kind: 'undone' } : { kind: 'gone' };
  } catch (cause) {
    return cause instanceof ConflictError ? { kind: 'conflict' } : { kind: 'failed', cause };
  }
}

/** What an Undo that did not happen says, in an error toast. */
export function undoFailedMessage(outcome: Exclude<UndoOutcome, { kind: 'undone' }>): string {
  if (outcome.kind === 'gone') return strings.move.undoGone;
  if (outcome.kind === 'conflict') return strings.move.undoConflict;
  return describeError(outcome.cause, 'move', 'item').kind === 'offline'
    ? strings.move.undoFailed
    : strings.move.undoFailedOther;
}

/** A container as a toast names it: its name, or the code on its label. */
export function containerLabel(place: { name: string | null; shortCode: string }): string {
  return place.name ?? place.shortCode;
}

/**
 * The toast after a move.
 *
 * Out of the drop zone it is filing, so it says "Filed in". In a filing run
 * the item screen goes straight on to the next waiting item, which the screen
 * itself shows. After the last one the run ends on the Drop zone tab, and the
 * toast says so (rather than a second toast pushing this one, and its Undo,
 * off the screen). `moreWaiting` is `null` when the drop zone could not be
 * read, and then the toast promises neither.
 */
export function movedMessage({
  fromDropZone,
  filing,
  moreWaiting,
  container,
  space,
}: {
  fromDropZone: boolean;
  filing: boolean;
  moreWaiting: boolean | null;
  container: string;
  space: string;
}): string {
  if (!fromDropZone) return strings.move.movedTo(container, space);
  return filing && moreWaiting === false
    ? strings.move.filedLast(container, space)
    : strings.move.filedIn(container, space);
}

/**
 * After a filing step, the drop zone read once, right after the move: the
 * toast's "Everything is filed." and the item screen's next step both come
 * from this one read, so they cannot disagree when an item lands in the drop
 * zone (or is filed elsewhere) in between. `moreWaiting` is `null` and
 * `waiting` absent when the read failed.
 */
export async function afterFiling(
  items: { listUnsorted(): Promise<readonly { id: string }[]> },
  itemId: string,
): Promise<{ waiting?: string[]; moreWaiting: boolean | null }> {
  try {
    const waiting = (await items.listUnsorted()).map((entry) => entry.id);
    return { waiting, moreWaiting: waiting.some((id) => id !== itemId) };
  } catch {
    return { moreWaiting: null };
  }
}

/** The picker notice when another phone moved the item first. */
export function movedElsewhereMessage(fresh: {
  containerId: string;
  containerName: string | null;
  containerShortCode: string;
}): string {
  if (fresh.containerId === DROP_ZONE_CONTAINER_ID) return strings.move.alreadyMovedToDropZone;
  return strings.move.alreadyMoved(fresh.containerName ?? fresh.containerShortCode);
}

/** The picker notice for a move that failed: the connection, or anything else. */
export function moveFailedMessage(cause: unknown): string {
  return describeError(cause, 'move', 'item').kind === 'offline'
    ? strings.move.failed
    : strings.move.failedOther;
}

/**
 * The next item of a filing run (the desk's "runs, not errands").
 *
 * `before` is the drop zone as it was when this item's move started, so the
 * run keeps its order; `waiting` is the drop zone as it is now. The item
 * after this one in `before` is next, wrapping round to the top, skipping
 * this item and anything filed or deleted meanwhile. Items that arrived in
 * the drop zone since come last. `null` when nothing is left.
 */
export function nextInRun(
  before: readonly string[],
  currentId: string,
  waiting: readonly string[],
): string | null {
  const left = new Set(waiting.filter((id) => id !== currentId));
  if (left.size === 0) return null;

  // From the item after this one, wrapping; from the top if it was not in the list.
  const start = before.indexOf(currentId) + 1;
  for (let offset = 0; offset < before.length; offset += 1) {
    const id = before[(start + offset) % before.length];
    if (id !== undefined && left.has(id)) return id;
  }
  return waiting.find((id) => left.has(id)) ?? null;
}
