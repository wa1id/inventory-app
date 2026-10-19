// RN: src/db/migrations.ts:24-262. The seven schema migrations, verbatim.
//
// Append-only: never edit or reorder one that has shipped. Each `up` is the
// exact JS template-literal text (indentation included), because SQLite stores
// every CREATE statement's text in sqlite_master and backups, household dumps
// and the home server compare against it (01 §3.2, §4.1). The closing
// delimiters sit at column 0 so Swift strips no indentation; the leading empty
// line and the trailing four spaces are the JS literal's own. Pinned by
// MigrationTests against Fixtures/db/migrations.json.
//
// Generated from that fixture; keep it byte-identical.

extension Migration {
    /// Every migration, in order; `version == index + 1`.
    public static let all: [Migration] = [
        initialInventorySchema,
        addSearchNormalizationColumns,
        addDropZone,
        addPhotoSyncState,
        addPhotoThumbnails,
        dropItemValueEstimate,
        allowZeroQuantity,
    ]

    /// The schema version a fresh database reaches (RN `LATEST_SCHEMA_VERSION`): 7.
    public static let latestSchemaVersion = all.count

    /// v1 `initial_inventory_schema`.
    static let initialInventorySchema = Migration(
        version: 1,
        name: "initial_inventory_schema",
        up: #"""

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
    
"""#
    )

    /// v2 `add_search_normalization_columns`.
    static let addSearchNormalizationColumns = Migration(
        version: 2,
        name: "add_search_normalization_columns",
        up: #"""

      -- Precomputed lowercase columns keep keyword search index-friendly and
      -- avoid per-row LOWER() calls once an inventory grows past a few thousand
      -- items. Backfilled here for inventories created before this migration.
      ALTER TABLE items ADD COLUMN search_text TEXT NOT NULL DEFAULT '';
      -- TRIM matches how the repository builds search_text for new rows, so a
      -- migrated row and a freshly written one are byte-identical.
      UPDATE items
         SET search_text = TRIM(LOWER(name || ' ' || COALESCE(category, '')));
      CREATE INDEX idx_items_search_text ON items(search_text);
    
"""#
    )

    /// v3 `add_drop_zone`.
    static let addDropZone = Migration(
        version: 3,
        name: "add_drop_zone",
        up: #"""

      -- The drop zone lets people photograph things before deciding where they
      -- live (issue #26). Modelling it as a system-flagged space and container
      -- rather than a nullable items.container_id is deliberate: SQLite cannot
      -- drop NOT NULL in place, and rebuilding `items` under
      -- `PRAGMA foreign_keys = ON` would cascade-delete every photo and tag.
      -- ADD COLUMN is safe, and every existing INNER JOIN keeps resolving.
      ALTER TABLE spaces ADD COLUMN kind TEXT NOT NULL DEFAULT 'normal';
      ALTER TABLE containers ADD COLUMN kind TEXT NOT NULL DEFAULT 'normal';

      INSERT INTO spaces (id, name, icon, color, created_at, updated_at, kind)
      VALUES (
        'drop-zone-space', 'Drop zone', '📥', '#0F9BB0',
        CAST(strftime('%s','now') AS INTEGER) * 1000,
        CAST(strftime('%s','now') AS INTEGER) * 1000,
        'system'
      );

      INSERT INTO containers (id, space_id, name, visual_type, short_code, created_at, updated_at, kind)
      VALUES (
        'drop-zone', 'drop-zone-space', 'Drop zone', 'other', 'DROP-ZONE',
        CAST(strftime('%s','now') AS INTEGER) * 1000,
        CAST(strftime('%s','now') AS INTEGER) * 1000,
        'system'
      );
    
"""#
    )

    /// v4 `add_photo_sync_state`.
    static let addPhotoSyncState = Migration(
        version: 4,
        name: "add_photo_sync_state",
        up: #"""

      -- When this photo's bytes were last confirmed stored remotely. NULL
      -- means "not uploaded yet", which is also the correct state for every
      -- photo that existed before this migration — they are backfilled by the
      -- uploader, not here, because this migration cannot do network I/O.
      ALTER TABLE item_photos ADD COLUMN remote_synced_at INTEGER;

      -- Partial index: the uploader only ever asks for the unsynced ones, and
      -- in a healthy inventory that set is empty. Indexing only the NULLs keeps
      -- the index proportional to the backlog rather than to the library.
      CREATE INDEX idx_item_photos_unsynced
        ON item_photos(created_at)
        WHERE remote_synced_at IS NULL;

      -- Tombstones for remote cleanup.
      --
      -- Deleting an item cascades to its photo rows, which is exactly the
      -- moment the id needed to delete the remote copy stops existing. Without
      -- this table a deleted photo would be unreachable locally and retained
      -- remotely forever — the user believing it gone while it is not.
      CREATE TABLE sync_deletions (
        photo_id   TEXT PRIMARY KEY NOT NULL,
        deleted_at INTEGER NOT NULL
      );

      -- A trigger rather than repository code: the deletes that matter most
      -- here are the cascaded ones, which no repository issues explicitly.
      CREATE TRIGGER item_photos_tombstone
      AFTER DELETE ON item_photos
      WHEN OLD.remote_synced_at IS NOT NULL
      BEGIN
        INSERT OR REPLACE INTO sync_deletions (photo_id, deleted_at)
        VALUES (OLD.id, CAST(strftime('%s','now') AS INTEGER) * 1000);
      END;
    
"""#
    )

    /// v5 `add_photo_thumbnails`.
    static let addPhotoThumbnails = Migration(
        version: 5,
        name: "add_photo_thumbnails",
        up: #"""

      -- Path to a small copy used by list rows, which are 56–64pt and were
      -- decoding the full-size image to fill them.
      --
      -- Nullable because it cannot be backfilled here: generating one means
      -- decoding and re-encoding an image, which a migration cannot do. Rows
      -- written before this migration keep a NULL and fall back to the full
      -- image, so nothing breaks — they are simply as expensive to draw as they
      -- were before. New captures and restored photos populate it.
      ALTER TABLE item_photos ADD COLUMN thumb_uri TEXT;
    
"""#
    )

    /// v6 `drop_item_value_estimate`.
    static let dropItemValueEstimate = Migration(
        version: 6,
        name: "drop_item_value_estimate",
        up: #"""

      -- The value estimate is gone from the product, so it goes from the
      -- schema too rather than lingering as a column nothing reads. Dropping
      -- it is deliberate data loss, and the only honest option: keeping the
      -- numbers in a table with no way to see or edit them is worse than not
      -- having them.
      --
      -- `currency` goes with it. It never denominated anything else — it
      -- existed to say what `estimated_value` was counted in.
      --
      -- Safe as a plain DROP COLUMN: neither column is indexed, referenced by
      -- a trigger, or part of search_text. Rows restored from a backup taken
      -- before this migration are brought forward through here like any other
      -- older snapshot.
      ALTER TABLE items DROP COLUMN estimated_value;
      ALTER TABLE items DROP COLUMN currency;
    
"""#
    )

    /// v7 `allow_zero_quantity` (rebuild: runs with foreign keys off).
    static let allowZeroQuantity = Migration(
        version: 7,
        name: "allow_zero_quantity",
        up: #"""

      -- Quantity 0 means the item is still filed in this container, just not
      -- currently there — taken out temporarily, to be put back later. The
      -- original CHECK (quantity > 0) made that unsayable: the only way to
      -- record "none here" was to delete the row and lose the location.
      --
      -- SQLite cannot rewrite a CHECK in place. Rebuilding `items` while
      -- foreign_keys is ON would cascade-delete every photo and tag, so this
      -- migration is flagged `rebuild` and the runner turns foreign keys off
      -- for it. Child rows stay put; their REFERENCES items(id) still resolve
      -- after the rename.
      CREATE TABLE items_new (
        id           TEXT PRIMARY KEY NOT NULL,
        container_id TEXT NOT NULL REFERENCES containers(id) ON DELETE CASCADE,
        name         TEXT NOT NULL,
        category     TEXT,
        quantity     INTEGER NOT NULL DEFAULT 1 CHECK (quantity >= 0),
        notes        TEXT,
        created_at   INTEGER NOT NULL,
        updated_at   INTEGER NOT NULL,
        search_text  TEXT NOT NULL DEFAULT ''
      );

      INSERT INTO items_new (
        id, container_id, name, category, quantity, notes,
        created_at, updated_at, search_text
      )
      SELECT id, container_id, name, category, quantity, notes,
             created_at, updated_at, search_text
        FROM items;

      DROP TABLE items;
      ALTER TABLE items_new RENAME TO items;

      CREATE INDEX idx_items_container ON items(container_id);
      CREATE INDEX idx_items_name ON items(name COLLATE NOCASE);
      CREATE INDEX idx_items_search_text ON items(search_text);
    
"""#,
        rebuild: true
    )
}
