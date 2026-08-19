import type { SqlDatabase } from '@/db/types';

import type {
  DumpContainer,
  DumpItem,
  DumpItemTag,
  DumpPhoto,
  DumpQrBinding,
  DumpSpace,
  DumpTag,
  HouseholdDump,
} from './dump';

/** Reads the local inventory as an id-preserving dump for household import. */
export async function collectHouseholdDump(db: SqlDatabase): Promise<HouseholdDump> {
  const spaces = await db.getAllAsync<{
    id: string;
    name: string;
    icon: string;
    color: string;
    kind: string;
    created_at: number;
    updated_at: number;
  }>('SELECT id, name, icon, color, kind, created_at, updated_at FROM spaces');

  const containers = await db.getAllAsync<{
    id: string;
    space_id: string;
    name: string | null;
    visual_type: string;
    short_code: string;
    kind: string;
    created_at: number;
    updated_at: number;
  }>(
    'SELECT id, space_id, name, visual_type, short_code, kind, created_at, updated_at FROM containers',
  );

  const items = await db.getAllAsync<{
    id: string;
    container_id: string;
    name: string;
    category: string | null;
    quantity: number;
    notes: string | null;
    search_text: string;
    created_at: number;
    updated_at: number;
  }>(
    'SELECT id, container_id, name, category, quantity, notes, search_text, created_at, updated_at FROM items',
  );

  const tags = await db.getAllAsync<{
    id: string;
    name: string;
    normalized_name: string;
    created_at: number;
  }>('SELECT id, name, normalized_name, created_at FROM tags');

  const itemTags = await db.getAllAsync<{ item_id: string; tag_id: string }>(
    'SELECT item_id, tag_id FROM item_tags',
  );

  const qrBindings = await db.getAllAsync<{
    id: string;
    token: string;
    container_id: string;
    created_at: number;
    updated_at: number;
  }>('SELECT id, token, container_id, created_at, updated_at FROM qr_bindings');

  const photos = await db.getAllAsync<{
    id: string;
    item_id: string;
    uri: string;
    width: number | null;
    height: number | null;
    byte_size: number | null;
    created_at: number;
  }>('SELECT id, item_id, uri, width, height, byte_size, created_at FROM item_photos');

  return {
    spaces: spaces.map((row): DumpSpace => ({
      id: row.id,
      name: row.name,
      icon: row.icon,
      color: row.color,
      kind: row.kind,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    })),
    containers: containers.map((row): DumpContainer => ({
      id: row.id,
      spaceId: row.space_id,
      name: row.name,
      visualType: row.visual_type,
      shortCode: row.short_code,
      kind: row.kind,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    })),
    items: items.map((row): DumpItem => ({
      id: row.id,
      containerId: row.container_id,
      name: row.name,
      category: row.category,
      quantity: row.quantity,
      notes: row.notes,
      searchText: row.search_text,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    })),
    tags: tags.map((row): DumpTag => ({
      id: row.id,
      name: row.name,
      normalizedName: row.normalized_name,
      createdAt: row.created_at,
    })),
    itemTags: itemTags.map((row): DumpItemTag => ({
      itemId: row.item_id,
      tagId: row.tag_id,
    })),
    qrBindings: qrBindings.map((row): DumpQrBinding => ({
      id: row.id,
      token: row.token,
      containerId: row.container_id,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    })),
    photos: photos.map((row): DumpPhoto => ({
      id: row.id,
      itemId: row.item_id,
      width: row.width,
      height: row.height,
      byteSize: row.byte_size,
      createdAt: row.created_at,
    })),
  };
}

export async function localPhotoUris(db: SqlDatabase): Promise<Map<string, string>> {
  const rows = await db.getAllAsync<{ id: string; uri: string }>('SELECT id, uri FROM item_photos');
  return new Map(rows.map((row) => [row.id, row.uri]));
}
