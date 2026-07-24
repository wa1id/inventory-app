import { newId } from '@/core/id';
import type { SqlDatabase, Space, SpaceWithCounts } from '@/db/types';

interface SpaceRow {
  id: string;
  name: string;
  icon: string;
  color: string;
  created_at: number;
  updated_at: number;
}

interface SpaceWithCountsRow extends SpaceRow {
  container_count: number;
  item_count: number;
}

function toSpace(row: SpaceRow): Space {
  return {
    id: row.id,
    name: row.name,
    icon: row.icon,
    color: row.color,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

export interface CreateSpaceInput {
  name: string;
  icon: string;
  color: string;
}

export type UpdateSpaceInput = Partial<CreateSpaceInput>;

/** What a user is about to lose by deleting a space, for the confirm dialog. */
export interface SpaceDeletionImpact {
  containerCount: number;
  itemCount: number;
  photoCount: number;
  qrBindingCount: number;
}

export function createSpacesRepository(db: SqlDatabase) {
  return {
    /**
     * Dashboard query. Counts are aggregated in SQL rather than by loading
     * children, so a space with thousands of items still renders in one round
     * trip.
     */
    async listWithCounts(): Promise<SpaceWithCounts[]> {
      const rows = await db.getAllAsync<SpaceWithCountsRow>(`
        SELECT s.*,
               (SELECT COUNT(*) FROM containers c WHERE c.space_id = s.id)
                 AS container_count,
               (SELECT COUNT(*) FROM items i
                  JOIN containers c ON c.id = i.container_id
                 WHERE c.space_id = s.id)
                 AS item_count
          FROM spaces s
         ORDER BY s.name COLLATE NOCASE ASC
      `);

      return rows.map((row) => ({
        ...toSpace(row),
        containerCount: row.container_count,
        itemCount: row.item_count,
      }));
    },

    async getById(id: string): Promise<Space | null> {
      const row = await db.getFirstAsync<SpaceRow>('SELECT * FROM spaces WHERE id = ?', [id]);
      return row ? toSpace(row) : null;
    },

    async create(input: CreateSpaceInput): Promise<Space> {
      const now = Date.now();
      const space: Space = {
        id: newId(),
        name: input.name.trim(),
        icon: input.icon,
        color: input.color,
        createdAt: now,
        updatedAt: now,
      };

      await db.runAsync(
        `INSERT INTO spaces (id, name, icon, color, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?)`,
        [space.id, space.name, space.icon, space.color, space.createdAt, space.updatedAt],
      );

      return space;
    },

    /** Renaming or restyling never touches `id` or `created_at`. */
    async update(id: string, input: UpdateSpaceInput): Promise<Space | null> {
      const existing = await this.getById(id);
      if (!existing) return null;

      const next: Space = {
        ...existing,
        name: input.name?.trim() ?? existing.name,
        icon: input.icon ?? existing.icon,
        color: input.color ?? existing.color,
        updatedAt: Date.now(),
      };

      await db.runAsync(
        `UPDATE spaces SET name = ?, icon = ?, color = ?, updated_at = ? WHERE id = ?`,
        [next.name, next.icon, next.color, next.updatedAt, id],
      );

      return next;
    },

    /** Powers the "this will also delete N containers and M items" warning. */
    async deletionImpact(id: string): Promise<SpaceDeletionImpact> {
      const row = await db.getFirstAsync<{
        container_count: number;
        item_count: number;
        photo_count: number;
        qr_count: number;
      }>(
        `SELECT
           (SELECT COUNT(*) FROM containers WHERE space_id = ?1) AS container_count,
           (SELECT COUNT(*) FROM items i JOIN containers c ON c.id = i.container_id
             WHERE c.space_id = ?1) AS item_count,
           (SELECT COUNT(*) FROM item_photos p
              JOIN items i ON i.id = p.item_id
              JOIN containers c ON c.id = i.container_id
             WHERE c.space_id = ?1) AS photo_count,
           (SELECT COUNT(*) FROM qr_bindings q
              JOIN containers c ON c.id = q.container_id
             WHERE c.space_id = ?1) AS qr_count`,
        [id],
      );

      return {
        containerCount: row?.container_count ?? 0,
        itemCount: row?.item_count ?? 0,
        photoCount: row?.photo_count ?? 0,
        qrBindingCount: row?.qr_count ?? 0,
      };
    },

    /**
     * Deletes a space and everything beneath it in one transaction.
     *
     * Returns the photo URIs that are now unreferenced so the caller can delete
     * the backing files; the rows are gone either way, so a failed file cleanup
     * can never leave a dangling database reference.
     */
    async delete(id: string): Promise<{ deleted: boolean; orphanedPhotoUris: string[] }> {
      let deleted = false;
      let orphanedPhotoUris: string[] = [];

      await db.withTransactionAsync(async () => {
        const photos = await db.getAllAsync<{ uri: string }>(
          `SELECT p.uri FROM item_photos p
             JOIN items i ON i.id = p.item_id
             JOIN containers c ON c.id = i.container_id
            WHERE c.space_id = ?`,
          [id],
        );
        orphanedPhotoUris = photos.map((photo) => photo.uri);

        // ON DELETE CASCADE removes containers, items, photos, tags links, and
        // QR bindings; foreign_keys is enabled when the database is opened.
        const result = await db.runAsync('DELETE FROM spaces WHERE id = ?', [id]);
        deleted = result.changes > 0;
      });

      return { deleted, orphanedPhotoUris };
    },
  };
}

export type SpacesRepository = ReturnType<typeof createSpacesRepository>;
