import type { SqlDatabase } from '../../src/db/types.ts';
import type { HouseholdDump } from '../../src/services/household/dump.ts';
import { r2ObjectKey } from './photos.ts';

const ID = /^[\w.-]{1,80}$/;

function asId(value: unknown): string | null {
  return typeof value === 'string' && ID.test(value) ? value : null;
}

/**
 * Id-preserving upsert. Never REPLACE — a REPLACE would delete child rows
 * through ON DELETE CASCADE and then insert a hollow parent (K16).
 */
export async function applyHouseholdDump(db: SqlDatabase, dump: HouseholdDump): Promise<void> {
  await db.withTransactionAsync(async () => {
    for (const space of dump.spaces) {
      const id = asId(space.id);
      if (!id) continue;
      await db.runAsync(
        `INSERT INTO spaces (id, name, icon, color, created_at, updated_at, kind)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
           name = excluded.name,
           icon = excluded.icon,
           color = excluded.color,
           updated_at = excluded.updated_at,
           kind = excluded.kind`,
        [
          id,
          String(space.name ?? ''),
          String(space.icon ?? 'cube'),
          String(space.color ?? '#5B8DEF'),
          Number(space.createdAt) || 0,
          Number(space.updatedAt) || 0,
          String(space.kind ?? 'normal'),
        ],
      );
    }

    for (const container of dump.containers) {
      const id = asId(container.id);
      const spaceId = asId(container.spaceId);
      if (!id || !spaceId) continue;
      await db.runAsync(
        `INSERT INTO containers
           (id, space_id, name, visual_type, short_code, created_at, updated_at, kind)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
           space_id = excluded.space_id,
           name = excluded.name,
           visual_type = excluded.visual_type,
           short_code = excluded.short_code,
           updated_at = excluded.updated_at,
           kind = excluded.kind`,
        [
          id,
          spaceId,
          container.name ?? null,
          String(container.visualType ?? 'box'),
          String(container.shortCode ?? id),
          Number(container.createdAt) || 0,
          Number(container.updatedAt) || 0,
          String(container.kind ?? 'normal'),
        ],
      );
    }

    for (const item of dump.items) {
      const id = asId(item.id);
      const containerId = asId(item.containerId);
      if (!id || !containerId) continue;
      const name = String(item.name ?? '');
      const category = item.category ?? null;
      const searchText = item.searchText || `${name} ${category ?? ''}`.trim().toLowerCase();
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
          id,
          containerId,
          name,
          category,
          Number.isInteger(item.quantity) && item.quantity >= 1 ? item.quantity : 1,
          item.notes ?? null,
          Number(item.createdAt) || 0,
          Number(item.updatedAt) || 0,
          searchText,
        ],
      );
    }

    for (const tag of dump.tags) {
      const id = asId(tag.id);
      if (!id) continue;
      await db.runAsync(
        `INSERT INTO tags (id, name, normalized_name, created_at)
         VALUES (?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
           name = excluded.name,
           normalized_name = excluded.normalized_name`,
        [
          id,
          String(tag.name ?? ''),
          String(tag.normalizedName ?? String(tag.name ?? '').toLowerCase()),
          Number(tag.createdAt) || 0,
        ],
      );
    }

    for (const link of dump.itemTags) {
      const itemId = asId(link.itemId);
      const tagId = asId(link.tagId);
      if (!itemId || !tagId) continue;
      await db.runAsync('INSERT OR IGNORE INTO item_tags (item_id, tag_id) VALUES (?, ?)', [
        itemId,
        tagId,
      ]);
    }

    for (const binding of dump.qrBindings) {
      const id = asId(binding.id);
      const containerId = asId(binding.containerId);
      if (!id || !containerId || typeof binding.token !== 'string') continue;
      await db.runAsync(
        `INSERT INTO qr_bindings (id, token, container_id, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
           token = excluded.token,
           container_id = excluded.container_id,
           updated_at = excluded.updated_at`,
        [
          id,
          binding.token,
          containerId,
          Number(binding.createdAt) || 0,
          Number(binding.updatedAt) || 0,
        ],
      );
    }

    for (const photo of dump.photos) {
      const id = asId(photo.id);
      const itemId = asId(photo.itemId);
      if (!id || !itemId) continue;
      const uri = `r2:${r2ObjectKey(id, 'full')}`;
      const thumbUri = `r2:${r2ObjectKey(id, 'thumb')}`;
      await db.runAsync(
        `INSERT INTO item_photos
           (id, item_id, uri, thumb_uri, width, height, byte_size, created_at, remote_synced_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
           item_id = excluded.item_id,
           uri = excluded.uri,
           thumb_uri = excluded.thumb_uri,
           width = excluded.width,
           height = excluded.height,
           byte_size = excluded.byte_size,
           remote_synced_at = excluded.remote_synced_at`,
        [
          id,
          itemId,
          uri,
          thumbUri,
          photo.width,
          photo.height,
          photo.byteSize,
          Number(photo.createdAt) || 0,
          Date.now(),
        ],
      );
    }
  });
}
