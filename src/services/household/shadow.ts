import { newId } from '@/core/id';
import type { Repositories } from '@/db/repositories';
import type { Container, Item, ItemWithContext, Space, SqlDatabase } from '@/db/types';
import { logEvent } from '@/services/telemetry';

/**
 * Mirrors a successful household write into local SQLite so the old
 * inventory-sync snapshots keep covering overlap (K5). Failures here must
 * not fail the server write — the home server is the source of truth.
 */
export function withLocalShadow(remote: Repositories, local: Repositories): Repositories {
  const db = local.db;

  return {
    db: remote.db,
    spaces: {
      ...remote.spaces,
      async create(input) {
        const space = await remote.spaces.create(input);
        await shadow(() => upsertSpace(db, space));
        return space;
      },
      async update(id, input) {
        const space = await remote.spaces.update(id, input);
        if (space) await shadow(() => upsertSpace(db, space));
        return space;
      },
      async delete(id) {
        const result = await remote.spaces.delete(id);
        if (result.deleted)
          await shadow(() => db.runAsync('DELETE FROM spaces WHERE id = ?', [id]));
        return result;
      },
    },
    containers: {
      ...remote.containers,
      async create(input) {
        const container = await remote.containers.create(input);
        await shadow(() => upsertContainer(db, container));
        return container;
      },
      async update(id, input) {
        const container = await remote.containers.update(id, input);
        if (container) await shadow(() => upsertContainer(db, container));
        return container;
      },
      async delete(id) {
        const result = await remote.containers.delete(id);
        if (result.deleted) {
          await shadow(() => db.runAsync('DELETE FROM containers WHERE id = ?', [id]));
        }
        return result;
      },
    },
    items: {
      ...remote.items,
      async create(draft) {
        const item = await remote.items.create(draft);
        await shadow(async () => {
          if (isItemWithContext(item)) await upsertItemGraph(db, item);
          else await upsertItemRow(db, item);
        });
        return item;
      },
      async update(id, input) {
        const item = await remote.items.update(id, input);
        if (item) await shadow(() => upsertItemRow(db, item));
        return item;
      },
      async delete(id) {
        const result = await remote.items.delete(id);
        if (result.deleted) await shadow(() => db.runAsync('DELETE FROM items WHERE id = ?', [id]));
        return result;
      },
    },
    qr: {
      ...remote.qr,
      async bind(token, containerId) {
        const binding = await remote.qr.bind(token, containerId);
        await shadow(() => upsertQr(db, binding));
        return binding;
      },
      async createAndBind(containerId) {
        const binding = await remote.qr.createAndBind(containerId);
        await shadow(() => upsertQr(db, binding));
        return binding;
      },
      async unbind(containerId) {
        const unbound = await remote.qr.unbind(containerId);
        if (unbound) {
          await shadow(() =>
            db.runAsync('DELETE FROM qr_bindings WHERE container_id = ?', [containerId]),
          );
        }
        return unbound;
      },
    },
    search: remote.search,
  };
}

async function shadow(work: () => Promise<unknown>): Promise<void> {
  try {
    await work();
  } catch (error) {
    logEvent('household_shadow_failed', {
      errorClass: error instanceof Error ? error.name : 'unknown',
    });
  }
}

function isItemWithContext(item: Item): item is ItemWithContext {
  return 'spaceId' in item && typeof (item as ItemWithContext).spaceId === 'string';
}

async function upsertSpace(db: SqlDatabase, space: Space): Promise<void> {
  await db.runAsync(
    `INSERT INTO spaces (id, name, icon, color, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       name = excluded.name,
       icon = excluded.icon,
       color = excluded.color,
       updated_at = excluded.updated_at`,
    [space.id, space.name, space.icon, space.color, space.createdAt, space.updatedAt],
  );
}

async function upsertContainer(db: SqlDatabase, container: Container): Promise<void> {
  await db.runAsync(
    `INSERT INTO containers
       (id, space_id, name, visual_type, short_code, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       space_id = excluded.space_id,
       name = excluded.name,
       visual_type = excluded.visual_type,
       short_code = excluded.short_code,
       updated_at = excluded.updated_at`,
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
}

async function upsertItemRow(db: SqlDatabase, item: Item): Promise<void> {
  const searchText = `${item.name} ${item.category ?? ''}`.trim().toLowerCase();
  await db.runAsync(
    `INSERT INTO items
       (id, container_id, name, category, quantity, notes, created_at, updated_at, search_text)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       container_id = excluded.container_id,
       name = excluded.name,
       category = excluded.category,
       quantity = excluded.quantity,
       notes = excluded.notes,
       updated_at = excluded.updated_at,
       search_text = excluded.search_text`,
    [
      item.id,
      item.containerId,
      item.name,
      item.category,
      item.quantity,
      item.notes,
      item.createdAt,
      item.updatedAt,
      searchText,
    ],
  );
}

async function upsertItemGraph(db: SqlDatabase, item: ItemWithContext): Promise<void> {
  await upsertSpace(db, {
    id: item.spaceId,
    name: item.spaceName,
    icon: item.spaceIcon,
    color: item.spaceColor,
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
  });
  await upsertContainer(db, {
    id: item.containerId,
    spaceId: item.spaceId,
    name: item.containerName,
    visualType: 'box',
    shortCode: item.containerShortCode || `CTR-${item.containerId.slice(0, 4).toUpperCase()}`,
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
  });
  await upsertItemRow(db, item);

  if (item.photoId && item.photoUri) {
    await db.runAsync(
      `INSERT INTO item_photos
         (id, item_id, uri, thumb_uri, width, height, byte_size, created_at, remote_synced_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         uri = excluded.uri,
         thumb_uri = excluded.thumb_uri,
         remote_synced_at = excluded.remote_synced_at`,
      [
        item.photoId,
        item.id,
        item.photoUri,
        item.photoThumbUri,
        null,
        null,
        null,
        item.createdAt,
        Date.now(),
      ],
    );
  }

  await db.runAsync('DELETE FROM item_tags WHERE item_id = ?', [item.id]);
  for (const raw of item.tags) {
    const name = raw.trim();
    const normalized = name.toLowerCase();
    if (!normalized) continue;
    const existing = await db.getFirstAsync<{ id: string }>(
      'SELECT id FROM tags WHERE normalized_name = ?',
      [normalized],
    );
    const tagId = existing?.id ?? newId();
    if (!existing) {
      await db.runAsync(
        'INSERT INTO tags (id, name, normalized_name, created_at) VALUES (?, ?, ?, ?)',
        [tagId, name, normalized, Date.now()],
      );
    }
    await db.runAsync('INSERT OR IGNORE INTO item_tags (item_id, tag_id) VALUES (?, ?)', [
      item.id,
      tagId,
    ]);
  }
}

async function upsertQr(
  db: SqlDatabase,
  binding: { id: string; token: string; containerId: string; createdAt: number; updatedAt: number },
): Promise<void> {
  await db.runAsync('DELETE FROM qr_bindings WHERE token = ? OR container_id = ?', [
    binding.token,
    binding.containerId,
  ]);
  await db.runAsync(
    `INSERT INTO qr_bindings (id, token, container_id, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?)`,
    [binding.id, binding.token, binding.containerId, binding.createdAt, binding.updatedAt],
  );
}
