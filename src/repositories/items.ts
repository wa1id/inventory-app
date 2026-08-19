import { newId } from '@/core/id';
import { DROP_ZONE_CONTAINER_ID, splitTagNames } from '@/db/constants';
import type { Item, ItemPhoto, ItemWithContext, SqlDatabase } from '@/db/types';

interface ItemRow {
  id: string;
  container_id: string;
  name: string;
  category: string | null;
  quantity: number;
  notes: string | null;
  created_at: number;
  updated_at: number;
}

interface ItemContextRow extends ItemRow {
  photo_id: string | null;
  photo_uri: string | null;
  photo_thumb_uri: string | null;
  tag_names: string | null;
  space_id: string;
  space_name: string;
  space_icon: string;
  space_color: string;
  container_name: string | null;
  container_short_code: string;
}

function toItem(row: ItemRow): Item {
  return {
    id: row.id,
    containerId: row.container_id,
    name: row.name,
    category: row.category,
    quantity: row.quantity,
    notes: row.notes,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function toItemWithContext(row: ItemContextRow): ItemWithContext {
  return {
    ...toItem(row),
    photoId: row.photo_id,
    photoUri: row.photo_uri,
    photoThumbUri: row.photo_thumb_uri,
    tags: splitTagNames(row.tag_names),
    spaceId: row.space_id,
    spaceName: row.space_name,
    spaceIcon: row.space_icon,
    spaceColor: row.space_color,
    containerName: row.container_name,
    containerShortCode: row.container_short_code,
  };
}

/**
 * Shared projection for every item list in the app.
 *
 * Tags are aggregated with a unit-separator delimiter rather than a comma so a
 * tag containing a comma cannot corrupt the split on the client.
 */
const ITEM_CONTEXT_SELECT = `
  SELECT i.*,
         (SELECT p.id FROM item_photos p WHERE p.item_id = i.id
           ORDER BY p.created_at ASC LIMIT 1) AS photo_id,
         (SELECT p.uri FROM item_photos p WHERE p.item_id = i.id
           ORDER BY p.created_at ASC LIMIT 1) AS photo_uri,
         (SELECT p.thumb_uri FROM item_photos p WHERE p.item_id = i.id
           ORDER BY p.created_at ASC LIMIT 1) AS photo_thumb_uri,
         (SELECT GROUP_CONCAT(t.name, char(31)) FROM item_tags it
            JOIN tags t ON t.id = it.tag_id WHERE it.item_id = i.id) AS tag_names,
         c.space_id AS space_id,
         s.name AS space_name,
         s.icon AS space_icon,
         s.color AS space_color,
         c.name AS container_name,
         c.short_code AS container_short_code
    FROM items i
    JOIN containers c ON c.id = i.container_id
    JOIN spaces s ON s.id = c.space_id
`;

export interface ItemDraft {
  containerId: string;
  /**
   * Omit when the item genuinely has no name yet — fast capture writes the row
   * before recognition has returned, and a failed recognition leaves it that
   * way. An explicitly blank string is still rejected: that means a caller
   * skipped validation rather than deliberately deferring the name.
   */
  name?: string;
  category?: string | null;
  quantity?: number;
  notes?: string | null;
  tags?: string[];
  photo?: {
    uri: string;
    thumbUri?: string;
    width?: number;
    height?: number;
    byteSize?: number;
  } | null;
}

export type UpdateItemInput = Partial<Omit<ItemDraft, 'containerId'>> & {
  containerId?: string;
};

function normalizeTag(tag: string): string {
  return tag.trim().toLowerCase();
}

function searchTextFor(name: string, category: string | null): string {
  return `${name} ${category ?? ''}`.trim().toLowerCase();
}

export function createItemsRepository(db: SqlDatabase) {
  /** Resolves tag names to IDs, creating any that do not exist yet. */
  async function upsertTags(tags: string[]): Promise<string[]> {
    const ids: string[] = [];
    const seen = new Set<string>();

    for (const raw of tags) {
      const name = raw.trim();
      const normalized = normalizeTag(name);
      if (!normalized || seen.has(normalized)) continue;
      seen.add(normalized);

      const existing = await db.getFirstAsync<{ id: string }>(
        'SELECT id FROM tags WHERE normalized_name = ?',
        [normalized],
      );

      if (existing) {
        ids.push(existing.id);
        continue;
      }

      const id = newId();
      await db.runAsync(
        'INSERT INTO tags (id, name, normalized_name, created_at) VALUES (?, ?, ?, ?)',
        [id, name, normalized, Date.now()],
      );
      ids.push(id);
    }

    return ids;
  }

  async function replaceTags(itemId: string, tags: string[]): Promise<void> {
    const tagIds = await upsertTags(tags);
    await db.runAsync('DELETE FROM item_tags WHERE item_id = ?', [itemId]);
    for (const tagId of tagIds) {
      await db.runAsync('INSERT INTO item_tags (item_id, tag_id) VALUES (?, ?)', [itemId, tagId]);
    }
  }

  return {
    async listByContainer(containerId: string): Promise<ItemWithContext[]> {
      const rows = await db.getAllAsync<ItemContextRow>(
        `${ITEM_CONTEXT_SELECT} WHERE i.container_id = ? ORDER BY i.created_at DESC`,
        [containerId],
      );
      return rows.map(toItemWithContext);
    },

    /** Everything waiting in the drop zone, newest first (issue #26). */
    async listUnsorted(): Promise<ItemWithContext[]> {
      const rows = await db.getAllAsync<ItemContextRow>(
        `${ITEM_CONTEXT_SELECT} WHERE i.container_id = ? ORDER BY i.created_at DESC`,
        [DROP_ZONE_CONTAINER_ID],
      );
      return rows.map(toItemWithContext);
    },

    /** Cheap enough for the dashboard badge to read on every focus. */
    async countUnsorted(): Promise<number> {
      const row = await db.getFirstAsync<{ count: number }>(
        'SELECT COUNT(*) AS count FROM items WHERE container_id = ?',
        [DROP_ZONE_CONTAINER_ID],
      );
      return row?.count ?? 0;
    },

    async getById(id: string): Promise<ItemWithContext | null> {
      const row = await db.getFirstAsync<ItemContextRow>(`${ITEM_CONTEXT_SELECT} WHERE i.id = ?`, [
        id,
      ]);
      return row ? toItemWithContext(row) : null;
    },

    /**
     * Creates an item together with its optional photo and tags atomically.
     *
     * A partially written item (row saved, tags lost) would be worse than a
     * failed save, so the whole draft commits or none of it does.
     */
    async create(draft: ItemDraft): Promise<Item> {
      const now = Date.now();
      const quantity = draft.quantity ?? 1;
      if (!Number.isInteger(quantity) || quantity < 1) {
        throw new Error('Quantity must be a whole number of at least 1.');
      }

      const name = draft.name === undefined ? '' : draft.name.trim();
      if (draft.name !== undefined && !name) throw new Error('Item name is required.');

      const category = draft.category?.trim() || null;

      const item: Item = {
        id: newId(),
        containerId: draft.containerId,
        name,
        category,
        quantity,
        notes: draft.notes?.trim() || null,
        createdAt: now,
        updatedAt: now,
      };

      await db.withTransactionAsync(async () => {
        await db.runAsync(
          `INSERT INTO items
             (id, container_id, name, category, quantity, notes, created_at,
              updated_at, search_text)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          [
            item.id,
            item.containerId,
            item.name,
            item.category,
            item.quantity,
            item.notes,
            item.createdAt,
            item.updatedAt,
            searchTextFor(item.name, item.category),
          ],
        );

        if (draft.photo) {
          await db.runAsync(
            `INSERT INTO item_photos (id, item_id, uri, thumb_uri, width, height, byte_size, created_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
            [
              newId(),
              item.id,
              draft.photo.uri,
              draft.photo.thumbUri ?? null,
              draft.photo.width ?? null,
              draft.photo.height ?? null,
              draft.photo.byteSize ?? null,
              now,
            ],
          );
        }

        if (draft.tags?.length) {
          await replaceTags(item.id, draft.tags);
        }
      });

      return item;
    },

    async update(id: string, input: UpdateItemInput): Promise<Item | null> {
      const existing = await db.getFirstAsync<ItemRow>('SELECT * FROM items WHERE id = ?', [id]);
      if (!existing) return null;

      const quantity = input.quantity ?? existing.quantity;
      if (!Number.isInteger(quantity) || quantity < 1) {
        throw new Error('Quantity must be a whole number of at least 1.');
      }

      const name = input.name === undefined ? existing.name : input.name.trim();
      // Same rule as create: only an *explicitly* blank name is an error. An
      // item that is already unnamed must stay editable — otherwise filing a
      // drop-zone capture into a container fails purely because it has no name
      // yet, which is exactly the state the drop zone exists to hold.
      if (input.name !== undefined && !name) throw new Error('Item name is required.');

      const category =
        input.category === undefined ? existing.category : input.category?.trim() || null;

      const next: Item = {
        ...toItem(existing),
        containerId: input.containerId ?? existing.container_id,
        name,
        category,
        quantity,
        notes: input.notes === undefined ? existing.notes : input.notes?.trim() || null,
        updatedAt: Date.now(),
      };

      await db.withTransactionAsync(async () => {
        await db.runAsync(
          `UPDATE items
              SET container_id = ?, name = ?, category = ?, quantity = ?,
                  notes = ?, updated_at = ?, search_text = ?
            WHERE id = ?`,
          [
            next.containerId,
            next.name,
            next.category,
            next.quantity,
            next.notes,
            next.updatedAt,
            searchTextFor(next.name, next.category),
            id,
          ],
        );

        if (input.tags !== undefined) {
          await replaceTags(id, input.tags);
        }

        if (input.photo !== undefined) {
          await db.runAsync('DELETE FROM item_photos WHERE item_id = ?', [id]);
          if (input.photo) {
            await db.runAsync(
              `INSERT INTO item_photos (id, item_id, uri, thumb_uri, width, height, byte_size, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
              [
                newId(),
                id,
                input.photo.uri,
                input.photo.thumbUri ?? null,
                input.photo.width ?? null,
                input.photo.height ?? null,
                input.photo.byteSize ?? null,
                Date.now(),
              ],
            );
          }
        }
      });

      return next;
    },

    async getPhotos(itemId: string): Promise<ItemPhoto[]> {
      const rows = await db.getAllAsync<{
        id: string;
        item_id: string;
        uri: string;
        thumb_uri: string | null;
        width: number | null;
        height: number | null;
        byte_size: number | null;
        created_at: number;
      }>('SELECT * FROM item_photos WHERE item_id = ? ORDER BY created_at ASC', [itemId]);

      return rows.map((row) => ({
        id: row.id,
        itemId: row.item_id,
        uri: row.uri,
        thumbUri: row.thumb_uri,
        width: row.width,
        height: row.height,
        byteSize: row.byte_size,
        createdAt: row.created_at,
      }));
    },

    /** Removes the item plus its photo and tag links in one transaction. */
    async delete(id: string): Promise<{ deleted: boolean; orphanedPhotoUris: string[] }> {
      let deleted = false;
      let orphanedPhotoUris: string[] = [];

      await db.withTransactionAsync(async () => {
        const photos = await db.getAllAsync<{ uri: string; thumb_uri: string | null }>(
          'SELECT uri, thumb_uri FROM item_photos WHERE item_id = ?',
          [id],
        );
        // Both files, or the thumbnail is left behind on every delete. Rows
        // captured before thumbnails existed have none, and those nulls are
        // dropped here rather than pushed onto every caller.
        orphanedPhotoUris = photos
          .flatMap((photo) => [photo.uri, photo.thumb_uri])
          .filter((uri): uri is string => uri !== null);

        const result = await db.runAsync('DELETE FROM items WHERE id = ?', [id]);
        deleted = result.changes > 0;
      });

      return { deleted, orphanedPhotoUris };
    },

    async countAll(): Promise<number> {
      const row = await db.getFirstAsync<{ count: number }>('SELECT COUNT(*) AS count FROM items');
      return row?.count ?? 0;
    },
  };
}

export type ItemsRepository = ReturnType<typeof createItemsRepository>;
