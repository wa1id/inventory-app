import { ConflictError } from '@/core/conflict';
import { ago, longDate } from '@/i18n/format';
import { strings } from '@/i18n/strings';
import type { ItemFormValues } from '@/ui/components/ItemForm';

/*
 * Pure helpers for the item screen and Edit details,
 * tested in Node.
 */

/** The stored fields Edit details is filled from; `repos.items.getById` fits. */
export interface DetailsSource {
  name: string;
  category: string | null;
  tags: readonly string[];
  notes: string | null;
  quantity: number;
}

/** What Edit details is seeded with, once per item id. */
export function detailsSeed(item: DetailsSource): ItemFormValues {
  return {
    name: item.name,
    category: item.category ?? '',
    tags: item.tags.join(', '),
    // Not edited here (the stepper saves it), but `validateItemForm` reads it.
    quantity: String(item.quantity),
    notes: item.notes ?? '',
  };
}

function tagList(tags: string): string {
  return tags
    .split(',')
    .map((tag) => tag.trim())
    .filter(Boolean)
    .join(',');
}

/**
 * Whether the form holds anything worth asking about before it closes:
 * a field that differs from the seed once trimmed. Re-spacing the tags
 * ("a,b" for "a, b") is not a change; quantity is not on this form.
 */
export function detailsDirty(values: ItemFormValues, seed: ItemFormValues): boolean {
  return (
    values.name.trim() !== seed.name.trim() ||
    values.category.trim() !== seed.category.trim() ||
    tagList(values.tags) !== tagList(seed.tags) ||
    values.notes.trim() !== seed.notes.trim()
  );
}

/**
 * The desk rule: an item that has no name yet (a Quick Snap photo) can have
 * its category, tags or notes saved while it stays unnamed. A name is only
 * required once someone types one, or of an item that already had one,
 * because an explicitly blank name is refused by the repository.
 */
export function keepsUnnamed(storedName: string, typedName: string): boolean {
  return storedName === '' && typedName.trim() === '';
}

/** What Edit details writes; `name` is left out while an unnamed item stays unnamed. */
export interface DetailsPatch {
  name?: string;
  category: string | null;
  tags: string[];
  notes: string | null;
}

/** The version of the item a save goes over: its stamp, and its fields as the form shows them. */
export interface DetailsBase {
  updatedAt: number;
  values: ItemFormValues;
}

export type DetailsOutcome =
  | { kind: 'saved' }
  /** Deleted on another phone (a household update answers 404 as `null`). */
  | { kind: 'gone' }
  /**
   * Someone changed the name, category, tags or notes meanwhile; nothing was
   * written. `base` is their version, which saving again goes over.
   */
  | { kind: 'conflict'; base: DetailsBase }
  | { kind: 'failed'; cause: unknown };

/**
 * Saves Edit details over the version the form was filled from, never over
 * whatever a background re-read brought in meanwhile, so another phone's
 * rename is reported instead of silently overwritten.
 *
 * On a conflict the item is re-read. If one of this form's fields changed,
 * that is a real conflict and the person decides. If only the quantity or the
 * place changed, the save goes through once with the new stamp: most often
 * that change is this phone's own stepper on the item screen underneath,
 * whose write landed after the form was read, and blaming "another device"
 * for it was the self-conflict this form exists to remove.
 */
export async function attemptDetails(
  items: {
    update(
      id: string,
      input: DetailsPatch & { expectedUpdatedAt: number },
    ): Promise<{ updatedAt: number } | null>;
    getById(id: string): Promise<(DetailsSource & { updatedAt: number }) | null>;
  },
  id: string,
  patch: DetailsPatch,
  base: DetailsBase,
): Promise<DetailsOutcome> {
  try {
    const updated = await items.update(id, { ...patch, expectedUpdatedAt: base.updatedAt });
    return updated ? { kind: 'saved' } : { kind: 'gone' };
  } catch (cause) {
    if (!(cause instanceof ConflictError)) return { kind: 'failed', cause };
  }

  try {
    const fresh = await items.getById(id);
    if (!fresh) return { kind: 'gone' };
    const theirs: DetailsBase = { updatedAt: fresh.updatedAt, values: detailsSeed(fresh) };
    if (detailsDirty(theirs.values, base.values)) return { kind: 'conflict', base: theirs };
    const updated = await items.update(id, { ...patch, expectedUpdatedAt: fresh.updatedAt });
    return updated ? { kind: 'saved' } : { kind: 'gone' };
  } catch (cause) {
    return { kind: 'failed', cause };
  }
}

/** Changes closer than this to the creation are part of adding it (desk). */
const CHANGED_AFTER_MS = 60_000;

/** "Added 2 September 2026. Last changed 3 days ago." */
export function itemStamp(createdAt: number, updatedAt: number, now: number): string {
  const added = strings.item.stampAdded(longDate(createdAt));
  return updatedAt - createdAt > CHANGED_AFTER_MS
    ? `${added} ${strings.item.stampChanged(ago(updatedAt, now))}`
    : added;
}

export type NameOutcome =
  | { kind: 'named' }
  /** Deleted on another phone (a household update answers 404 as `null`). */
  | { kind: 'gone' }
  /**
   * It was given another name first, by recognition or on another phone
   * (which of the two is not known). Nothing was written; saving again over
   * `updatedAt` keeps the typed name.
   */
  | { kind: 'namedMeanwhile'; name: string; updatedAt: number }
  | { kind: 'failed'; cause: unknown };

/**
 * Names an unnamed item, carrying its lock (the "What is it?" field on the
 * item screen). On a conflict the item is re-read. If it now has another
 * name, nothing is written and the person decides; the typed name is never
 * dropped. Otherwise (a quantity changed, say, or it was given this very
 * name) the name is written once more with the new stamp.
 */
export async function attemptName(
  items: {
    update(
      id: string,
      input: { name: string; expectedUpdatedAt: number },
    ): Promise<{ updatedAt: number } | null>;
    getById(id: string): Promise<{ name: string; updatedAt: number } | null>;
  },
  item: { id: string; updatedAt: number },
  name: string,
): Promise<NameOutcome> {
  try {
    const updated = await items.update(item.id, { name, expectedUpdatedAt: item.updatedAt });
    return updated ? { kind: 'named' } : { kind: 'gone' };
  } catch (cause) {
    if (!(cause instanceof ConflictError)) return { kind: 'failed', cause };
  }

  try {
    const fresh = await items.getById(item.id);
    if (!fresh) return { kind: 'gone' };
    if (fresh.name && fresh.name !== name) {
      return { kind: 'namedMeanwhile', name: fresh.name, updatedAt: fresh.updatedAt };
    }
    const updated = await items.update(item.id, { name, expectedUpdatedAt: fresh.updatedAt });
    return updated ? { kind: 'named' } : { kind: 'gone' };
  } catch (cause) {
    return { kind: 'failed', cause };
  }
}
