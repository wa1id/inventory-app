import type { SqlDatabase } from './types';

/**
 * Ordered, append-only schema migrations.
 *
 * `version` must equal the array index + 1. The runner stores the highest
 * applied version in SQLite's `user_version` pragma, so an app upgrade replays
 * only the migrations a device has not seen yet. Never edit or reorder a
 * migration that has shipped — add a new one instead.
 */
export interface Migration {
  version: number;
  name: string;
  up: string;
}

export const MIGRATIONS: Migration[] = [
  {
    version: 1,
    name: 'initial_inventory_schema',
    up: `
      CREATE TABLE spaces (
        id          TEXT PRIMARY KEY NOT NULL,
        name        TEXT NOT NULL,
        icon        TEXT NOT NULL DEFAULT 'cube',
        color       TEXT NOT NULL DEFAULT '#5B8DEF',
        created_at  INTEGER NOT NULL,
        updated_at  INTEGER NOT NULL
      );

      CREATE TABLE containers (
        id          TEXT PRIMARY KEY NOT NULL,
        space_id    TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
        name        TEXT,
        visual_type TEXT NOT NULL DEFAULT 'box',
        short_code  TEXT NOT NULL UNIQUE,
        created_at  INTEGER NOT NULL,
        updated_at  INTEGER NOT NULL
      );
      CREATE INDEX idx_containers_space ON containers(space_id);

      CREATE TABLE items (
        id              TEXT PRIMARY KEY NOT NULL,
        container_id    TEXT NOT NULL REFERENCES containers(id) ON DELETE CASCADE,
        name            TEXT NOT NULL,
        category        TEXT,
        quantity        INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
        estimated_value REAL,
        currency        TEXT,
        notes           TEXT,
        created_at      INTEGER NOT NULL,
        updated_at      INTEGER NOT NULL
      );
      CREATE INDEX idx_items_container ON items(container_id);
      CREATE INDEX idx_items_name ON items(name COLLATE NOCASE);

      CREATE TABLE item_photos (
        id         TEXT PRIMARY KEY NOT NULL,
        item_id    TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
        uri        TEXT NOT NULL,
        width      INTEGER,
        height     INTEGER,
        byte_size  INTEGER,
        created_at INTEGER NOT NULL
      );
      CREATE INDEX idx_item_photos_item ON item_photos(item_id);

      CREATE TABLE tags (
        id              TEXT PRIMARY KEY NOT NULL,
        name            TEXT NOT NULL,
        normalized_name TEXT NOT NULL UNIQUE,
        created_at      INTEGER NOT NULL
      );

      CREATE TABLE item_tags (
        item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
        tag_id  TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
        PRIMARY KEY (item_id, tag_id)
      );
      CREATE INDEX idx_item_tags_tag ON item_tags(tag_id);

      CREATE TABLE qr_bindings (
        id           TEXT PRIMARY KEY NOT NULL,
        token        TEXT NOT NULL UNIQUE,
        container_id TEXT NOT NULL REFERENCES containers(id) ON DELETE CASCADE,
        created_at   INTEGER NOT NULL,
        updated_at   INTEGER NOT NULL
      );
      CREATE INDEX idx_qr_bindings_container ON qr_bindings(container_id);
    `,
  },
  {
    version: 2,
    name: 'add_search_normalization_columns',
    up: `
      -- Precomputed lowercase columns keep keyword search index-friendly and
      -- avoid per-row LOWER() calls once an inventory grows past a few thousand
      -- items. Backfilled here for inventories created before this migration.
      ALTER TABLE items ADD COLUMN search_text TEXT NOT NULL DEFAULT '';
      -- TRIM matches how the repository builds search_text for new rows, so a
      -- migrated row and a freshly written one are byte-identical.
      UPDATE items
         SET search_text = TRIM(LOWER(name || ' ' || COALESCE(category, '')));
      CREATE INDEX idx_items_search_text ON items(search_text);
    `,
  },
];

/** Schema version a freshly built app expects. */
export const LATEST_SCHEMA_VERSION = MIGRATIONS.length;

async function readUserVersion(db: SqlDatabase): Promise<number> {
  const row = await db.getFirstAsync<{ user_version: number }>('PRAGMA user_version');
  return row?.user_version ?? 0;
}

/**
 * Applies every migration newer than the database's current `user_version`.
 *
 * Each migration runs inside its own transaction together with the version
 * bump, so an interrupted upgrade leaves the database on the last fully applied
 * version rather than in a half-migrated state.
 */
export async function migrate(
  db: SqlDatabase,
  migrations: Migration[] = MIGRATIONS,
): Promise<number> {
  const current = await readUserVersion(db);

  for (const migration of migrations) {
    if (migration.version <= current) continue;

    await db.withTransactionAsync(async () => {
      await db.execAsync(migration.up);
      // PRAGMA does not accept bound parameters; version is a trusted integer
      // from the migration table above, never user input.
      await db.execAsync(`PRAGMA user_version = ${migration.version}`);
    });
  }

  return readUserVersion(db);
}
