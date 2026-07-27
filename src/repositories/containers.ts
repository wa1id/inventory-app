import { newId } from '@/core/id';
import { generateShortCode } from '@/core/shortCode';
import type { Container, ContainerVisualType, ContainerWithCounts, SqlDatabase } from '@/db/types';

interface ContainerRow {
  id: string;
  space_id: string;
  name: string | null;
  visual_type: string;
  short_code: string;
  created_at: number;
  updated_at: number;
}

interface ContainerWithCountsRow extends ContainerRow {
  item_count: number;
  qr_token: string | null;
}

function toContainer(row: ContainerRow): Container {
  return {
    id: row.id,
    spaceId: row.space_id,
    name: row.name,
    visualType: row.visual_type as ContainerVisualType,
    shortCode: row.short_code,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

export interface CreateContainerInput {
  spaceId: string;
  name?: string | null;
  visualType: ContainerVisualType;
}

export interface UpdateContainerInput {
  name?: string | null;
  visualType?: ContainerVisualType;
  spaceId?: string;
}

export interface ContainerDeletionImpact {
  itemCount: number;
  photoCount: number;
  hasQrBinding: boolean;
}

/** Bounded retry budget for the (very unlikely) short-code collision. */
const SHORT_CODE_ATTEMPTS = 10;

export function createContainersRepository(db: SqlDatabase) {
  return {
    async listBySpace(spaceId: string): Promise<ContainerWithCounts[]> {
      const rows = await db.getAllAsync<ContainerWithCountsRow>(
        `SELECT c.*,
                (SELECT COUNT(*) FROM items i WHERE i.container_id = c.id) AS item_count,
                (SELECT q.token FROM qr_bindings q WHERE q.container_id = c.id
                  ORDER BY q.created_at DESC LIMIT 1) AS qr_token
           FROM containers c
          WHERE c.space_id = ? AND c.kind = 'normal'
          ORDER BY c.created_at DESC`,
        [spaceId],
      );

      return rows.map((row) => ({
        ...toContainer(row),
        itemCount: row.item_count,
        qrToken: row.qr_token,
      }));
    },

    async getById(id: string): Promise<Container | null> {
      const row = await db.getFirstAsync<ContainerRow>('SELECT * FROM containers WHERE id = ?', [
        id,
      ]);
      return row ? toContainer(row) : null;
    },

    async getWithCounts(id: string): Promise<ContainerWithCounts | null> {
      const row = await db.getFirstAsync<ContainerWithCountsRow>(
        `SELECT c.*,
                (SELECT COUNT(*) FROM items i WHERE i.container_id = c.id) AS item_count,
                (SELECT q.token FROM qr_bindings q WHERE q.container_id = c.id
                  ORDER BY q.created_at DESC LIMIT 1) AS qr_token
           FROM containers c
          WHERE c.id = ?`,
        [id],
      );
      if (!row) return null;
      return { ...toContainer(row), itemCount: row.item_count, qrToken: row.qr_token };
    },

    /**
     * Creates a container, assigning a unique human-friendly short code.
     *
     * The UNIQUE index is the actual arbiter of uniqueness — we retry on insert
     * failure rather than doing a check-then-insert, which would race.
     */
    async create(input: CreateContainerInput): Promise<Container> {
      const now = Date.now();
      const name = input.name?.trim() ? input.name.trim() : null;

      for (let attempt = 0; attempt < SHORT_CODE_ATTEMPTS; attempt += 1) {
        const container: Container = {
          id: newId(),
          spaceId: input.spaceId,
          name,
          visualType: input.visualType,
          shortCode: generateShortCode(input.visualType),
          createdAt: now,
          updatedAt: now,
        };

        try {
          await db.runAsync(
            `INSERT INTO containers
               (id, space_id, name, visual_type, short_code, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?)`,
            [
              container.id,
              container.spaceId,
              container.name,
              container.visualType,
              container.shortCode,
              container.createdAt,
              container.updatedAt,
            ],
          );
          return container;
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          if (!/UNIQUE|constraint/i.test(message)) throw error;
          // Short code collided — fall through and try another one.
        }
      }

      throw new Error('Could not allocate a unique container code. Please try again.');
    },

    async update(id: string, input: UpdateContainerInput): Promise<Container | null> {
      const existing = await this.getById(id);
      if (!existing) return null;

      const next: Container = {
        ...existing,
        name:
          input.name === undefined ? existing.name : input.name?.trim() ? input.name.trim() : null,
        visualType: input.visualType ?? existing.visualType,
        spaceId: input.spaceId ?? existing.spaceId,
        updatedAt: Date.now(),
      };

      await db.runAsync(
        `UPDATE containers
            SET name = ?, visual_type = ?, space_id = ?, updated_at = ?
          WHERE id = ?`,
        [next.name, next.visualType, next.spaceId, next.updatedAt, id],
      );

      return next;
    },

    async deletionImpact(id: string): Promise<ContainerDeletionImpact> {
      const row = await db.getFirstAsync<{
        item_count: number;
        photo_count: number;
        qr_count: number;
      }>(
        `SELECT
           (SELECT COUNT(*) FROM items WHERE container_id = ?1) AS item_count,
           (SELECT COUNT(*) FROM item_photos p JOIN items i ON i.id = p.item_id
             WHERE i.container_id = ?1) AS photo_count,
           (SELECT COUNT(*) FROM qr_bindings WHERE container_id = ?1) AS qr_count`,
        [id],
      );

      return {
        itemCount: row?.item_count ?? 0,
        photoCount: row?.photo_count ?? 0,
        hasQrBinding: (row?.qr_count ?? 0) > 0,
      };
    },

    async delete(id: string): Promise<{ deleted: boolean; orphanedPhotoUris: string[] }> {
      let deleted = false;
      let orphanedPhotoUris: string[] = [];

      await db.withTransactionAsync(async () => {
        const photos = await db.getAllAsync<{ uri: string }>(
          `SELECT p.uri FROM item_photos p
             JOIN items i ON i.id = p.item_id
            WHERE i.container_id = ?`,
          [id],
        );
        orphanedPhotoUris = photos.map((photo) => photo.uri);

        const result = await db.runAsync('DELETE FROM containers WHERE id = ?', [id]);
        deleted = result.changes > 0;
      });

      return { deleted, orphanedPhotoUris };
    },

    /** Container picker used when binding an unknown QR token. */
    async listAllWithSpace(): Promise<(Container & { spaceName: string; itemCount: number })[]> {
      const rows = await db.getAllAsync<ContainerRow & { space_name: string; item_count: number }>(
        `SELECT c.*, s.name AS space_name,
                (SELECT COUNT(*) FROM items i WHERE i.container_id = c.id) AS item_count
           FROM containers c
           JOIN spaces s ON s.id = c.space_id
          WHERE c.kind = 'normal'
          ORDER BY s.name COLLATE NOCASE ASC, c.created_at DESC`,
      );

      return rows.map((row) => ({
        ...toContainer(row),
        spaceName: row.space_name,
        itemCount: row.item_count,
      }));
    },
  };
}

export type ContainersRepository = ReturnType<typeof createContainersRepository>;
