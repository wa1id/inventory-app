/**
 * Generates the InventoryStorage database fixtures from the real TypeScript
 * migrations and repositories, running on node:sqlite (src/db/nodeDatabase.ts).
 *
 * Not part of the RN test suite. To regenerate (see native-ios/docs/CONVENTIONS.md):
 *
 *   ln -s /home/walid/inventory-app/node_modules node_modules   # once, in a worktree
 *   mkdir -p src/__vectors__/__tests__
 *   cp native-ios/Packages/InventoryKit/Tests/InventoryStorageTests/Fixtures/db/generator/db-fixtures.test.ts \
 *      src/__vectors__/__tests__/
 *   npx jest src/__vectors__ --selectProjects logic
 *   rm -r src/__vectors__
 *
 * Output lands next to this folder, in Tests/InventoryStorageTests/Fixtures/db/.
 * Ids, short codes and clocks are seeded, so regenerating gives the same data.
 */
import { copyFileSync, existsSync, mkdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

import { configureRandomBytes } from '@/core/id';
import { LATEST_SCHEMA_VERSION, MIGRATIONS, migrate } from '@/db/migrations';
import { openNodeDatabase } from '@/db/nodeDatabase';
import { initializeRepositories, type Repositories } from '@/db/repositories';
import type { SqlDatabase } from '@/db/types';

const OUT = join(__dirname, '../../../native-ios/Packages/InventoryKit/Tests/InventoryStorageTests/Fixtures/db');
const SCRATCH = join(tmpdir(), `inventory-db-fixtures-${process.pid}`);

type Value = string | number | null;
type Row = Record<string, Value>;

function write(name: string, data: unknown, pretty = true): void {
  writeFileSync(join(OUT, name), `${pretty ? JSON.stringify(data, null, 1) : JSON.stringify(data)}\n`);
}

function removeDb(path: string): void {
  for (const suffix of ['', '-wal', '-shm']) rmSync(`${path}${suffix}`, { force: true });
}

/** Deterministic PRNG so regenerating gives the same files. */
function lcg(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 0x100000000;
  };
}

async function insert(db: SqlDatabase, table: string, row: Row): Promise<void> {
  const columns = Object.keys(row);
  await db.runAsync(
    `INSERT INTO ${table} (${columns.join(', ')}) VALUES (${columns.map(() => '?').join(', ')})`,
    columns.map((column) => row[column] ?? null),
  );
}

const USER_TABLES = [
  'spaces',
  'containers',
  'items',
  'item_photos',
  'tags',
  'item_tags',
  'qr_bindings',
  'sync_deletions',
];

async function existingTables(db: SqlDatabase): Promise<string[]> {
  const rows = await db.getAllAsync<{ name: string }>(
    `SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY rowid`,
  );
  return rows.map((row) => row.name);
}

async function dumpTables(db: SqlDatabase): Promise<Record<string, Row[]>> {
  const out: Record<string, Row[]> = {};
  for (const table of await existingTables(db)) {
    out[table] = await db.getAllAsync<Row>(`SELECT * FROM "${table}" ORDER BY rowid`);
  }
  return out;
}

async function countTables(db: SqlDatabase): Promise<Record<string, number>> {
  const out: Record<string, number> = {};
  for (const table of await existingTables(db)) {
    const row = await db.getFirstAsync<{ n: number }>(`SELECT COUNT(*) AS n FROM "${table}"`);
    out[table] = row?.n ?? 0;
  }
  return out;
}

async function sqliteMaster(db: SqlDatabase) {
  return db.getAllAsync<{ type: string; name: string; tbl_name: string; sql: string | null }>(
    'SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY rowid',
  );
}

async function userVersion(db: SqlDatabase): Promise<number> {
  const row = await db.getFirstAsync<{ user_version: number }>('PRAGMA user_version');
  return row?.user_version ?? 0;
}

// ---------------------------------------------------------------------------
// Historical databases: real migrations stopped at each version, with rows
// written in the shape that version's schema had.

const searchTextFor = (name: string, category: string | null) =>
  `${name} ${category ?? ''}`.trim().toLowerCase();

function itemRow(
  version: number,
  item: {
    id: string;
    container_id: string;
    name: string;
    category: string | null;
    quantity: number;
    notes: string | null;
    created_at: number;
    estimated_value?: number;
    currency?: string;
  },
): Row {
  const row: Row = {
    id: item.id,
    container_id: item.container_id,
    name: item.name,
    category: item.category,
    quantity: item.quantity,
    notes: item.notes,
    created_at: item.created_at,
    updated_at: item.created_at,
  };
  if (version < 6) {
    row.estimated_value = item.estimated_value ?? null;
    row.currency = item.currency ?? null;
  }
  if (version >= 2) row.search_text = searchTextFor(item.name, item.category);
  return row;
}

function photoRow(
  version: number,
  photo: {
    id: string;
    item_id: string;
    uri: string;
    thumb_uri: string | null;
    width: number | null;
    height: number | null;
    byte_size: number | null;
    created_at: number;
    remote_synced_at: number | null;
  },
): Row {
  const row: Row = {
    id: photo.id,
    item_id: photo.item_id,
    uri: photo.uri,
    width: photo.width,
    height: photo.height,
    byte_size: photo.byte_size,
    created_at: photo.created_at,
  };
  if (version >= 4) row.remote_synced_at = photo.remote_synced_at;
  if (version >= 5) row.thumb_uri = photo.thumb_uri;
  return row;
}

const OLD_CONTAINER = 'file:///var/mobile/Containers/Data/Application/0A1B2C3D-0000-4000-8000-000000000001/Documents';

async function seedAt(db: SqlDatabase, version: number): Promise<void> {
  if (version < 1) return;

  await insert(db, 'spaces', {
    id: 'sp-garage', name: 'Garage', icon: 'car', color: '#5B8DEF', created_at: 1000, updated_at: 1000,
  });
  await insert(db, 'spaces', {
    id: 'sp-kitchen', name: 'Küche', icon: '🍳', color: '#E4572E', created_at: 1001, updated_at: 1001,
  });

  await insert(db, 'containers', {
    id: 'ct-toolbox', space_id: 'sp-garage', name: 'Tool Box', visual_type: 'box', short_code: 'BOX-7K2M',
    created_at: 1100, updated_at: 1100,
  });
  await insert(db, 'containers', {
    id: 'ct-drawer', space_id: 'sp-kitchen', name: null, visual_type: 'drawer', short_code: 'DRW-ABCD',
    created_at: 1101, updated_at: 1101,
  });
  await insert(db, 'containers', {
    id: 'ct-shelf', space_id: 'sp-garage', name: 'Top shelf', visual_type: 'shelf', short_code: 'SHF-2345',
    created_at: 1102, updated_at: 1102,
  });

  await insert(db, 'items', itemRow(version, {
    id: 'it-drill', container_id: 'ct-toolbox', name: 'Cordless Drill', category: 'Power Tools', quantity: 1,
    notes: 'Charger in side pocket', created_at: 1200, estimated_value: 129.99, currency: 'EUR',
  }));
  // Non-ASCII capitals: the v2 backfill uses SQLite's ASCII-only LOWER, so this keeps its Ä.
  await insert(db, 'items', itemRow(version, {
    id: 'it-armel', container_id: 'ct-drawer', name: 'ÄRMEL Schoner', category: null, quantity: 2,
    notes: null, created_at: 1201,
  }));
  await insert(db, 'items', itemRow(version, {
    id: 'it-nails', container_id: 'ct-shelf', name: 'Nails', category: 'Hardware', quantity: 500,
    notes: 'Mixed sizes', created_at: 1202,
  }));
  await insert(db, 'items', itemRow(version, {
    id: 'it-cable', container_id: 'ct-toolbox', name: 'USB-C cable', category: null, quantity: 3,
    notes: null, created_at: 1203, estimated_value: 4.5, currency: 'USD',
  }));
  if (version >= 3) {
    await insert(db, 'items', itemRow(version, {
      id: 'it-unnamed', container_id: 'drop-zone', name: '', category: null, quantity: 1, notes: null,
      created_at: 1204,
    }));
  }

  await insert(db, 'item_photos', photoRow(version, {
    id: 'ph-drill', item_id: 'it-drill', uri: `${OLD_CONTAINER}/item-photos/7f3c.webp`,
    thumb_uri: `${OLD_CONTAINER}/item-photos/7f3c-thumb.webp`, width: 1400, height: 1050, byte_size: 210000,
    created_at: 1200, remote_synced_at: 1500,
  }));
  await insert(db, 'item_photos', photoRow(version, {
    id: 'ph-drill-later', item_id: 'it-drill', uri: `${OLD_CONTAINER}/item-photos/later.webp`, thumb_uri: null,
    width: 320, height: 240, byte_size: 9000, created_at: 1250, remote_synced_at: null,
  }));
  await insert(db, 'item_photos', photoRow(version, {
    id: 'ph-nails', item_id: 'it-nails', uri: `${OLD_CONTAINER}/item-photos/legacy.jpg`, thumb_uri: null,
    width: null, height: null, byte_size: null, created_at: 1202, remote_synced_at: null,
  }));

  await insert(db, 'tags', { id: 'tg-dewalt', name: 'DeWalt', normalized_name: 'dewalt', created_at: 1200 });
  await insert(db, 'tags', { id: 'tg-18v', name: '18V', normalized_name: '18v', created_at: 1200 });
  await insert(db, 'tags', { id: 'tg-hw', name: 'hardware', normalized_name: 'hardware', created_at: 1202 });
  for (const [item_id, tag_id] of [
    ['it-drill', 'tg-dewalt'],
    ['it-drill', 'tg-18v'],
    ['it-nails', 'tg-hw'],
    ['it-cable', 'tg-hw'],
  ]) {
    await insert(db, 'item_tags', { item_id, tag_id });
  }

  await insert(db, 'qr_bindings', {
    id: 'qr-1', token: 'ab'.repeat(16), container_id: 'ct-toolbox', created_at: 1300, updated_at: 1300,
  });
  await insert(db, 'qr_bindings', {
    id: 'qr-2', token: 'cd'.repeat(16), container_id: 'ct-shelf', created_at: 1301, updated_at: 1301,
  });

  if (version >= 4) {
    await insert(db, 'sync_deletions', { photo_id: 'ph-old', deleted_at: 1600 });
  }
}

async function generateHistorical(): Promise<void> {
  const dir = join(OUT, 'historical');
  mkdirSync(dir, { recursive: true });
  const fixtures = [];

  for (let version = 0; version < LATEST_SCHEMA_VERSION; version += 1) {
    const file = `v${version}.db`;
    const path = join(dir, file);
    removeDb(path);

    const db = openNodeDatabase(path);
    const reached = await migrate(db, MIGRATIONS.slice(0, version));
    expect(reached).toBe(version);
    await seedAt(db, version);
    const before = await countTables(db);
    const schemaBefore = await sqliteMaster(db);
    await db.closeAsync();
    expect(existsSync(`${path}-wal`)).toBe(false);

    // What the TypeScript runner makes of a copy of that file.
    const copy = join(SCRATCH, file);
    removeDb(copy);
    copyFileSync(path, copy);
    const migrated = openNodeDatabase(copy);
    expect(await migrate(migrated)).toBe(LATEST_SCHEMA_VERSION);
    const after = await dumpTables(migrated);
    const fk = await migrated.getAllAsync('PRAGMA foreign_key_check');
    expect(fk).toEqual([]);
    await migrated.closeAsync();
    removeDb(copy);

    fixtures.push({
      version,
      file,
      byteSize: statSync(path).size,
      countsBefore: before,
      schemaBefore,
      expectedAfter: after,
    });
  }

  write('historical.json', { fixtures });
}

// ---------------------------------------------------------------------------
// A database at user_version 4 whose newest rows live only in the -wal file,
// as an RN build killed before a checkpoint would leave it.

async function generateWal(): Promise<void> {
  const dir = join(OUT, 'wal');
  mkdirSync(dir, { recursive: true });
  const live = join(SCRATCH, 'wal-live.db');
  removeDb(live);

  const handle = new DatabaseSync(live);
  handle.exec('PRAGMA journal_mode = WAL');
  handle.exec('PRAGMA foreign_keys = ON');
  handle.exec('PRAGMA wal_autocheckpoint = 0');
  const db: SqlDatabase = {
    execAsync: async (sql) => {
      handle.exec(sql);
    },
    runAsync: async (sql, params = []) => ({ changes: Number(handle.prepare(sql).run(...params).changes) }),
    getAllAsync: async <T,>(sql: string, params: Value[] = []) => handle.prepare(sql).all(...params) as T[],
    getFirstAsync: async <T,>(sql: string, params: Value[] = []) =>
      (handle.prepare(sql).get(...params) as T | undefined) ?? null,
    withTransactionAsync: async (task) => {
      handle.exec('BEGIN');
      try {
        await task();
        handle.exec('COMMIT');
      } catch (error) {
        handle.exec('ROLLBACK');
        throw error;
      }
    },
    closeAsync: async () => handle.close(),
  };

  expect(await migrate(db, MIGRATIONS.slice(0, 4))).toBe(4);
  await seedAt(db, 4);
  handle.exec('PRAGMA wal_checkpoint(TRUNCATE)');

  // Committed, never checkpointed.
  await insert(db, 'spaces', {
    id: 'sp-wal', name: 'Shed', icon: 'box', color: '#2E9E4F', created_at: 2000, updated_at: 2000,
  });
  await insert(db, 'containers', {
    id: 'ct-wal', space_id: 'sp-wal', name: 'Crate in the shed', visual_type: 'crate', short_code: 'CRT-WAL2',
    created_at: 2001, updated_at: 2001,
  });
  await insert(db, 'items', itemRow(4, {
    id: 'it-wal', container_id: 'ct-wal', name: 'Lawn Mower Blade', category: 'Garden', quantity: 1,
    notes: null, created_at: 2002,
  }));
  await insert(db, 'item_photos', photoRow(4, {
    id: 'ph-wal', item_id: 'it-wal', uri: `${OLD_CONTAINER}/item-photos/blade.webp`, thumb_uri: null,
    width: 1400, height: 1400, byte_size: 1234, created_at: 2002, remote_synced_at: null,
  }));
  await insert(db, 'item_tags', { item_id: 'it-wal', tag_id: 'tg-hw' });
  await db.runAsync('UPDATE items SET quantity = 7, updated_at = 2003 WHERE id = ?', ['it-nails']);

  for (const suffix of ['', '-wal', '-shm']) {
    copyFileSync(`${live}${suffix}`, join(dir, `v4.db${suffix}`));
  }
  handle.close();
  removeDb(live);

  // The main file alone must not have the rows, or the fixture tests nothing.
  const mainOnly = join(SCRATCH, 'wal-main-only.db');
  removeDb(mainOnly);
  copyFileSync(join(dir, 'v4.db'), mainOnly);
  const bare = new DatabaseSync(mainOnly);
  expect(bare.prepare("SELECT COUNT(*) AS n FROM items WHERE id = 'it-wal'").get()).toEqual({ n: 0 });
  bare.close();
  removeDb(mainOnly);

  // With the sidecar next to it, they are there.
  const withWal = join(SCRATCH, 'wal-with.db');
  removeDb(withWal);
  copyFileSync(join(dir, 'v4.db'), withWal);
  copyFileSync(join(dir, 'v4.db-wal'), `${withWal}-wal`);
  const replayed = openNodeDatabase(withWal);
  expect(await migrate(replayed)).toBe(LATEST_SCHEMA_VERSION);
  const after = await dumpTables(replayed);
  await replayed.closeAsync();
  removeDb(withWal);

  write('wal.json', {
    userVersion: 4,
    walOnly: { spaces: ['sp-wal'], containers: ['ct-wal'], items: ['it-wal'], item_photos: ['ph-wal'] },
    updatedInWal: { id: 'it-nails', quantity: 7, updated_at: 2003 },
    expectedAfter: after,
  });
}

// ---------------------------------------------------------------------------
// A v7 inventory built through the repositories, plus what the TypeScript
// repositories return for a broad set of searches and reads over it.

async function buildSearchInventory(repos: Repositories) {
  const space = (name: string, icon: string, color: string) => repos.spaces.create({ name, icon, color });
  const garage = await space('Garage', 'car', '#5B8DEF');
  const kitchen = await space('Kitchen', 'pot', '#E4572E');
  const kuche = await space('Küche', '🍳', '#F4A259');
  const kids = await space("Kid's room", '🧸', '#8E7DBE');
  const office = await space('Office/Studio', '💼', '#2E9E4F');
  const bureau = await space('Bureau 2.0', 'desk', '#0F9BB0');
  const warehouse = await space('Warehouse', 'box', '#5B8DEF');
  await space('ÄRMEL Lager', 'box', '#999999');

  const container = (spaceId: string, visualType: string, name?: string | null) =>
    repos.containers.create({ spaceId, visualType: visualType as never, name });
  const toolBox = await container(garage.id, 'box', 'Tool Box');
  const drawer = await container(kitchen.id, 'drawer', 'Utensil Drawer');
  const crate = await container(garage.id, 'crate');
  const parts = await container(garage.id, 'bin', 'Spare Parts');
  const cafeShelf = await container(kitchen.id, 'shelf', 'Café Shelf');
  const usbBox = await container(office.id, 'box', 'USB-C box');
  const tray = await container(bureau.id, 'other', 'Лоток');
  const japanese = await container(kids.id, 'cabinet', '収納ボックス');
  const spices = await container(kuche.id, 'drawer', 'Gewürze');
  const bag = await container(kids.id, 'bag', "o'neil bag");
  const bins = [];
  for (let n = 1; n <= 34; n += 1) {
    bins.push(await container(warehouse.id, 'bin', `Bin ${String(n).padStart(2, '0')}`));
  }

  const item = (containerId: string, fields: Record<string, unknown> = {}) =>
    repos.items.create({ containerId, ...(fields as object) });
  const photo = (name: string, thumb = true) => ({
    uri: `file:///var/mobile/Containers/Data/Application/SEARCH/Documents/item-photos/${name}.webp`,
    ...(thumb ? { thumbUri: `file:///var/mobile/Containers/Data/Application/SEARCH/Documents/item-photos/${name}-thumb.webp` } : {}),
    width: 1400,
    height: 1050,
    byteSize: 120_000,
  });

  const drill = await item(toolBox.id, {
    name: 'Cordless Drill', category: 'Power Tools', tags: ['dewalt', '18v', 'Werkzeug'], photo: photo('drill'),
    notes: 'Charger in the side pocket',
  });
  await item(toolBox.id, { name: 'Hammer', category: 'Hand Tools', tags: ['DeWalt'] });
  await item(drawer.id, { name: 'Whisk', category: 'Utensils' });
  await item(usbBox.id, { name: 'USB-C to USB-A cable', category: 'Cables', tags: ['usb'] });
  await item(usbBox.id, { name: 'Microusb cable', category: 'Cables', photo: photo('micro', false) });
  await item(parts.id, { name: 'Garage Door Remote' });
  await item(cafeShelf.id, { name: 'Café Mug', category: 'Kitchenware' });
  await item(spices.id, { name: 'ÄRMEL Jacke', category: 'Kleidung' });
  await item(spices.id, { name: 'Ölkanne', category: 'Küche' });
  await item(usbBox.id, { name: 'Straße map', category: 'Maps' });
  await item(bag.id, { name: "o'neil poster", tags: ["kid's"] });
  await item(bag.id, { name: 'under_score label', category: 'Labels' });
  await item(tray.id, { name: '50% off coupon' });
  await item(japanese.id, { name: 'ワイヤー', category: '工具' });
  await item(japanese.id, { name: 'ガラス cup' });
  await item(tray.id, { name: 'ΟΔΟΣ sign', category: 'Σήματα' });
  await item(crate.id, { name: 'Tent Pegs', category: 'Camping', quantity: 24 });
  await item(crate.id, { name: 'Nails', category: 'Hardware', quantity: 0, tags: ['hardware'] });
  await item(tray.id, { name: 'a\\b backslash file' });
  await item(drawer.id, { name: '™ trademark sticker' });
  await item(drawer.id, { name: 'ﬁle folder', notes: 'notes are not searched: zebra' });
  await item('drop-zone', {});
  await item('drop-zone', { name: 'Mystery cable', photo: photo('mystery') });
  await item('drop-zone', { name: 'Old phone charger', category: 'Cables' });
  const renamed = await item(toolBox.id, { name: 'Angle Grinder', category: 'Power Tools', tags: ['old tag'] });
  await repos.items.update(renamed.id, { name: 'Angle Grinder 125', tags: ['grinder', 'Bosch'] });
  const doomed = await item(toolBox.id, { name: 'Broken saw', tags: ['saw'] });
  await repos.items.delete(doomed.id);
  // A second, later photo: the earliest stays the primary.
  await repos.db.runAsync(
    `INSERT INTO item_photos (id, item_id, uri, thumb_uri, width, height, byte_size, created_at)
     VALUES (?, ?, ?, NULL, 10, 10, 10, ?)`,
    ['later-photo', drill.id, 'file:///later.webp', Date.now()],
  );
  for (let n = 0; n < 205; n += 1) {
    await item(bins[n % bins.length]!.id, { name: `Widget ${n}`, category: 'Parts' });
  }

  await repos.qr.createAndBind(toolBox.id);
  await repos.qr.createAndBind(drawer.id);
  const shared = await repos.qr.createAndBind(parts.id);
  await repos.qr.bind(shared.token, crate.id);

  return { garage, toolBox, crate };
}

const BASE_QUERIES = [
  '', '   ', 'drill', 'DRILL', 'cordless drill', 'usbc', 'usb-c', 'usb c', 'usb/c', 'USB', 'cable',
  'cables', 'garage', 'kitchen', 'küche', 'kuche', 'kuch', 'café', 'cafe', 'caf', 'drop', 'zone',
  'dropzone', 'drop zone', 'box', 'bin', 'bin 07', 'bin07', 'widget', 'widget 42', 'widget 2', '%', '_',
  '\\', 'a\\b', "o'neil", 'oneil', 'neil', 'under_score', 'underscore', 'under', 'score', 'ワイヤー',
  'ガラス', 'カラス', 'οδος', 'ΟΔΟΣ', 'σήματα', 'straße', 'strasse', 'ärmel', 'ÄRMEL', 'Ärmel', 'rmel',
  'ölkanne', 'Ölkanne', 'lkanne', 'dewalt', 'DeWalt', '18v', 'werkzeug', 'power tools', 'tools', 'tool',
  'garage drill', 'drill kitchen', 'drill garage tool box', 'kid', "kid's", 'kids', 'office', 'studio',
  'office/studio', 'officestudio', '2.0', '20', 'bureau', 'лоток', 'Лоток', '収納', '収納ボックス',
  'mystery', 'charger', 'nails', 'hardware', '0', '1', '24', 'tent', 'zebra', 'notes', '™', 'tm',
  'trademark', 'ﬁle', 'file', 'grinder', 'angle grinder 125', 'old tag', 'bosch', 'saw', 'broken',
  'cup', 'map', 'coupon', '50', '50%', 'spare parts', 'remote', 'door', 'utensil', 'whisk', 'mug',
  'jacke', 'kleidung', 'lager', 'shelf', 'crate', 'warehouse', 'e', 'a b c d e f g h i j k l m n',
  'parts widget 1', '-', '--', "'", '.', '/', 'p.art.s', "p'arts", 'p-a-r-t-s',
];

async function generateSearch(): Promise<void> {
  const dir = join(OUT, 'search');
  mkdirSync(dir, { recursive: true });
  const path = join(dir, 'inventory.db');
  removeDb(path);

  const bytes = lcg(0x5eed);
  const codes = lcg(0xc0de);
  configureRandomBytes((count) => Uint8Array.from({ length: count }, () => Math.floor(bytes() * 256)));
  const random = jest.spyOn(Math, 'random').mockImplementation(codes);
  let clock = 1_760_000_000_000;
  const now = jest.spyOn(Date, 'now').mockImplementation(() => {
    clock += 7;
    return clock;
  });

  try {
    const db = openNodeDatabase(path);
    const repos = await initializeRepositories(db);
    const { toolBox, crate } = await buildSearchInventory(repos);

    const spaces = await db.getAllAsync<{ id: string }>('SELECT id FROM spaces ORDER BY rowid');
    const containers = await db.getAllAsync<{ id: string; short_code: string }>(
      'SELECT id, short_code FROM containers ORDER BY rowid',
    );
    const itemIds = await db.getAllAsync<{ id: string }>('SELECT id FROM items ORDER BY rowid');
    const tokens = await db.getAllAsync<{ token: string }>('SELECT token FROM qr_bindings ORDER BY rowid');

    const codeQueries = containers
      .slice(0, 12)
      .flatMap((c) => [c.short_code, c.short_code.replace('-', ''), c.short_code.toLowerCase()]);
    const queries = [...BASE_QUERIES, ...codeQueries];

    // Each item's search projection is stored once; queries list ids in result order.
    const searchItems: Record<string, unknown> = {};
    const search = [];
    for (const query of queries) {
      const { terms, locations, items } = await repos.search.search(query);
      for (const { matchKind: _matchKind, ...row } of items) {
        const seen = searchItems[row.id];
        if (seen) expect(row).toEqual(seen);
        searchItems[row.id] = row;
      }
      search.push({ query, terms, locations, items: items.map((i) => [i.id, i.matchKind]) });
    }
    write('search-vectors.json', { items: searchItems, queries: search }, false);

    const reads = {
      listWithCounts: await repos.spaces.listWithCounts(),
      listAllWithSpace: await repos.containers.listAllWithSpace(),
      listUnsorted: await repos.items.listUnsorted(),
      countUnsorted: await repos.items.countUnsorted(),
      countAll: await repos.items.countAll(),
      listRecent: [] as { limit: number; items: unknown }[],
      spaces: [] as unknown[],
      containers: [] as unknown[],
      items: [] as unknown[],
      scans: [] as unknown[],
      tokens: [] as unknown[],
    };
    for (const limit of [40, 0, 3, 500]) {
      reads.listRecent.push({ limit, items: await repos.items.listRecent(limit) });
    }
    for (const { id } of [...spaces, { id: 'no-such-space' }]) {
      reads.spaces.push({
        id,
        getById: await repos.spaces.getById(id),
        deletionImpact: await repos.spaces.deletionImpact(id),
        listBySpace: await repos.containers.listBySpace(id),
      });
    }
    for (const { id } of [...containers, { id: 'no-such-container' }]) {
      reads.containers.push({
        id,
        getById: await repos.containers.getById(id),
        getWithCounts: await repos.containers.getWithCounts(id),
        deletionImpact: await repos.containers.deletionImpact(id),
        listByContainer: await repos.items.listByContainer(id),
        qrByContainer: await repos.qr.getByContainer(id),
      });
    }
    const sampledItems = itemIds.filter((_, index) => index < 40 || index % 50 === 0);
    for (const { id } of [...sampledItems, { id: 'no-such-item' }]) {
      reads.items.push({ id, getById: await repos.items.getById(id), getPhotos: await repos.items.getPhotos(id) });
    }
    const scans = [
      ...tokens.map((t) => `inventory://c/${t.token}`),
      tokens[0]!.token.toUpperCase(),
      ` ${tokens[1]!.token} `,
      `inventory://c/${'f'.repeat(32)}`,
      'f'.repeat(32),
      'INVENTORY://c/' + tokens[0]!.token,
      'https://example.com',
      '',
      'inventory://c/',
      'ab'.repeat(15),
    ];
    for (const raw of scans) reads.scans.push({ raw, outcome: await repos.qr.resolveScan(raw) });
    for (const token of [...tokens.map((t) => t.token), tokens[0]!.token.toUpperCase(), 'f'.repeat(32)]) {
      reads.tokens.push({ token, binding: await repos.qr.getByToken(token) });
    }
    write('reads.json', { toolBoxId: toolBox.id, crateId: crate.id, ...reads }, false);

    await db.closeAsync();
    expect(existsSync(`${path}-wal`)).toBe(false);
  } finally {
    random.mockRestore();
    now.mockRestore();
  }
}

// ---------------------------------------------------------------------------
// Write parity: one script of repository writes, run through the TypeScript
// repositories with a seeded clock, id bytes and short codes. WriteParityTests
// replays the same script through the Swift repositories with the same seeds
// and compares every result, every error and every table row, so a drift in
// trimming, folding, NULL handling or statement order cannot hide behind
// read-only parity. Strings starting with `@` refer to earlier results:
// `@alias` is its id, `@alias.field` one of its fields.

/** Seeds shared with WriteParityTests. */
const WRITE_SEEDS = { clockStart: 1_770_000_000_000, clockStep: 3, idSeed: 0x1d5eed, codeSeed: 0xc0dec0de };

type WriteOp = { op: string; as?: string; [key: string]: unknown };

const WRITE_OPS: WriteOp[] = [
  // SQL-stamped values (migration 3's seed rows, the tombstone trigger) use the wall clock.
  { op: 'sql', sql: "UPDATE spaces SET created_at = 0, updated_at = 0 WHERE kind = 'system'" },
  { op: 'sql', sql: "UPDATE containers SET created_at = 0, updated_at = 0 WHERE kind = 'system'" },

  { op: 'spaces.create', as: 'attic', input: { name: '  Attic  ', icon: 'box', color: '#E4572E' } },
  { op: 'spaces.create', as: 'loft', input: { name: '﻿Loft　', icon: '🏠', color: '#2E9E4F' } },
  { op: 'spaces.create', as: 'nel', input: { name: '\u0085Nel\u0085', icon: '', color: '' } },
  { op: 'spaces.create', as: 'blank', input: { name: ' \t\n ', icon: 'x', color: '#000' } },
  { op: 'spaces.create', as: 'greek', input: { name: 'ΑΠΟΘΗΚΗ ΣΑΣ', icon: 'g', color: '#111111' } },
  { op: 'spaces.update', id: '@loft', input: { name: '  ' } },
  { op: 'spaces.update', id: '@attic', input: { icon: '📦' } },
  { op: 'spaces.update', id: '@attic', input: { name: ' Attic ', color: '#123456' } },
  { op: 'spaces.update', id: 'drop-zone-space', input: { name: 'Mine' } },
  { op: 'spaces.update', id: 'no-such-space', input: { name: 'x' } },

  { op: 'containers.create', as: 'box', input: { spaceId: '@attic', visualType: 'box', name: ' Tool Box ' } },
  { op: 'containers.create', as: 'drawer', input: { spaceId: '@attic', visualType: 'drawer', name: '   ' } },
  { op: 'containers.create', as: 'shelf', input: { spaceId: '@greek', visualType: 'shelf', name: ' ΡΑΦΙ ' } },
  { op: 'containers.create', as: 'trunk', input: { spaceId: '@loft', visualType: 'Trunk', name: null } },
  // Ten attempts, each with a new id and code, then the short-code error (01 §7.2, Q5).
  { op: 'containers.create', input: { spaceId: 'no-such-space', visualType: 'bin' } },
  { op: 'containers.create', as: 'bag', input: { spaceId: '@nel', visualType: 'bag' } },
  { op: 'containers.update', id: '@drawer', input: { name: ' Cutlery ' } },
  { op: 'containers.update', id: '@drawer', input: { visualType: 'cabinet' } },
  { op: 'containers.update', id: '@drawer', input: { name: null } },
  { op: 'containers.update', id: '@box', input: { name: '  ', visualType: 'crate' } },
  { op: 'containers.update', id: '@box', input: { name: 'Tool Box' } },
  { op: 'containers.update', id: '@bag', input: { spaceId: 'drop-zone-space' } },
  { op: 'containers.update', id: '@bag', input: { spaceId: 'no-such-space' } },
  { op: 'containers.update', id: 'drop-zone', input: { name: 'x' } },
  { op: 'containers.update', id: 'no-such-container', input: {} },

  {
    op: 'items.create', as: 'drill',
    input: {
      containerId: '@box', name: ' Cordless Drill ', category: ' Power Tools ', quantity: 2, notes: '\n Charger \t',
      tags: ['  DeWalt ', 'dewalt', 'DEWALT', '', '   ', '18V'],
      photo: { uri: 'file:///p/drill.webp', thumbUri: 'file:///p/drill-thumb.webp', width: 1400, height: 1050, byteSize: 1234 },
    },
  },
  {
    op: 'items.create', as: 'sigma',
    input: { containerId: '@shelf', name: 'ΟΔΟΣ ΣΑΣ Σ', category: 'aΣ.', tags: ['ΣΑΣ', 'σας', 'İstanbul', 'i̇stanbul'] },
  },
  {
    op: 'items.create', as: 'misc',
    input: {
      containerId: '@drawer', name: 'Straße ǅ ﬁle ™ ẞ', category: 'Küche',
      tags: ['Ölkanne', 'ölkanne', 'café', 'café', '﻿ '], photo: { id: 'given-photo', uri: 'r2:x' },
    },
  },
  { op: 'items.create', as: 'unnamed', input: { containerId: 'drop-zone' } },
  { op: 'items.create', as: 'zero', input: { containerId: '@box', name: 'Nails', quantity: 0, category: '  ', notes: '  ' } },
  { op: 'items.create', input: { containerId: '@box', name: '  ' } },
  { op: 'items.create', input: { containerId: '@box', name: '  ', quantity: -1 } },
  { op: 'items.create', input: { containerId: 'no-such-container', name: 'Ghost', photo: { uri: 'file:///ghost' }, tags: ['ghost'] } },
  { op: 'items.create', as: 'big', input: { containerId: '@trunk', name: 'Screws', quantity: 12345, tags: ['dewalt'], category: null, notes: null } },
  { op: 'sql', sql: 'UPDATE item_photos SET remote_synced_at = 5' },
  { op: 'items.update', id: '@drill', input: { name: 'Impact Drill', tags: ['DeWalt', 'new tag', 'NEW TAG'] } },
  { op: 'items.update', id: '@drill', input: { category: null, notes: '  ' } },
  { op: 'items.update', id: '@drill', input: { photo: { id: 'ignored', uri: 'file:///p/drill2.webp', width: 10 } } },
  { op: 'items.update', id: '@misc', input: { photo: null } },
  { op: 'items.update', id: '@unnamed', input: { containerId: '@box', expectedUpdatedAt: '@unnamed.updatedAt' } },
  { op: 'items.update', id: '@unnamed', input: { quantity: 3, tags: ['lost'], expectedUpdatedAt: 1 } },
  { op: 'items.update', id: 'no-such-item', input: { quantity: 3, expectedUpdatedAt: 1 } },
  { op: 'items.update', id: '@zero', input: { name: '  ' } },
  { op: 'items.update', id: '@zero', input: { quantity: -2, name: '  ' } },
  { op: 'items.update', id: '@sigma', input: { tags: [] } },
  { op: 'items.update', id: '@sigma', input: { category: ' ΣΑΣ ', quantity: 1 } },
  // A pre-v2 backfill left ASCII-only lowercase; any update rewrites it (01 §3.2 v2).
  { op: 'sql', sql: "UPDATE items SET search_text = 'Ärmel' WHERE name = 'Screws'" },
  { op: 'items.update', id: '@big', input: { quantity: 9 } },

  { op: 'qr.createAndBind', as: 'label1', containerId: '@box' },
  { op: 'qr.createAndBind', as: 'label2', containerId: '@box' },
  { op: 'qr.bind', as: 'label3', token: '@label2.token', containerId: '@shelf' },
  { op: 'qr.bind', as: 'label4', token: 'ABCDEF', containerId: '@drawer' },
  { op: 'qr.createAndBind', containerId: 'drop-zone' },
  { op: 'qr.bind', token: '@label3.token', containerId: 'no-such-container' },
  { op: 'qr.unbind', containerId: '@drawer' },
  { op: 'qr.unbind', containerId: '@drawer' },

  // Every table, then searches over what the writes stored (folding on write meets folding in the query).
  { op: 'sql', sql: 'UPDATE sync_deletions SET deleted_at = 0' },
  { op: 'dump' },
  ...[
    'drill', 'impact', 'dewalt', 'new tag', 'οδος', 'σας', 'σασ', 'istanbul', 'i̇stanbul', 'straße', 'ǆ', 'file', 'tm',
    'küche', 'kuche', 'ölkanne', 'cafe', 'café', 'attic', 'tool box', 'toolbox', 'nails', 'screws', 'ärmel', 'ραφι',
    'nel', 'loft', 'cutlery', 'drop', 'trunk', 'ctr', 'box', 'crt', 'zone', 'power', 'charger', 'ẞ', 'ß', 'ss',
  ].map((query) => ({ op: 'search', query })),

  { op: 'items.delete', id: '@drill' },
  { op: 'items.delete', id: 'no-such-item' },
  { op: 'containers.delete', id: '@drawer' },
  { op: 'containers.delete', id: 'drop-zone' },
  { op: 'spaces.delete', id: '@greek' },
  { op: 'spaces.delete', id: 'drop-zone-space' },
  { op: 'spaces.delete', id: 'no-such-space' },
  { op: 'sql', sql: 'UPDATE sync_deletions SET deleted_at = 0' },
];

function resolveRefs(value: unknown, results: Map<string, Record<string, unknown>>): unknown {
  if (typeof value === 'string' && value.startsWith('@')) {
    const [alias, field = 'id'] = value.slice(1).split('.');
    const result = results.get(alias!);
    if (!result) throw new Error(`unknown alias ${value}`);
    return result[field];
  }
  if (Array.isArray(value)) return value.map((entry) => resolveRefs(entry, results));
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, entry]) => [key, resolveRefs(entry, results)]));
  }
  return value;
}

async function runWriteOp(repos: Repositories, step: WriteOp): Promise<unknown> {
  const arg = (key: string) => step[key] as never;
  switch (step.op) {
    case 'sql':
      await repos.db.execAsync(arg('sql'));
      return null;
    case 'dump': return dumpTables(repos.db);
    case 'search': return repos.search.search(arg('query'));
    case 'spaces.create': return repos.spaces.create(arg('input'));
    case 'spaces.update': return repos.spaces.update(arg('id'), arg('input'));
    case 'spaces.delete': return repos.spaces.delete(arg('id'));
    case 'containers.create': return repos.containers.create(arg('input'));
    case 'containers.update': return repos.containers.update(arg('id'), arg('input'));
    case 'containers.delete': return repos.containers.delete(arg('id'));
    case 'items.create': return repos.items.create(arg('input'));
    case 'items.update': return repos.items.update(arg('id'), arg('input'));
    case 'items.delete': return repos.items.delete(arg('id'));
    case 'qr.bind': return repos.qr.bind(arg('token'), arg('containerId'));
    case 'qr.createAndBind': return repos.qr.createAndBind(arg('containerId'));
    case 'qr.unbind': return repos.qr.unbind(arg('containerId'));
    default: throw new Error(`unknown op ${step.op}`);
  }
}

async function generateWrites(): Promise<void> {
  const bytes = lcg(WRITE_SEEDS.idSeed);
  const codes = lcg(WRITE_SEEDS.codeSeed);
  configureRandomBytes((count) => Uint8Array.from({ length: count }, () => Math.floor(bytes() * 256)));
  const random = jest.spyOn(Math, 'random').mockImplementation(codes);
  let clock = WRITE_SEEDS.clockStart;
  const now = jest.spyOn(Date, 'now').mockImplementation(() => {
    clock += WRITE_SEEDS.clockStep;
    return clock;
  });

  try {
    const db = openNodeDatabase();
    const repos = await initializeRepositories(db);
    const aliases = new Map<string, Record<string, unknown>>();
    const steps = [];
    for (const raw of WRITE_OPS) {
      const step = resolveRefs(raw, aliases) as WriteOp;
      let outcome: { ok: unknown } | { error: string };
      try {
        const value = await runWriteOp(repos, step);
        outcome = { ok: value ?? null };
        if (raw.as && value && typeof value === 'object') aliases.set(raw.as, value as Record<string, unknown>);
      } catch (error) {
        outcome = { error: error instanceof Error ? error.message : String(error) };
      }
      steps.push({ ...raw, ...outcome });
    }
    write('writes.json', { seeds: WRITE_SEEDS, steps, tables: await dumpTables(db) });
    await db.closeAsync();
  } finally {
    random.mockRestore();
    now.mockRestore();
  }
}

// ---------------------------------------------------------------------------

describe('database fixtures', () => {
  beforeAll(() => {
    mkdirSync(SCRATCH, { recursive: true });
    mkdirSync(OUT, { recursive: true });
  });

  afterAll(() => {
    rmSync(SCRATCH, { recursive: true, force: true });
  });

  it('writes the migrations verbatim and the final sqlite_master', async () => {
    write('migrations.json', {
      latestSchemaVersion: LATEST_SCHEMA_VERSION,
      migrations: MIGRATIONS.map((m) => ({ version: m.version, name: m.name, up: m.up, rebuild: m.rebuild === true })),
    });

    const db = openNodeDatabase();
    await migrate(db);
    const version = await db.getFirstAsync<{ v: string }>('SELECT sqlite_version() AS v');
    write('sqlite_master.json', {
      generatedWith: `node ${process.version}, SQLite ${version?.v}`,
      userVersion: await userVersion(db),
      rows: await sqliteMaster(db),
    });
    await db.closeAsync();
  });

  it('writes databases at every historical schema version', async () => {
    await generateHistorical();
  });

  it('writes a database with rows only in its WAL', async () => {
    await generateWal();
  });

  it('writes the search inventory and the TypeScript results over it', async () => {
    await generateSearch();
  }, 120_000);

  it('writes the write-parity script and what the TypeScript repositories made of it', async () => {
    await generateWrites();
  });
});
