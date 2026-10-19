# 01 — Data layer: schema, migrations, repositories, search, core logic

Porting spec for the native iOS app (Swift 6, SwiftUI, iOS 26, GRDB). It covers the
on-device SQLite database and everything that reads or writes it directly, plus the
pure logic and the data hooks that sit on top.

All citations are `path:line` against the RN repo at commit `40c0616`. Line numbers
are per file.

---

## 0. Scope and source files

| Area | Files |
|---|---|
| DB contract, opening, pragmas | `src/db/types.ts`, `src/db/expoDatabase.ts`, `src/db/nodeDatabase.ts` (test/home-server adapter), `src/db/repositories.ts`, `src/db/constants.ts` |
| Migrations | `src/db/migrations.ts` |
| Core logic | `src/core/bytes.ts`, `conflict.ts`, `id.ts`, `quantity.ts`, `shortCode.ts`, `tokenize.ts` |
| Repositories | `src/repositories/spaces.ts`, `containers.ts`, `items.ts`, `qr.ts`, `search.ts` |
| Data hooks and stores | `src/hooks/useInventoryQuery.ts`, `useSearch.ts`, `useMove.ts`, `useSavedQuantity.ts`, `useRecentPlaces.ts`, `src/services/places/recentPlaces.ts`, `src/ui/placeMatch.ts`, `src/ui/categoryMemory.ts` |
| Supporting code read for semantics | `src/providers/DatabaseProvider.tsx` (invalidation), `src/providers/DropZoneProvider.tsx`, `src/ui/item/moveFlow.ts` (conflict rules used by `useMove`), `src/ui/errors.ts` (`describeError`), `src/ui/motion.ts` (debounce), `src/services/household/shadow.ts` (local mirror of remote writes), `src/services/sync/backup.ts` (`restore` then `migrate`) |
| Tests | Listed in §13 |

---

## 1. Decisions for the Swift engineer (short version)

1. **Open the existing file in place**: `<AppContainer>/Documents/SQLite/inventory.db`, together with its `-wal` and `-shm` sidecars. Do not copy, rename or "import" it (§2.1).
2. **Run the same 7 migrations, keyed on `PRAGMA user_version`.** Embed the SQL text verbatim. **Do not** use GRDB's `DatabaseMigrator`, which tracks state in a `grdb_migrations` table (§3).
3. **Keep the final schema byte-for-byte.** Backups, household dumps and Android/RN restores all depend on it. There are **no FTS tables**. There is **one trigger**. Search uses `LIKE` (§4).
4. **Keep each repository's SQL** so that local results match what the home server returns. The home server runs the same TypeScript repositories (§7).
5. **Port the text-folding functions at the Unicode-scalar level**, matching JS `toLowerCase` / `normalize('NFKD')` / `\p{Letter}\p{Number}` exactly. Test vectors are in §6.6.
6. **Keep the explicit invalidation model**: a global revision counter bumped after writes, a re-read whenever a screen gains *navigation focus* (it becomes the top screen again; app foregrounding is not focus, §9.1), and last-good data kept on failure. Do not replace it with DB observation. When the phone is paired, reads go over HTTP and DB observation would not see them (§9.1).
7. **Import two AsyncStorage keys once** (`places.recent.v1`, `categories.recent.v1`) from RN's legacy AsyncStorage manifest into `UserDefaults` (§10.2).

---

## 2. Database file, connection and lifecycle

### 2.1 Location (critical for replace-in-place)

- The RN app calls `SQLite.openDatabaseAsync('inventory.db')` (`src/db/expoDatabase.ts:63,73`) with no directory, so expo-sqlite resolves it under `defaultDatabaseDirectory`. On iOS that is `appContext.config.documentDirectory/SQLite` (`node_modules/expo-sqlite/ios/SQLiteModule.swift:24-29`).
- **Path:** `FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("SQLite/inventory.db")`.
- Sidecars: `inventory.db-wal` and `inventory.db-shm`. **Never delete them before opening.** The RN app may have been killed with committed pages still in the WAL, and SQLite replays them on open.
- Encryption: none. The `expo-sqlite` plugin has no options in `app.json` (no SQLCipher).
- expo-sqlite on iOS uses its own vendored SQLite 3.50.3 (`node_modules/expo-sqlite/vendor/sqlite3/sqlite3.h:149`). Its compile flags are `SQLITE_TEMP_STORE=2`, FTS3/4/5, MATH_FUNCTIONS and SESSION (`node_modules/expo-sqlite/ios/ExpoSQLite.podspec:38-42`), and **no ICU**. GRDB on the iOS 26 system SQLite (≥ 3.43) reads the same file format. Migration 6 needs `DROP COLUMN` (≥ 3.35) and migration 7 needs modern `ALTER TABLE RENAME` (≥ 3.26). Both are satisfied.
- **ICU caveat:** `LOWER()`, `LIKE` and `COLLATE NOCASE` must stay **ASCII-only case folding**, as in stock SQLite. Before shipping, verify on device that `SELECT LOWER('ÄRMEL'), 'ärmel' LIKE 'ÄRMEL'` returns `'Ärmel', 0`, the same as node:sqlite and expo (verified in Node during this spec). If Apple's SQLite folds Unicode case, link GRDB against a custom SQLite build such as `GRDB/SQLCipher` without encryption, or GRDB with a bundled SQLite.

### 2.2 Pragmas set on open

From `openExpoDatabase` (`src/db/expoDatabase.ts:72-77`):

```sql
PRAGMA journal_mode = WAL;   -- persistent in the file header; the file is already WAL
PRAGMA foreign_keys = ON;    -- per connection; REQUIRED for every ON DELETE CASCADE
```

Nothing else is set. There is no `busy_timeout` and no `synchronous` override. With expo's flags, `synchronous` is SQLite's default of FULL (2). expo-sqlite's `initDb` adds nothing unless the change listener is enabled, and it is not (`node_modules/expo-sqlite/ios/SQLiteModule.swift:346-351`).

**Native (GRDB):**
- Use a `DatabaseQueue` (one connection, like the RN app). Keep `Configuration.foreignKeysEnabled = true` (the GRDB default), and in `prepareDatabase` run `PRAGMA journal_mode = WAL`.
- Optionally set `PRAGMA synchronous = FULL` explicitly. The system SQLite's WAL default may be NORMAL, and this keeps durability the same as before.
- **Decision (all specs aligned): use the `DatabaseQueue`.** A `DatabasePool` would also work, but restore (§2.5) is simpler with a single connection, a pool's open readers can block the pre-snapshot `wal_checkpoint(TRUNCATE)`, and GRDB's pool is believed to force `synchronous = NORMAL` on its writer (`02-device-storage-migration.md` §2.3 rule 5).
- Reads and writes go through `read {}` / `write {}`. GRDB serialises writes, which fixes the expo `withTransactionAsync` interleaving hazard (§11).

### 2.3 Open and boot flow

`DatabaseProvider` (`src/providers/DatabaseProvider.tsx:36-81`):

1. The RNG is installed at module load (`:15`). Natively, use `SecRandomCopyBytes` directly (§6.1).
2. Boot state machine: `loading → ready(repos) | error(message)` (`:17-20`).
3. Open the database (`:47`), then `initializeRepositories(db)`, which runs `migrate(db)` and then builds the repositories (`src/db/repositories.ts:31-34`).
4. Success logs `database_ready {durationMs}` (`:50`). Failure logs `database_open_failed {durationMs}` (`:54`) and sets state `error`. The message is `error.message` or `'The inventory database could not be opened.'` (`:55-59`), but the UI never shows that text. It shows `strings.boot.failedTitle` / `strings.boot.failedBody` with a retry button (`app/_layout.tsx:142-151`).
5. `retry()` sets `loading` and re-runs the open (`:69-72`). While loading, the UI shows `strings.boot.opening`. **RN detail:** retry calls `openExpoDatabase()` again without closing a connection that may have opened before `migrate` threw (`:47-48`). This does not leak in practice: expo-sqlite returns its **cached native connection** for the same path and options (`node_modules/expo-sqlite/ios/SQLiteModule.swift:107-111`, `findCachedDatabase` + `addRef`), so the retry re-runs the pragmas and `migrate` on the same connection (matches `09-app-shell-lifecycle-config.md` §2.4). Native: close (drop) any previous `DatabaseQueue` before reopening.
6. Screens below the gate are mounted only when the state is `ready` (the root layout also waits for onboarding and household readiness, `app/_layout.tsx:153`; other specs).

### 2.4 `Repositories` façade

`src/db/repositories.ts:10-17`: `{ db, spaces, containers, items, qr, search }`.

When the phone is paired with a household, `useRepositories()` returns `withLocalShadow(remoteHttpRepos, localRepos)` instead of the local repos (`src/providers/DatabaseProvider.tsx:108-120`):
- reads and search go to the HTTP implementation (`src/services/household/httpRepositories.ts`);
- writes go to HTTP and are then mirrored into local SQLite on a best-effort basis (`src/services/household/shadow.ts:11-100`).

**Swift:** define the façade as protocols (`SpacesStore`, `ContainersStore`, `ItemsStore`, `QrStore`, `SearchStore`) with three implementations: local (GRDB, this spec), HTTP (household spec) and a shadow decorator. Backup, restore and photo sync always use the **local** DB handle (`src/providers/SyncProvider.tsx:58,67`: `state.repos.db` from the un-shadowed local state), even while paired.

### 2.5 Snapshot and restore (backend capability used by backup)

- `snapshotAsync` runs `PRAGMA wal_checkpoint(TRUNCATE)`, then `serializeAsync()` (`sqlite3_serialize` of `main`) (`src/db/expoDatabase.ts:31-34`).
- `restoreAsync(bytes)` deserialises the snapshot into an in-memory DB, copies it into the live connection with the SQLite **online backup API** (main to main), then closes the source (`src/db/expoDatabase.ts:47-60`). The file is never overwritten while open.
- After a restore, the caller **must run `migrate()`**, because the snapshot may come from an older schema (`src/services/sync/backup.ts:139-143`). A snapshot whose `schemaVersion > LATEST_SCHEMA_VERSION` is refused before restoring (`src/services/sync/backup.ts:134-137`).
- `readSchemaVersion` = `PRAGMA user_version` (`src/services/sync/backup.ts:24-27`). It is sent as the `x-snapshot-schema-version` header (sync spec).
- **Native:**
  - Snapshot: `try db.checkpoint(.truncate)` inside `writeWithoutTransaction`, then `sqlite3_serialize` via `db.sqliteConnection`. Alternatively use `VACUUM INTO` a temp file, as the home-server Node adapter does (`src/db/nodeDatabase.ts:113-121`); both produce a valid SQLite file. (Reviewer: confirm `sqlite3_serialize`/`sqlite3_deserialize` are exported by the iOS SDK's `libsqlite3`; if not, `VACUUM INTO` is the safe default.)
  - Restore: open an in-memory `DatabaseQueue`, `sqlite3_deserialize` the bytes into it (or write the bytes to a temp file and open a `DatabaseQueue(path:)` on it), run `source.backup(to: liveQueue)`, then `migrate()`. The backup API copies page 1, so the snapshot's `user_version` comes with it; `PRAGMA foreign_keys` is per connection and stays ON on the live queue.
  - The snapshot must stay restorable by the RN Android app, which runs the same migrations. **Do not add tables** such as `grdb_migrations`.

---

## 3. Migrations

### 3.1 Runner semantics (must be identical)

`migrate(db, migrations = MIGRATIONS)` (`src/db/migrations.ts:284-313`):

1. `current = PRAGMA user_version` (`:267-270`, missing row → 0).
2. Go through migrations in array order. **Skip** any whose `version <= current` (`:291`).
3. If `migration.rebuild` is true (only v7): read `PRAGMA foreign_keys` (`:272-275`), remember whether it was on, then run `PRAGMA foreign_keys = OFF` **outside any transaction** (`:293-296`). SQLite ignores this pragma inside a transaction (`:15-21`).
4. Inside **one transaction**: execute the migration's multi-statement SQL, then `PRAGMA user_version = <version>` (integer interpolated, because pragmas cannot be bound) (`:299-304`). An interruption leaves the DB at the last fully applied version.
5. `finally`: if foreign keys were on before step 3, run `PRAGMA foreign_keys = ON` (`:305-309`). If they were off, leave them off.
6. Return `PRAGMA user_version` (`:312`).

Invariants:
- `version == index + 1` (test `persistence.test.ts:133`). `LATEST_SCHEMA_VERSION = MIGRATIONS.length = 7` (`src/db/migrations.ts:265`; `home-server/test/migrate.test.ts:16`).
- The list is append-only. Git history confirms that no shipped migration was ever edited: commits `67185d8`, `4a0c3f4`, `9d24ddf`, `4fa33a6`, `d8cf59d` and `fe6e940` only appended migrations. `fe6e940` added v7 and the `rebuild` handling.
- A failure throws to the caller. At boot this becomes the boot `error` state.

Edge cases:
- **`user_version` = 0 on an empty file** → all 7 migrations run (fresh install).
- **`user_version` > 7** (a file written by a newer build): every migration is skipped silently, with no refusal (`:291`). Keep this behaviour. Restore guards against newer snapshots separately.
- **Tables present but `user_version` = 0**: impossible via the app, because v1 and the version bump commit together. If it happened, v1 would fail with "table spaces already exists" and boot would end in the error state. Keep this; do not try to "detect" the schema.

**Native implementation sketch:**

```swift
func migrate(_ writer: DatabaseQueue, upTo migrations: [Migration] = Migration.all) throws -> Int {
  try writer.writeWithoutTransaction { db in
    let current = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
    for m in migrations where m.version > current {
      let restoreFK = m.rebuild ? (try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? 0) != 0 : false
      if m.rebuild { try db.execute(sql: "PRAGMA foreign_keys = OFF") }
      defer { if restoreFK { try? db.execute(sql: "PRAGMA foreign_keys = ON") } }
      try db.inTransaction {
        try db.execute(sql: m.up)                       // multi-statement, verbatim text
        try db.execute(sql: "PRAGMA user_version = \(m.version)")
        return .commit
      }
    }
    return try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
  }
}
```

Use `BEGIN` (deferred), matching expo's `withTransactionAsync`, which issues `BEGIN` / `COMMIT` / `ROLLBACK` (`node_modules/expo-sqlite/src/SQLiteDatabase.ts:140-149`). Accept a migration subset parameter, as the TS version does. Tests use it to stop at an older version.

### 3.2 Ordered migration list (verbatim SQL; embed exactly)

Each `up` string is executed as one multi-statement script. Comments between statements are harmless and do not reach `sqlite_master`. Copy the text verbatim from `src/db/migrations.ts` into Swift raw string literals (`#"""…"""#`). Note that the JS sources escape backticks inside comments as `` \` ``; in Swift write them as plain backticks.

**Indentation gotcha (byte-identical `sqlite_master`):** SQLite stores each `CREATE` statement's text from the `CREATE` keyword to the end of the statement, *including the newlines and indentation inside it* (for example the 8-space column indents and the 6-space `)` line). The JS template literals keep the source indentation exactly: statements at 6 spaces, columns at 8 (`src/db/migrations.ts:29-96`). A Swift multi-line string literal **strips the indentation of its closing `"""#` delimiter from every line**. So either put the closing delimiter at column 0 and paste each JS line unchanged, or indent the literal so that, after stripping, every line still has exactly its JS indentation. Pin it with the byte-equality test in §13.8 #4. This matters for that test and for diffing schemas; SQLite does not care functionally.

**v1 `initial_inventory_schema`** (`src/db/migrations.ts:25-98`)

```sql
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
```

(Whitespace above is reflowed. The exact text in `sqlite_master` keeps the source indentation; see §4.1. Embed from the source file to keep it byte-identical.)

**v2 `add_search_normalization_columns`** (`:99-113`)

```sql
ALTER TABLE items ADD COLUMN search_text TEXT NOT NULL DEFAULT '';
UPDATE items
   SET search_text = TRIM(LOWER(name || ' ' || COALESCE(category, '')));
CREATE INDEX idx_items_search_text ON items(search_text);
```

The backfill uses SQLite's ASCII-only `LOWER` and space-only `TRIM`. Rows written by the app use JS `toLowerCase` and `trim` (§7.3.1), so a pre-v2 row containing non-ASCII capitals keeps them in `search_text` until its next `items.update`. **Any** update rewrites it, including a quantity tap or a move, because `items.update` always recomputes `search_text` from the merged name and category (`src/repositories/items.ts:324`). That is a historical quirk; do not rewrite in bulk. The corollary for Swift: every update rewrites `search_text` with the *Swift* lowercasing, so any difference from the JS lowercasing (§6.5) spreads into stored rows over time.

**v3 `add_drop_zone`** (`:114-143`)

```sql
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
```

The icon is U+1F4E5 📥. The timestamps are whole seconds × 1000.

**v4 `add_photo_sync_state`** (`:144-182`)

```sql
ALTER TABLE item_photos ADD COLUMN remote_synced_at INTEGER;

CREATE INDEX idx_item_photos_unsynced
  ON item_photos(created_at)
  WHERE remote_synced_at IS NULL;

CREATE TABLE sync_deletions (
  photo_id   TEXT PRIMARY KEY NOT NULL,
  deleted_at INTEGER NOT NULL
);

CREATE TRIGGER item_photos_tombstone
AFTER DELETE ON item_photos
WHEN OLD.remote_synced_at IS NOT NULL
BEGIN
  INSERT OR REPLACE INTO sync_deletions (photo_id, deleted_at)
  VALUES (OLD.id, CAST(strftime('%s','now') AS INTEGER) * 1000);
END;
```

The trigger fires on **every** photo row delete, including cascades from item, container and space deletes, and the delete-and-reinsert in `items.update({photo})`. It records only photos that had been uploaded.

**v5 `add_photo_thumbnails`** (`:183-197`)

```sql
ALTER TABLE item_photos ADD COLUMN thumb_uri TEXT;
```

**v6 `drop_item_value_estimate`** (`:198-218`)

```sql
ALTER TABLE items DROP COLUMN estimated_value;
ALTER TABLE items DROP COLUMN currency;
```

**v7 `allow_zero_quantity`**, `rebuild: true` (`:219-261`)

```sql
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
```

Foreign keys **must be OFF** while this runs. With them on, `DROP TABLE items` cascade-deletes every `item_photos` and `item_tags` row. The trigger is on `item_photos`, not `items`, so the rebuild does not affect it.

### 3.3 Schema at each historical version (to recognise any file)

| `user_version` | State |
|---|---|
| 0 | Empty file (fresh install, or never opened). |
| 1 | v1 tables. `items` has `estimated_value`, `currency`, `CHECK (quantity > 0)`. No `search_text`, no `kind`, no drop zone, no `remote_synced_at` / `thumb_uri` / `sync_deletions` / trigger. |
| 2 | + `items.search_text` (backfilled) + `idx_items_search_text`. |
| 3 | + `spaces.kind`, `containers.kind`, drop-zone space and container rows. |
| 4 | + `item_photos.remote_synced_at`, `idx_item_photos_unsynced`, `sync_deletions`, trigger `item_photos_tombstone`. |
| 5 | + `item_photos.thumb_uri`. |
| 6 | − `items.estimated_value`, − `items.currency`. |
| 7 | `items` rebuilt with `CHECK (quantity >= 0)`. Final (§4). |

The only discriminator is `user_version`. Never infer the version from the schema.

---

## 4. Final schema (version 7)

### 4.1 Exact `sqlite_master` contents

Generated by running all migrations on Node's SQLite and dumping `sqlite_master` in rowid order. A database created on a device by the RN app has the same text. A native fresh install must produce the same text, which it will if it runs the same SQL with the same whitespace (see the indentation gotcha in §3.2). Column additions appear as `, col …` appended to the original `CREATE TABLE` text, and the rebuilt table is quoted as `"items"`.

Formatting of the block below: the stored `sql` values have **no trailing `;`**; the semicolons are only there for readability. The `-- …` lines are annotations. The `sqlite_autoindex_*` rows exist in `sqlite_master` with `sql = NULL`. (Re-verified by the reviewer on Node 24 / SQLite 3.53.1: the text, the rowid order and the `NULL` autoindex rows all match.)

```sql
-- table spaces
CREATE TABLE spaces (
        id          TEXT PRIMARY KEY NOT NULL,
        name        TEXT NOT NULL,
        icon        TEXT NOT NULL DEFAULT 'cube',
        color       TEXT NOT NULL DEFAULT '#5B8DEF',
        created_at  INTEGER NOT NULL,
        updated_at  INTEGER NOT NULL
      , kind TEXT NOT NULL DEFAULT 'normal');
-- index sqlite_autoindex_spaces_1 (PK)

-- table containers
CREATE TABLE containers (
        id          TEXT PRIMARY KEY NOT NULL,
        space_id    TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
        name        TEXT,
        visual_type TEXT NOT NULL DEFAULT 'box',
        short_code  TEXT NOT NULL UNIQUE,
        created_at  INTEGER NOT NULL,
        updated_at  INTEGER NOT NULL
      , kind TEXT NOT NULL DEFAULT 'normal');
-- index sqlite_autoindex_containers_1 (PK), sqlite_autoindex_containers_2 (UNIQUE short_code)
CREATE INDEX idx_containers_space ON containers(space_id);

-- table item_photos
CREATE TABLE item_photos (
        id         TEXT PRIMARY KEY NOT NULL,
        item_id    TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
        uri        TEXT NOT NULL,
        width      INTEGER,
        height     INTEGER,
        byte_size  INTEGER,
        created_at INTEGER NOT NULL
      , remote_synced_at INTEGER, thumb_uri TEXT);
-- index sqlite_autoindex_item_photos_1 (PK)
CREATE INDEX idx_item_photos_item ON item_photos(item_id);

-- table tags
CREATE TABLE tags (
        id              TEXT PRIMARY KEY NOT NULL,
        name            TEXT NOT NULL,
        normalized_name TEXT NOT NULL UNIQUE,
        created_at      INTEGER NOT NULL
      );
-- index sqlite_autoindex_tags_1 (PK), sqlite_autoindex_tags_2 (UNIQUE normalized_name)

-- table item_tags
CREATE TABLE item_tags (
        item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
        tag_id  TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
        PRIMARY KEY (item_id, tag_id)
      );
-- index sqlite_autoindex_item_tags_1 (PK item_id, tag_id)
CREATE INDEX idx_item_tags_tag ON item_tags(tag_id);

-- table qr_bindings
CREATE TABLE qr_bindings (
        id           TEXT PRIMARY KEY NOT NULL,
        token        TEXT NOT NULL UNIQUE,
        container_id TEXT NOT NULL REFERENCES containers(id) ON DELETE CASCADE,
        created_at   INTEGER NOT NULL,
        updated_at   INTEGER NOT NULL
      );
-- index sqlite_autoindex_qr_bindings_1 (PK), sqlite_autoindex_qr_bindings_2 (UNIQUE token)
CREATE INDEX idx_qr_bindings_container ON qr_bindings(container_id);

CREATE INDEX idx_item_photos_unsynced
        ON item_photos(created_at)
        WHERE remote_synced_at IS NULL;

-- table sync_deletions
CREATE TABLE sync_deletions (
        photo_id   TEXT PRIMARY KEY NOT NULL,
        deleted_at INTEGER NOT NULL
      );
-- index sqlite_autoindex_sync_deletions_1 (PK)

CREATE TRIGGER item_photos_tombstone
      AFTER DELETE ON item_photos
      WHEN OLD.remote_synced_at IS NOT NULL
      BEGIN
        INSERT OR REPLACE INTO sync_deletions (photo_id, deleted_at)
        VALUES (OLD.id, CAST(strftime('%s','now') AS INTEGER) * 1000);
      END;

-- table items (rebuilt in v7; SQLite rewrote the name to "items")
CREATE TABLE "items" (
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
-- index sqlite_autoindex_items_1 (PK)
CREATE INDEX idx_items_container ON items(container_id);
CREATE INDEX idx_items_name ON items(name COLLATE NOCASE);
CREATE INDEX idx_items_search_text ON items(search_text);
```

`PRAGMA user_version = 7`, `journal_mode = wal`.

**Not present:** FTS or virtual tables, views, and any trigger other than `item_photos_tombstone`.

### 4.2 Foreign keys and cascade graph

`spaces` → `containers` (CASCADE) → `items` (CASCADE) → `item_photos` (CASCADE, fires tombstone trigger) and `item_tags` (CASCADE). `containers` → `qr_bindings` (CASCADE). `tags` → `item_tags` (CASCADE). `tags` rows themselves are **never deleted** by the app; the tag vocabulary outlives items (test `persistence.test.ts:445`).

### 4.3 Seeded system rows (from v3)

| Table | id | name | other |
|---|---|---|---|
| spaces | `drop-zone-space` | `Drop zone` | icon `📥`, color `#0F9BB0`, kind `system` |
| containers | `drop-zone` | `Drop zone` | space `drop-zone-space`, visual_type `other`, short_code `DROP-ZONE`, kind `system` |

Constants: `DROP_ZONE_CONTAINER_ID = 'drop-zone'` and `DROP_ZONE_SPACE_ID = 'drop-zone-space'` (`src/db/constants.ts:26-27`). The repositories refuse to modify these rows (§7). List queries filter on `kind = 'normal'`.

### 4.4 Column semantics

- Every `*_at` value is **integer epoch milliseconds**, from JS `Date.now()` (integer ms). Native: `Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))`. The exceptions are SQL-generated values (`strftime('%s','now')*1000`, whole seconds): the v3 seed rows and `sync_deletions.deleted_at`.
- `items.name` is `''` for an item that has no name yet. The UI shows `strings.entities.unnamedItem`.
- `items.quantity` is a non-negative integer (DB CHECK `>= 0`). The 9999 cap is applied **only** by UI paths that call `clampQuantity`: the stepper (`src/ui/components/QuantityStepper.tsx:211,220,268`) and `useSavedQuantity`. The item form's `validateItemForm` (`src/ui/components/ItemForm.tsx:57`) and `app/item/new.tsx:630` use `parseQuantityInput`, which returns values above 9999 unclamped, and the repository has no upper bound. So stored values above 9999 are possible, and the Swift model must not assume ≤ 9999 when decoding.
- `items.search_text` = `lower(trim(name + ' ' + (category ?? '')))`, maintained by the app (§7.3.1). It is not a generated column.
- `containers.name` is NULL when blank (never `''` via the repositories).
- `containers.visual_type` is one of `box, drawer, shelf, cabinet, bin, bag, crate, other` (`src/db/types.ts:56-65`, in that order). Import, shadow and household paths may write other strings, so the Swift type must preserve unknown raw values (§5).
- `item_photos.uri` / `thumb_uri` are absolute `file://` URIs into `Documents/item-photos/` on the device that wrote them (`src/services/capture/imageStore.ts:28,40,84`), or household URIs while paired. **The iOS container path segment can change between installs or updates.** Resolve files by re-rooting the path under the current `Documents` directory (dependency on the photo spec; see §15).
- `tags.normalized_name` = `trim(name).toLowerCase()`. `tags.name` keeps the **first** spelling ever used.

### 4.5 Other code that reads or writes the schema directly (keep compatible)

| Consumer | SQL touchpoints |
|---|---|
| Photo sync (`src/services/sync/photoSync.ts:53-57,69,81,104,116,137-141,158`) | `item_photos.remote_synced_at`, `sync_deletions`, rewriting `uri`/`thumb_uri`/`byte_size` |
| Household dump (`src/services/household/collectDump.ts:24,36,50,58,61,70,80,142`) | SELECTs every column of every table, including `kind` and `search_text` |
| Shadow mirror (`src/services/household/shadow.ts:116-259`) | UPSERTs into spaces, containers, items, item_photos, tags, item_tags, qr_bindings |
| Home server importer (`home-server/src/importer.ts`) | Same tables, UPSERT. The home server runs **these same migrations** (`home-server/src/index.ts:44`). |

---

## 5. Domain types (Swift mapping)

From `src/db/types.ts`. Use `Sendable`, `Hashable` value types. Integer timestamps are `Int64`. The JSON keys for the household wire format are the camelCase TS names shown (household spec).

| TS type (`src/db/types.ts`) | Fields |
|---|---|
| `Space` `:35-42` | `id, name, icon, color, createdAt, updatedAt` (no `kind`) |
| `Container` `:45-54` | `id, spaceId, name: String?, visualType, shortCode, createdAt, updatedAt` (no `kind`) |
| `Item` `:70-79` | `id, containerId, name, category: String?, quantity: Int, notes: String?, createdAt, updatedAt` |
| `ItemPhoto` `:82-92` | `id, itemId, uri, thumbUri?, width?, height?, byteSize?, createdAt` |
| `Tag` `:94-99` | `id, name, normalizedName, createdAt` (not used by the UI) |
| `QrBinding` `:102-108` | `id, token, containerId, createdAt, updatedAt` |
| `SpaceWithCounts` `:111-114` | `Space` + `containerCount, itemCount` |
| `ContainerWithCounts` `:117-120` | `Container` + `itemCount, qrToken: String?` |
| `ItemWithContext` `:123-143` | `Item` + `photoId?, photoUri?, photoThumbUri?, tags: [String], spaceId, spaceName, spaceIcon, spaceColor, containerName?, containerShortCode` |
| `ItemSearchResult` (`src/repositories/search.ts:13-15`) | `ItemWithContext` + `matchKind: 'direct' \| 'location'` |
| `LocationSearchResult` (`search.ts:17-24`) | `kind: 'space' \| 'container', id, title, subtitle, spaceId, itemCount` |
| `SearchResults` (`search.ts:26-30`) | `terms: [String], locations: [LocationSearchResult], items: [ItemSearchResult]` |

`ContainerVisualType`: the TS code casts any DB string (`src/repositories/containers.ts:26`). In Swift, use `struct ContainerVisualType: RawRepresentable, Hashable, Sendable { let rawValue: String }` with static members for the 8 known values. Code that switches on it must have a default branch. A plain `enum` would either drop or rewrite unknown values.

---

## 6. Core logic

### 6.1 IDs and QR tokens (`src/core/id.ts`)

- The randomness source is injected (`configureRandomBytes`, `:15-17`). It throws `'Random bytes source is not configured. Call configureRandomBytes() at process start.'` when unset (`:26-33`). There is deliberately no `Math.random` fallback.
- `newId()` (`:41-54`): take 16 random bytes; `b[6] = (b[6] & 0x0f) | 0x40`; `b[8] = (b[8] & 0x3f) | 0x80`; encode as lowercase hex; group 8-4-4-4-12 with `-`. Example from the test: bytes 0…15 → `00010203-0405-4607-8809-0a0b0c0d0e0f`.
- `newQrToken()` (`:62-64`): 16 random bytes as lowercase hex, 32 characters, no dashes.
- `toHex` (`src/core/bytes.ts:11-17`): lowercase, two digits per byte.
- **Native:** a `RandomSource` protocol whose production implementation uses `SecRandomCopyBytes`, so the test vector can be reproduced. `UUID().uuidString` is upper case, so if you use `UUID()`, call `.lowercased()`. The format is identical: v4, CSPRNG.

### 6.2 Short codes (`src/core/shortCode.ts`)

- Alphabet: `23456789ABCDEFGHJKLMNPQRSTUVWXYZ` (32 characters; no 0, 1, I, O) (`:7`). Suffix length 4 (`:8`).
- Prefixes (`:10-19`): box→`BOX`, drawer→`DRW`, shelf→`SHF`, cabinet→`CAB`, bin→`BIN`, bag→`BAG`, crate→`CRT`, other→`CTR`. Unknown types → `CTR` (`:36`).
- `generateShortCode(type)` = `PREFIX + '-' + 4 random characters` (`:35-37`). JS uses `Math.random` (`:21-27`). Native: `SystemRandomNumberGenerator`, which is fine.
- Uniqueness is enforced only by the `UNIQUE(short_code)` constraint plus the retry loop in `containers.create` (§7.2).
- `normalizeShortCode(s)` = `trim → toUpperCase → remove /[\s-]+/g` (`:40-45`). It is **only used in tests**; no production caller. Port it for parity, or drop it.

### 6.3 Conflict error (`src/core/conflict.ts:8-16`)

`ConflictError { status = 409, code = 'conflict', message = 'conflict', updatedAt: number | null }`.

- Thrown by local `items.update` when `expectedUpdatedAt` no longer matches (§7.3).
- Thrown by the household client on HTTP 409. The body is `{ error: 'conflict', updatedAt }` (`home-server/src/inventory.ts:298-299`), and `updatedAt` is parsed only when finite (`src/services/household/client.ts:125-130`).
- `describeError` maps it to kind `conflict` with `strings.errors.conflict` (`src/ui/errors.ts:48-50`).
- **Swift:** `struct ConflictError: Error, Sendable { let updatedAt: Int64? }`. Both the local and HTTP stores throw this one type.

### 6.4 Quantity (`src/core/quantity.ts`)

- `MIN_QUANTITY = 0`, `MAX_QUANTITY = 9999` (`:8-9`).
- `clampQuantity(v)` (`:12-17`): not an integer (including NaN and ±Infinity) → 0; < 0 → 0; > 9999 → 9999; otherwise v. `-0` → `-0`, which is 0.
- `parseQuantityInput(raw)` (`:26-32`): `trimmed = raw.trim()`; empty → `nil`; `v = Number(trimmed)`; if `!isInteger(v) || v < 0` → `nil`; otherwise v. **Values above 9999 are returned unclamped**; the stepper clamps on commit.
  - JS `Number()` grammar matters for parity. Verified in Node:
    - **accepted:** `"1.0"`→1, `"1e2"`→100, `"0x1F"`→31, `"0b11"`→3, `"+5"`→5, `"5."`→5, `"00012"`→12, `"-0"`→0, `" 7\n"`→7, `"12345"`→12345;
    - **rejected (`nil`):** `".5"`, `"1_000"`, `"Infinity"`, `"٣"`, `"1,5"`, `"1e-7"`, `"abc"`, `"1.5"`, `"-1"`.
  - Recommended Swift implementation: accept `^[+]?[0-9]+(\.0*)?$` and also `[eE]\+?[0-9]+` exponents, plus `0x`/`0b`/`0o` prefixes, **only** if parity with paste input matters. Use the explicit `[0-9]` class (or `.asciiOnlyDigits()`): Swift `Regex`'s `\d` and `Int(_:)`-style helpers that accept Unicode digits would let `"٣"` through, and JS rejects it. Trim with `jsTrim()` (§11), not `.whitespacesAndNewlines`. At minimum, match the test vectors (§13). The field uses a number keypad, so exotic input only arrives by paste. **Open question Q4.**
- `stepQuantity(current, delta)` = `clampQuantity(current + delta)` (`:34-36`).
- The repository's own guard is `requireQuantity`: not an integer or `< 0` → throw `'Quantity must be a whole number of 0 or more.'` (`src/repositories/items.ts:30-35`). There is no upper bound in the repository.

### 6.5 Tokenizer and folding (`src/core/tokenize.ts`)

- `MAX_TERMS = 12` (`:5`). `COMBINING_MARKS = /[̀-ͯ]/g` (`:8`). The source contains the literal characters U+0300 and U+036F.
- `tokenizeQuery(q)` (`:18-36`), applied in this order:
  1. `''` → `[]`.
  2. `toLowerCase()` (full Unicode, locale-independent, **context-sensitive final sigma**: `"ΟΔΟΣ"` → `"οδος"`, last character U+03C2; `"İ"` → `"i̇"` = U+0069 U+0307).
  3. `normalize('NFKD')` (compatibility decomposition: `ﬁ`→`fi`, `①`→`1`, full-width forms→ASCII). **NFKD runs after lowercasing, and its output is not lowercased again.** Characters that have no lowercase mapping but decompose to capitals therefore keep the capitals: `™`→`TM`, `𝐀BC`→`Abc`, `ℌ`→`H`, `㎒`→`MHz` (verified in Node; see §6.6). `Ⅻ` comes out as `xii` only because `toLowerCase` first maps U+216B to U+217B (`ⅻ`). The Swift port must use the same order: lowercase, then NFKD, then strip. Doing NFKD first changes results. SQL search does not notice ASCII capitals, because SQLite `LIKE` is ASCII case-insensitive. `placeMatch` does notice, because `String.includes` is case-sensitive: a filter typed as `™` does not match a container named "tm".
  4. Remove U+0300–U+036F (and only that range).
  5. Split on runs of `[^\p{Letter}\p{Number}-]`. `\p{Letter}` is General Category L* (Lu, Ll, Lt, Lm, Lo). `\p{Number}` is N* (Nd, Nl, No). `-` is ASCII U+002D only. **Other combining marks (Mn/Mc outside U+0300–036F) act as separators.**
  6. Strip leading and trailing `-` from each piece (`/^-+|-+$/g`). Drop empty pieces.
  7. Deduplicate, keeping first-occurrence order. Stop once 12 unique terms are collected.
- `toLikePattern(t)` (`:39-42`): prefix each `\`, `%` and `_` with `\`, then wrap as `%…%`. It is always used with `ESCAPE '\'`.
- `compactAlphanumeric(v)` (`:55-61`): `toLowerCase → NFKD → strip U+0300–036F → remove every scalar that is not L*/N*` (global). Dashes are removed too.
- `normalizeForCodeMatch` = `compactAlphanumeric` (`:45-47`). Only used in tests.

**Native implementation notes:**
- Work on `String.unicodeScalars`, not `Character`. JS regexes with `/u` match code points.
- Lowercasing must reproduce JS. Swift's `String.lowercased()` may not apply the final-sigma rule. Test `"ΟΔΟΣ sign"` → `"οδος sign"` with U+03C2, and pick an API that passes: Foundation `NSString.lowercased` / `lowercased(with: Locale(identifier: "en_US_POSIX"))`, or a manual final-sigma pass. The same lowercase function must be used for `search_text`, `tags.normalized_name`, the tokenizer, compacting, `categoryMemory` keys and `placeMatch`.
- NFKD: `decomposedStringWithCompatibilityMapping`.
- L*/N*: `scalar.properties.generalCategory` in {`.uppercaseLetter`, `.lowercaseLetter`, `.titlecaseLetter`, `.modifierLetter`, `.otherLetter`, `.decimalNumber`, `.letterNumber`, `.otherNumber`}.
- **Which engine produced the existing data:** the vectors in §6.6 were verified in **Node (V8 + ICU)**, which is what the home server runs. The phone app runs on **Hermes, not V8**. Hermes ships its own Unicode tables for regex `\p{…}`. On Apple platforms its `toLowerCase` / `normalize` / `localeCompare` are understood to go through CoreFoundation/Foundation (Hermes' platform-Unicode layer and its Apple `Intl` implementation). That is not verifiable from this repo, because Hermes is a prebuilt binary. So the `search_text`, `tags.normalized_name` and category keys already on users' devices were most likely produced by **CoreFoundation's** case mapping. The two agree on every vector in §6.6 as far as is known, but the parity target is an open question (Q10). Unicode versions also differ slightly between the engines; this only affects recently assigned code points.

### 6.6 Folding test vectors (verified in Node for this spec)

| Input | `tokenizeQuery` | `compactAlphanumeric` |
|---|---|---|
| `Cordless Drill` | `["cordless","drill"]` | — |
| `BOX-7K2M` | `["box-7k2m"]` | `box7k2m` |
| `-drill-` | `["drill"]` | — |
| `a--b- --c` | `["a--b","c"]` | — |
| `Café` | `["cafe"]` | `cafe` |
| `ワイヤー` | `["ワイヤー"]` | — |
| `ガラス` | `["カ","ラス"]` (U+3099 dakuten splits the word) | `カラス` |
| `ﬁle Ⅻ ①` | `["file","xii","1"]` | — |
| `ΟΔΟΣ` | `["οδος"]` (U+03C2) | — |
| `İstanbul` | `["istanbul"]` | — |
| `emoji 🔧x` | `["emoji","x"]` | — |
| `under_score` | `["under","score"]` | — |
| `o'neil` | `["o","neil"]` | — |
| `Straße` | `["straße"]` (ß is not expanded) | — |
| `™ 𝐀BC ℌ ㎒ Ｆｕｌｌ` | `["TM","Abc","H","MHz","full"]` (**capitals survive**: NFKD runs after lowercasing) | `TMAbcHMHzfull` |
| `ǅ` (U+01C5, titlecase) | `["dz"]` | `dz` |
| `ΣΑΣ Σ` | `["σας","σ"]` (final sigma only at the end of a word; a lone `Σ` → `σ`) | — |
| `aΣ.` | `["aς"]` (U+03C2: the following `.` counts as a word end) | — |
| `USB-C` / `usb c` / `usb/c` | — | `usbc` |
| `Küche` / `Кухня` | — | `kuche` / `кухня` |
| `a\b` | `toLikePattern` → `%a\\b%` | — |

---

## 7. Repositories (local SQLite implementation)

General rules:
- Every SQL statement below is the **exact text** from the source. Keep it, including `?1` numbered parameters (SQLite supports them; GRDB passes positional arguments).
- `Date.now()` is called at the points stated. Some functions call it more than once, and those calls can differ by a millisecond.
- No repository method calls `invalidate()`. Callers do (§9.1).
- Errors are thrown as `Error(message)`. The UI never shows `message` (`src/ui/errors.ts:32-40`). Any non-household, non-conflict error is kind `local` (`src/ui/errors.ts:77-81`). Swift: define `enum InventoryError: Error { case systemRecord, nameRequired, invalidQuantity, shortCodeExhausted }` and keep the messages for logs (`'system_record'`, `'Item name is required.'`, `'Quantity must be a whole number of 0 or more.'`, `'Could not allocate a unique container code. Please try again.'`). No app code matches on these messages.
- `changes` (`runAsync(...).changes`) is `sqlite3_changes()` for that one statement. It counts rows the statement matched directly; cascaded and trigger-inserted rows are not counted. An `UPDATE` that writes identical values still counts 1. GRDB equivalent: read `db.changesCount` immediately after the statement.
- **Composition / nesting:** repository methods open their own transactions (`withTransactionAsync`), and the Node adapter turns nested calls into SAVEPOINTs (`src/db/nodeDatabase.ts:78-95`). Test `persistence.test.ts:396` calls `items.create` *inside* an outer transaction and expects the outer rollback to remove it. No production code nests today, but other areas (shadow mirror, import) may want to compose repository writes. In GRDB, `DatabaseQueue.write {}` is not reentrant, and `inTransaction` cannot nest. Write each mutation as a core function that takes a `Database` (`func create(_:in db: Database) throws`), using `db.inSavepoint { … }` for its atomic block (it behaves as a transaction at the top level and as a savepoint when nested). Add a thin `writer.write { try create(draft, in: $0) }` wrapper for callers.
- Rows read back are decoded into the TS types with no coercion. INTEGER columns hold integers (INTEGER affinity converts integral REALs on storage).

Shared projection, `ITEM_CONTEXT_SELECT` (`src/repositories/items.ts:72-91`):

```sql
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
```

- The primary photo is the earliest by `created_at`. Ties are broken arbitrarily.
- Tags come from `GROUP_CONCAT` with separator U+001F. Split with `splitTagNames` (`src/db/constants.ts:16-18`): `null`/`''` → `[]`; otherwise split on U+001F and drop empty strings. `TAG_DELIMITER` is the literal U+001F (`constants.ts:6`).
- **Tag order** is not specified by SQL. In practice it follows the `item_tags` PK index `(item_id, tag_id)`, which means ascending tag id, a random UUID order (verified with `EXPLAIN QUERY PLAN`). Keep the same SQL so the order matches; do not sort.
- `TAG_NAMES_SUBQUERY` (`constants.ts:9-14`) is dead code.

### 7.1 Spaces (`src/repositories/spaces.ts`)

`assertNotDropZone(id)`: `id == 'drop-zone-space'` → throw `'system_record'` (`:44-46`).

| Function | Behaviour |
|---|---|
| `listWithCounts()` `:63-82` | SQL below. Counts are row counts; quantity-0 items count. |
| `getById(id)` `:84-87` | `SELECT * FROM spaces WHERE id = ?` → `Space?`. Works for the drop-zone space too. |
| `create({name, icon, color})` `:89-107` | `now = Date.now()`, `id = newId()`, `name = input.name.trim()`. **No empty-name validation** (the UI validates). `INSERT INTO spaces (id, name, icon, color, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)`. `kind` takes its default `'normal'`. Returns the `Space`. |
| `update(id, {name?, icon?, color?})` `:110-129` | Drop-zone guard **first**, then `getById`; missing → `nil`. `name = input.name?.trim() ?? existing.name`, so a provided `'  '` saves `''`. `icon`/`color` = input ?? existing. `updatedAt = Date.now()`. `UPDATE spaces SET name = ?, icon = ?, color = ?, updated_at = ? WHERE id = ?`. Returns the merged struct (not re-read). `id` and `createdAt` never change. |
| `deletionImpact(id)` `:132-159` | SQL below. Returns `{containerCount, itemCount, photoCount, qrBindingCount}`; missing values → 0. |
| `delete(id)` `:168-195` | Drop-zone guard. **In one transaction:** select photo URIs, then `DELETE FROM spaces WHERE id = ?`. `deleted = changes > 0`. Returns `{deleted, orphanedPhotoUris}`, where the list is `[uri, thumb_uri]` per photo with NULLs dropped, in unspecified photo order. Cascades remove containers, items, photos (the trigger tombstones synced ones), tag links and QR bindings. The caller deletes the files (for example `app/space/[id]/edit.tsx:164`). |

```sql
-- listWithCounts
SELECT s.*,
       (SELECT COUNT(*) FROM containers c WHERE c.space_id = s.id)
         AS container_count,
       (SELECT COUNT(*) FROM items i
          JOIN containers c ON c.id = i.container_id
         WHERE c.space_id = s.id)
         AS item_count
  FROM spaces s
 WHERE s.kind = 'normal'
 ORDER BY s.name COLLATE NOCASE ASC

-- deletionImpact (single bound argument ?1)
SELECT
  (SELECT COUNT(*) FROM containers WHERE space_id = ?1) AS container_count,
  (SELECT COUNT(*) FROM items i JOIN containers c ON c.id = i.container_id
    WHERE c.space_id = ?1) AS item_count,
  (SELECT COUNT(*) FROM item_photos p
     JOIN items i ON i.id = p.item_id
     JOIN containers c ON c.id = i.container_id
    WHERE c.space_id = ?1) AS photo_count,
  (SELECT COUNT(*) FROM qr_bindings q
     JOIN containers c ON c.id = q.container_id
    WHERE c.space_id = ?1) AS qr_count

-- delete (inside transaction)
SELECT p.uri, p.thumb_uri FROM item_photos p
  JOIN items i ON i.id = p.item_id
  JOIN containers c ON c.id = i.container_id
 WHERE c.space_id = ?
DELETE FROM spaces WHERE id = ?
```

`COLLATE NOCASE` folds ASCII only. Ties are in unspecified order.

### 7.2 Containers (`src/repositories/containers.ts`)

`assertNotDropZone(id)`: `id == 'drop-zone'` → throw `'system_record'` (`:57-59`). `SHORT_CODE_ATTEMPTS = 10` (`:62`).

| Function | Behaviour |
|---|---|
| `listBySpace(spaceId)` `:66-83` | SQL below; `kind = 'normal'`; `ORDER BY c.created_at DESC`. Returns `ContainerWithCounts[]`. |
| `getById(id)` `:85-90` | `SELECT * FROM containers WHERE id = ?` (no kind filter). |
| `getWithCounts(id)` `:92-104` | Same projection as `listBySpace` with `WHERE c.id = ?` (no kind filter, so the drop zone is reachable). |
| `create({spaceId, name?, visualType})` `:112-151` | `now` computed once. `name = trimmed or nil if blank`. Loop up to 10 times with a **new `newId()` and a new short code each time**: `INSERT INTO containers (id, space_id, name, visual_type, short_code, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)`. If it fails and the message matches `/UNIQUE\|constraint/i`, retry; any other error is rethrown. After 10 failures, throw `'Could not allocate a unique container code. Please try again.'`. **Quirk:** a FOREIGN KEY failure (unknown `spaceId`) also matches "constraint", so it retries 10 times and then throws the short-code message (test `persistence.test.ts:302` only asserts that it rejects). No guard against `spaceId = 'drop-zone-space'`. |
| `update(id, {name?, visualType?, spaceId?})` `:153-175` | Drop-zone guard (on the container id only), then `getById`; missing → `nil`. `name`: `undefined` → keep; `null` or blank → `NULL`; otherwise trimmed. `visualType`/`spaceId` = input ?? existing. `updatedAt = Date.now()`. `UPDATE containers SET name = ?, visual_type = ?, space_id = ?, updated_at = ? WHERE id = ?`. Returns the merged struct, not re-read. `short_code` and `kind` never change: changing `visualType` keeps the old prefix (a `BOX-…` code on a drawer). **No guard on the target `spaceId`:** a container can be moved into `'drop-zone-space'` through the repository, and an unknown `spaceId` fails with an FK error, a plain throw with no retry. The `changes` count is ignored, so a row deleted between the read and the `UPDATE` still returns the merged struct. |
| `deletionImpact(id)` `:177-196` | SQL below → `{itemCount, photoCount, hasQrBinding: qr_count > 0}`. |
| `delete(id)` `:198-222` | Drop-zone guard. Transaction: select photos, then `DELETE FROM containers WHERE id = ?`. Same return shape as `spaces.delete`. |
| `listAllWithSpace()` `:225-240` | Place picker source. SQL below → `Container & {spaceName, itemCount}`. |

```sql
-- listBySpace
SELECT c.*,
       (SELECT COUNT(*) FROM items i WHERE i.container_id = c.id) AS item_count,
       (SELECT q.token FROM qr_bindings q WHERE q.container_id = c.id
         ORDER BY q.created_at DESC LIMIT 1) AS qr_token
  FROM containers c
 WHERE c.space_id = ? AND c.kind = 'normal'
 ORDER BY c.created_at DESC

-- getWithCounts
SELECT c.*,
       (SELECT COUNT(*) FROM items i WHERE i.container_id = c.id) AS item_count,
       (SELECT q.token FROM qr_bindings q WHERE q.container_id = c.id
         ORDER BY q.created_at DESC LIMIT 1) AS qr_token
  FROM containers c
 WHERE c.id = ?

-- deletionImpact
SELECT
  (SELECT COUNT(*) FROM items WHERE container_id = ?1) AS item_count,
  (SELECT COUNT(*) FROM item_photos p JOIN items i ON i.id = p.item_id
    WHERE i.container_id = ?1) AS photo_count,
  (SELECT COUNT(*) FROM qr_bindings WHERE container_id = ?1) AS qr_count

-- delete (inside transaction)
SELECT p.uri, p.thumb_uri FROM item_photos p
  JOIN items i ON i.id = p.item_id
 WHERE i.container_id = ?
DELETE FROM containers WHERE id = ?

-- listAllWithSpace
SELECT c.*, s.name AS space_name,
       (SELECT COUNT(*) FROM items i WHERE i.container_id = c.id) AS item_count
  FROM containers c
  JOIN spaces s ON s.id = c.space_id
 WHERE c.kind = 'normal'
 ORDER BY s.name COLLATE NOCASE ASC, c.created_at DESC
```

**Native retry:** catch `DatabaseError` with `resultCode == .SQLITE_CONSTRAINT`, covering all extended codes, to match the TS behaviour. A cleaner alternative is to retry only on `SQLITE_CONSTRAINT_UNIQUE` / `SQLITE_CONSTRAINT_PRIMARYKEY` and rethrow FK failures, but that changes the error (**open question Q5**).

### 7.3 Items (`src/repositories/items.ts`)

#### 7.3.1 Helpers

- `normalizeTag(t)` = `t.trim().toLowerCase()` (`:126-128`).
- `searchTextFor(name, category)` = `` `${name} ${category ?? ''}`.trim().toLowerCase() `` (`:130-132`). Trim happens **before** lowercasing. The same formula appears in `shadow.ts:153`.
- `upsertTags(tags)` (`:136-165`). For each raw tag in order: `name = raw.trim()`, `normalized = lower(name)`; skip if empty or already seen in this call. Then `SELECT id FROM tags WHERE normalized_name = ?`. If found, reuse the id; **its `name` is not updated**. Otherwise `INSERT INTO tags (id, name, normalized_name, created_at) VALUES (?, ?, ?, ?)` with `newId()` and `Date.now()`. Returns the ids in input order.
- `replaceTags(itemId, tags)` (`:167-173`): `upsertTags` first, then `DELETE FROM item_tags WHERE item_id = ?`, then `INSERT INTO item_tags (item_id, tag_id) VALUES (?, ?)` for each id.

#### 7.3.2 Reads

| Function | SQL suffix on `ITEM_CONTEXT_SELECT` | Notes |
|---|---|---|
| `listByContainer(cid)` `:176-182` | `WHERE i.container_id = ? ORDER BY i.created_at DESC` | |
| `listUnsorted()` `:185-191` | `WHERE i.container_id = ? ORDER BY i.created_at DESC`, bound to `'drop-zone'` | The drop zone, newest first |
| `listRecent(limit = 40)` `:194-201` | `ORDER BY i.created_at DESC LIMIT ?` | `cap = max(1, min(floor(limit), 100))`. Includes drop-zone items. |
| `getById(id)` `:212-217` | `WHERE i.id = ?` | → `ItemWithContext?` |
| `countUnsorted()` `:204-210` | `SELECT COUNT(*) AS count FROM items WHERE container_id = ?` (`'drop-zone'`) | Not used by the UI (DropZoneProvider counts the list) |
| `countAll()` `:426-429` | `SELECT COUNT(*) AS count FROM items` | Used by the import offer |
| `getPhotos(itemId)` `:378-400` | `SELECT * FROM item_photos WHERE item_id = ? ORDER BY created_at ASC` | → `ItemPhoto[]`. No phone UI caller today (only part of the repository surface the HTTP implementation mirrors). |

#### 7.3.3 `create(draft)` (`:225-287`)

`ItemDraft` (`:93-115`): `containerId`, `name?`, `category?`, `quantity?`, `notes?`, `tags?`, `photo? {id?, uri, thumbUri?, width?, height?, byteSize?} | null`.

1. `now = Date.now()`; `quantity = requireQuantity(draft.quantity ?? 1)`.
2. `name = draft.name === undefined ? '' : draft.name.trim()`. If the name was provided but is blank, throw `'Item name is required.'`. **An omitted name is allowed and stored as `''`**: fast capture writes the row before recognition (`:95-100`).
3. `category = draft.category?.trim() || null`; `notes = draft.notes?.trim() || null`.
4. **Transaction:**
   - `INSERT INTO items (id, container_id, name, category, quantity, notes, created_at, updated_at, search_text) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
   - if `draft.photo`: `INSERT INTO item_photos (id, item_id, uri, thumb_uri, width, height, byte_size, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)` with `photo.id ?? newId()` and `created_at = now`. `remote_synced_at` is left NULL.
   - if `draft.tags` is non-empty: `replaceTags`.
5. Returns `Item` (not `ItemWithContext`), with `createdAt = updatedAt = now`.

An unknown `containerId` causes an FK failure and the whole transaction rolls back (test `persistence.test.ts:465`). Test `:396` covers the related case: an outer transaction that contains a successful `create` followed by a CHECK-violating raw insert leaves 0 items (it needs the nesting design in §7).

Validation order: `requireQuantity` runs **before** the name check (`:227` then `:229-230`), so `{name: '  ', quantity: -1}` throws the quantity error. The same order applies in `update` (`:293` then `:295-300`).

#### 7.3.4 `update(id, input)` (`:289-376`)

`UpdateItemInput` (`:117-124`) contains every draft field as optional, plus `containerId?` and `expectedUpdatedAt?`.

1. `existing = SELECT * FROM items WHERE id = ?`, run **outside** the transaction. Missing → return `nil`.
2. `quantity = requireQuantity(input.quantity ?? existing.quantity)`.
3. `name`: `undefined` → existing (**which may be `''`**); otherwise trimmed, and a blank provided name throws `'Item name is required.'` (`:295-300`).
4. `category`/`notes`: `undefined` → existing; `null` or blank → `NULL`; otherwise trimmed. `containerId = input.containerId ?? existing`.
5. `updatedAt = Date.now()`.
6. **Transaction:**
   - `UPDATE items SET container_id = ?, name = ?, category = ?, quantity = ?, notes = ?, updated_at = ?, search_text = ? WHERE id = ?`, plus ` AND updated_at = ?` when `expectedUpdatedAt` is set.
   - If `changes == 0`: read `SELECT updated_at FROM items WHERE id = ?`. If `expectedUpdatedAt` was set **and** the row exists → **throw `ConflictError(current.updated_at)`** (rollback; nothing is written). Otherwise the row vanished → return `nil`.
   - `input.tags !== undefined` → `replaceTags(id, tags)`. `[]` clears all links.
   - `input.photo !== undefined` → `DELETE FROM item_photos WHERE item_id = ?`. The trigger tombstones synced photos. Then, if the photo is non-null, insert a new row with **`newId()`** (any `photo.id` is ignored on update) and `created_at = Date.now()` (a second clock read). **The old photo's file URIs are not returned**; the caller has to clean them up (§15).
7. Returns the merged `Item`, not re-read: `id` and `createdAt` unchanged, the new `updatedAt`.

No drop-zone guard: items can move freely into and out of `'drop-zone'`.

#### 7.3.5 `delete(id)` (`:403-424`)

Transaction: `SELECT uri, thumb_uri FROM item_photos WHERE item_id = ?`, then `DELETE FROM items WHERE id = ?`. Returns `{deleted: changes > 0, orphanedPhotoUris}`. NULL thumbnails are dropped. The cascade removes photos and tag links; `tags` rows stay.

### 7.4 QR (`src/repositories/qr.ts`)

- `QR_URI_PREFIX = 'inventory://c/'` (`:29`). `formatQrPayload(t)` = prefix + t (`:31-33`).
- `parseQrPayload(raw)` (`:41-46`): `v = raw.trim()`. If `v` starts with the prefix (case-sensitive), strip it. The rest must match `/^[0-9a-f]{32}$/i`, and is returned lowercased; anything else → `nil`.
- `ScanOutcome` (`:48-51`): `.bound(container, token)`, `.unknown(token)` or `.invalid(raw)`.

| Function | Behaviour |
|---|---|
| `resolveScan(raw)` `:56-90` | Parse; invalid → `.invalid(raw)`. Otherwise `SELECT c.* FROM containers c JOIN qr_bindings q ON q.container_id = c.id WHERE q.token = ?`; no row → `.unknown(token)`; row → `.bound`. |
| `getByContainer(cid)` `:92-98` | `SELECT * FROM qr_bindings WHERE container_id = ? ORDER BY created_at DESC LIMIT 1` |
| `getByToken(token)` `:100-106` | `SELECT * FROM qr_bindings WHERE token = ?`. Exact match, not lowercased. No UI caller. |
| `bind(token, cid)` `:117-140` | `cid == 'drop-zone'` → throw `'system_record'`. `now`, `newId()`. **Transaction:** `DELETE FROM qr_bindings WHERE token = ?`; `DELETE FROM qr_bindings WHERE container_id = ?`; `INSERT INTO qr_bindings (id, token, container_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?)`. Invariant: one token ↔ one container. The token format is not validated here, and neither is the container: an unknown `containerId` fails the INSERT with an FK error, the transaction rolls back, and the two DELETEs are undone (the old bindings survive). Returns the new `QrBinding`. |
| `createAndBind(cid)` `:143-145` | `bind(newQrToken(), cid)` |
| `unbind(cid)` `:148-153` | `DELETE FROM qr_bindings WHERE container_id = ?` → `changes > 0`. No drop-zone guard. |

### 7.5 Search (`src/repositories/search.ts`)

Constants: `ITEM_RESULT_LIMIT = 200`, `LOCATION_RESULT_LIMIT = 30` (`:33-34`).

`sqlCompact(expr)` (`:40-46`) wraps `expr` in nested `REPLACE` calls that remove **only** `-`, `_`, `/`, `.` and `'`, in that order. It does not remove spaces or other characters:

```
REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(<expr>, '-', ''), '_', ''), '/', ''), '.', ''), '''', '')
```

For each term `t` (from `tokenizeQuery`):
- `like = toLikePattern(t)`
- `compactLike = toLikePattern(compactAlphanumeric(t) || t)`

**Item-field condition** (`:52-66`), 4 parameters: `like, compactLike, like, compactLike`.

```sql
(
    i.search_text LIKE ? ESCAPE '\'
    OR <compact(i.search_text)> LIKE ? ESCAPE '\'
    OR EXISTS (
      SELECT 1 FROM item_tags it
        JOIN tags t ON t.id = it.tag_id
       WHERE it.item_id = i.id
         AND (
           t.normalized_name LIKE ? ESCAPE '\'
           OR <compact(t.normalized_name)> LIKE ? ESCAPE '\'
         )
    )
  )
```

**Location condition** (`:68-76`), 5 parameters: `like, compactLike, like, compactLike, compactLike`.

```sql
(
    LOWER(s.name) LIKE ? ESCAPE '\'
    OR <compact(LOWER(s.name))> LIKE ? ESCAPE '\'
    OR LOWER(COALESCE(c.name, '')) LIKE ? ESCAPE '\'
    OR <compact(LOWER(COALESCE(c.name, '')))> LIKE ? ESCAPE '\'
    OR <compact(LOWER(c.short_code))> LIKE ? ESCAPE '\'
  )
```

**`search(rawQuery)`** (`:87-155`):
1. `terms = tokenizeQuery(rawQuery)`. If empty → `{terms: [], locations: [], items: []}`.
2. Item query: the `ITEM_CONTEXT_SELECT` columns plus `CASE WHEN <itemCond(t1)> AND … AND <itemCond(tn)> THEN 1 ELSE 0 END AS direct_match`, `FROM items i JOIN containers c … JOIN spaces s …`, `WHERE (<itemCond(t1)> OR <locCond(t1)>) AND … AND (<itemCond(tn)> OR <locCond(tn)>)`, `ORDER BY direct_match DESC, i.name COLLATE NOCASE ASC LIMIT 200`.
   - **Parameter order:** first all the `direct_match` parameters (4 per term, in term order), then all the WHERE parameters (9 per term: `like, compactLike, like, compactLike, like, compactLike, like, compactLike, compactLike`). The SELECT clause comes before WHERE in the SQL text.
   - A full 1-term expansion for `USB-C` is captured below.
3. `searchSpaces(terms)` and `searchContainers(terms)` run concurrently (`Promise.all`, `:145-148`). Ordering of the two does not matter.
4. `locations = (spaces + containers).prefix(30)`. Spaces come first.
5. `matchKind = direct_match == 1 ? 'direct' : 'location'`.

Semantics: **AND across terms; each term may match the item's own fields or its location.** Items whose own fields match every term rank first. Within each group, results sort by name (ASCII-NOCASE). Items with equal names come back in an unspecified order (whatever the query plan produces); do not add a tiebreaker if you want parity with the home server.

**The item query does NOT filter on `kind`.** Drop-zone items are found through their location: the terms `drop`, `zone` and `dropzone` all return them with `matchKind = 'location'` (verified). Quantity-0 items are included.

**`searchSpaces(terms)`** (`:157-197`):

```sql
SELECT s.id, s.name,
       (SELECT COUNT(*) FROM containers c WHERE c.space_id = s.id) AS container_count,
       (SELECT COUNT(*) FROM items i JOIN containers c ON c.id = i.container_id
         WHERE c.space_id = s.id) AS item_count
  FROM spaces s
 WHERE s.kind = 'normal' AND (LOWER(s.name) LIKE ? ESCAPE '\' OR <compact(LOWER(s.name))> LIKE ? ESCAPE '\') [AND … per term]
 ORDER BY s.name COLLATE NOCASE ASC
 LIMIT 30
```

Parameters per term: `like, compactLike`. Result mapping: `kind 'space'`, `title = name`, `spaceId = id`, `itemCount`. The subtitle is **hard-coded English in the repository**: `"\(cc) container\(cc == 1 ? "" : "s") · \(ic) item\(ic == 1 ? "" : "s")"`. The separator is U+00B7 with a space on each side (`:191-193`).

**`searchContainers(terms)`** (`:199-243`):

```sql
SELECT c.id, c.name, c.short_code, c.space_id, s.name AS space_name,
       (SELECT COUNT(*) FROM items i WHERE i.container_id = c.id) AS item_count
  FROM containers c
  JOIN spaces s ON s.id = c.space_id
 WHERE c.kind = 'normal' AND (LOWER(COALESCE(c.name, '')) LIKE ? ESCAPE '\'
   OR <compact(LOWER(COALESCE(c.name, '')))> LIKE ? ESCAPE '\'
   OR <compact(LOWER(c.short_code))> LIKE ? ESCAPE '\') [AND … per term]
 ORDER BY s.name COLLATE NOCASE ASC, c.short_code ASC
 LIMIT 30
```

Parameters per term: `like, compactLike, compactLike`. Mapping: `kind 'container'`, `title = name ?? short_code`, `subtitle = "\(spaceName) · \(shortCode) · \(n) item\(n == 1 ? "" : "s")"`, `spaceId`, `itemCount`. `short_code ASC` uses BINARY collation.

**`formatLocationPath(item)`** (`:293-298`): if `containerId == 'drop-zone'` → `spaceName`, which is `"Drop zone"`. Otherwise `"\(spaceName) > \(containerName ?? containerShortCode)"`.

**Captured SQL for the query `USB-C`** (one term; parameters as listed):

```text
item query params: ["%usb-c%","%usbc%","%usb-c%","%usbc%",            <- direct_match (4)
                    "%usb-c%","%usbc%","%usb-c%","%usbc%",            <- itemCond in WHERE (4)
                    "%usb-c%","%usbc%","%usb-c%","%usbc%","%usbc%"]   <- locationCond in WHERE (5)
spaces params:     ["%usb-c%","%usbc%"]
containers params: ["%usb-c%","%usbc%","%usbc%"]
```

**Known search quirks (current behaviour; replicate unless the team decides otherwise, see Q1):**
- **Accent folding only applies to the query.** `search_text`, tag names and `LOWER(name)` in the DB are not accent-folded, so `café`, `Küche` and `ärmel` find **nothing** when the stored text has the accent (verified: an item `Café Mug` is not found by `café`, but is found by `caf`).
- SQLite `LOWER` and `LIKE` fold ASCII only. A space named `ÄRMEL` does not match `ärmel`.
- `sqlCompact` does not remove spaces, so the term `usbc` does not match a stored `usb c`. Typing `usb c` produces two terms, which both match.
- Splitting on combining marks breaks Japanese voiced kana and Indic scripts into fragments (§6.6).

Performance: 10,000 items, the query `widget 4242` in under 1 s (test `search.test.ts:190`). The search uses LIKE scans; `idx_items_search_text` does not help a `%…%` LIKE. The test exists to catch O(n²) regressions.

---

## 8. Pure UI-data helpers

### 8.1 Place matching (`src/ui/placeMatch.ts`)

- `PlaceOption` (`:6-16`): `id, name?, shortCode, visualType, spaceId, spaceName, spaceColor, spaceIcon, itemCount`.
- `compact = compactAlphanumeric` (`:31`).
- `placeTerms(q)` (`:34-39`): split on JS `\s+`, apply `compact` to each piece, drop empty results.
- `matchesPlace(opt, terms)` (`:48-56`): `[]` → true. Otherwise `haystack = compact("\(name ?? "") \(shortCode) \(spaceName) \(typeName)")`, where `typeName = strings.entities.typeNames[visualType] ?? ""`, and **every** term must be a substring of `haystack`.
- `toPlaceOption(container, space?)` (`:58-76`): a missing space gives `spaceColor = ""` and `spaceIcon = ""`.
- `joinPlaceOptions(containers, spaces)` (`:79-85`): map spaces by id, then `toPlaceOption` for each container.

### 8.2 Recent places (`src/services/places/recentPlaces.ts`, `src/hooks/useRecentPlaces.ts`)

- Storage key `places.recent.v1` (`:5`). The value is a JSON array of container id strings, most recent first. `MAX_RECENT_PLACES = 6` (`:8`).
- `mergeRecent(list, id, max = 6)` (`:16-23`): remove `id` and `'drop-zone'` from `list`; if `id` is the drop zone, return the rest; otherwise put `id` first. Cap at `max`.
- In-memory `cache: [String]?` plus listeners (`:27-34`). Every picker on screen sees the same list.
- `readRecentPlaces()` (`:40-54`): return the cache if present. Otherwise read storage and `JSON.parse` it; a non-array becomes `[]`; keep only strings; `slice(0, 6)`. There is **no dedupe** on read. **Publish only if nothing was remembered while the read was in flight.** Any error → publish `[]` (again only if the cache is still unset).
- `rememberPlace(cid)` (`:57-66`): drop zone → no-op. `next = mergeRecent(cache ?? await read(), cid)`, publish, then persist the JSON; persist errors are ignored.
- Callers: a successful Add (`app/item/new.tsx`), Move or File (`src/hooks/useMove.ts:134`), and binding a label (`app/c/[token].tsx`).
- `useRecentPlaces()` (`src/hooks/useRecentPlaces.ts:24-36`) returns the list **as it was the first time it became known while this screen was open**. Later `rememberPlace` calls do not reorder an open picker. The value is `null` (unknown) until storage has been read, and `[]` is returned meanwhile. Callers filter the ids against containers that still exist.
- **Native:** a `@MainActor @Observable RecentPlacesStore` backed by `UserDefaults`, plus a one-time import (§10.2). Pickers capture `store.list` when presented. The RN reason for the snapshot was an Android renderer crash (`useRecentPlaces.ts:16-19`), which does not apply on iOS. Keep the snapshot anyway, so the tapped row stays put while the sheet closes.

### 8.3 Category memory (`src/ui/categoryMemory.ts`)

- Storage key `categories.recent.v1` (`:3`): a JSON array of strings, most recent first. `MAX_SAVED = 20`, `MAX_SUGGESTIONS = 6` (`:4-5`).
- `key(c)` = `c.trim().toLowerCase()` (`:24-26`).
- State: `saved` (persisted, max 20), `seen` (a session map from key to the first spelling seen), and `snapshot` (`:17-22`).
- `publish()` (`:28-37`): ordered map → first `saved` in order, keyed; then the `seen` entries whose key is not in `saved`, **sorted with `localeCompare(b, 'en', {sensitivity: 'base'})`**. `snapshot` = the values. Swift: `a.compare(b, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")) == .orderedAscending`. Entries that compare equal at base strength (for example `Cafe` and `Café`, which have different keys) keep their `seen` insertion order, because JS `Array.prototype.sort` is stable. In Swift, sort `(offset, element)` pairs with the offset as tiebreaker, rather than relying on `sort(by:)` being stable.
- `loadSaved()` (`:45-61`) runs **once per process**; the `loading` flag is never reset, even on failure. It is triggered only by the mount effect of `useKnownCategories` (`:138`), that is, the first time a Category field with suggestions is shown (`src/ui/components/ItemForm.tsx:138`). It reads storage; a non-array → return without publishing. It keeps strings, then `saved = mergeSaved(saved_in_memory + restored)`, so categories recorded meanwhile stay in front, and publishes. The merged list is **not** persisted here. Errors are ignored.
- **RN race (do not port):** `recordCategory` persists the in-memory `saved` (`:95`). If it runs before `loadSaved` has finished, or before any Category field has mounted, it overwrites `categories.recent.v1` with a list that lacks the stored entries. They survive in memory only if the load later completes, and reach storage again only on the next `recordCategory`. Native: read `UserDefaults` synchronously when the store is created, so `saved` is always complete before any write.
- `mergeSaved(list)` (`:63-74`): dedupe by `key`, skipping empty keys, push the **trimmed** value, cap at 20.
- `rememberCategories(items)` (`:76-86`): for each item with a non-empty trimmed category whose key is unseen, add it to `seen`. Publish if anything changed. Called after every item list loads (Home recent, search results, container list, drop zone).
- `recordCategory(c)` (`:88-99`): trimmed; empty → return. `saved = mergeSaved([trimmed] + saved)`, publish, persist. Called after an item is saved with a category (`app/item/new.tsx:548`, `app/item/[id]/edit.tsx:198`).
- `suggestCategories(categories, prefix, max = 6)` (`:106-122`): `typed = key(prefix)`. For each category, take its key `k` and skip it if `k` is empty, equals `typed`, was already offered, or does not start with `typed`. Otherwise push the trimmed category. Stop at `max`. An empty prefix gives the first 6 known categories.
- `useKnownCategories()` / `useCategorySuggestions(prefix)` (`:132-145`) are the observable snapshot and the memoised suggestions.

---

## 9. State, invalidation and data hooks

### 9.1 Invalidation model (how the UI learns about changes)

There is no DB observation and no in-memory mirror. The database (or the household server) is the single source of truth (`src/providers/DatabaseProvider.tsx:91-98`).

- **Global revision.** `revision: Int` in its own context. `invalidate()` increments it (`DatabaseProvider.tsx:34,38,68`).
- **Who calls `invalidate()`:**
  - Every screen or hook after a successful write: `app/capture/index.tsx`, `app/capture/review.tsx`, `app/container/[id]/edit.tsx`, `app/container/[id]/link.tsx`, `app/container/[id]/qr.tsx`, `app/container/new.tsx`, `app/c/[token].tsx`, `app/household.tsx`, `app/item/[id]/edit.tsx`, `app/item/[id]/index.tsx`, `app/item/new.tsx`, `app/space/[id]/edit.tsx`, `app/space/new.tsx`, `src/hooks/useMove.ts`, `src/hooks/useSavedQuantity.ts`, `src/ui/item/NameItInline.tsx`, `src/ui/household/JoinForm.tsx`, `src/ui/components/ConnectionBanner.tsx`.
  - `ConnectionProvider`, **only while paired** (every trigger is gated on a household session, `src/providers/ConnectionProvider.tsx:82,151`):
    - on recovery: the first `ok` reachability report after any failure, including a blip that never reached `offline`. At most once every `RESUME_REFRESH_MS = 5000` (`:43,108-119`).
    - on app resume, when `AppState` becomes `active`, ≥ 5 s after the last time it counted. The effect also re-runs on every session-key change while active. Only the **first evaluation per process** that passes the guard (`lastResumeRef == 0`) records the time without invalidating; `lastResumeRef` is never reset on a session change (`:149-158`). In practice that first evaluation is the session load resolving at launch, or the first join of an app that started unpaired. Leaving and re-joining more than 5 s after the last evaluation **does** invalidate. Same rule as `09-app-shell-lifecycle-config.md` §4.3 and `04-household.md` §9.3.
    - on manual `retry()`: a health ping plus `invalidate()` (`:175-178`).
  - **Unpaired (local) mode has no resume refresh at all.** Nothing re-reads when the app returns to the foreground, because local data cannot have changed meanwhile.
  - `SyncProvider`, twice after a restore: once after the rows are restored, once after the photos (`src/providers/SyncProvider.tsx:198,203`).
  - The phone does **not** subscribe to the home server's `/v1/events` SSE stream. Changes made on other devices appear only on focus, resume or retry.
- **`useInventoryQuery(run, key)`** (`src/hooks/useInventoryQuery.ts:52-127`):
  - The query re-runs (a) on mount, (b) **every time the screen gains focus** (`useFocusEffect` bumps `localRevision`, `:109-113`), (c) when the global `revision` changes **while the screen is focused** (`:67-69`), and (d) on `reload()`.
  - A screen in the background notices a newer revision when it next gains focus, and re-reads then.
  - In-flight results are discarded when superseded: request token = FNV-1a of `key|revision|localRevision` (`:130-138`), plus a `cancelled` flag (`:82-106`).
  - **`data`** = the last settled data. On success it is replaced. **On failure it is kept only if the previous result had the same key; otherwise it becomes `nil`** (`:91-99`). Note: `data` is returned even while a new key loads, so the previous key's data can show for a moment (`:120-121`).
  - `loading` = the newest request has not settled (`:117,124`).
  - `cause` = the error, only when the newest request failed.
  - `refreshFailed` = failed && data != nil, which drives the "could not be refreshed" banner via `needsRefreshBanner` (`src/ui/errors.ts:90-94`, `strings.errors.refreshFailed`).
- **`run` is not a dependency.** The latest closure is read through a ref (`:77-80`), so changing the closure without changing `key` does **not** re-run the query. Every input of a query must be encoded in `key`. Screens that sometimes do not need a read use sentinel keys with a no-op `run`: `containers-none` (`app/(tabs)/index.tsx:158`), `drop-zone:unused` (`app/item/[id]/index.tsx:100`) and `space:none` (`` `space:${spaceId ?? 'none'}` `` whose `run` resolves `null`, `app/container/[id]/index.tsx:180-183`).
- **Query keys in use** (so screens share invalidation semantics): `spaces`, `space:<id>`, `containers-of:<spaceId>`, `container:<id>`, `items-of:<containerId>`, `qr-of:<containerId>`, `item:<id>`, `recent:<limit>`, `containers-all`, `drop-zone`, `fast-review:<containerId>:<since>`, `devices:<deviceId>`, plus the sentinels above.
- **Mount reads twice in RN:** the effect runs once on mount with `localRevision = 0`, then `useFocusEffect` bumps it to 1 and supersedes the first read (`:82-113`). This is an artifact; one read on appear is enough natively.
- **`DropZoneProvider`** (`src/providers/DropZoneProvider.tsx:31-52`) runs one shared `listUnsorted()` query (key `drop-zone`) in the tabs layout and feeds the tab badge, Home's card and the Drop zone list. It exposes `items` (`[]` until loaded), `count = items.count`, `loading = loading && data == nil` (badges stay hidden rather than showing 0), `reading = loading` (pull-to-refresh spinner), `cause`, `refreshFailed` and `reload`.

**Native design:**

```swift
@MainActor @Observable final class DataRevision { private(set) var value = 0; func invalidate() { value &+= 1 } }

@MainActor @Observable final class InventoryQuery<T: Sendable> {
  // state: data: T?, loading: Bool, cause: Error?, refreshFailed: Bool, key: String
  // run when the screen gains focus, on revision change while focused, on reload()
  // cancel the previous Task on re-run; ignore results from superseded runs (token check)
  // on failure: keep data only if lastKey == key
}
```

Drive it from `.task(id: RunID(key, revisionSeenWhileFocused, localNonce))`. **Focus is not app foregrounding:** `scenePhase` becoming `.active` is *not* a re-read trigger in RN. App resume reaches screens only through the paired-mode `invalidate()` in `ConnectionProvider` (above). Port that as a `scenePhase` observer that calls `invalidate()` under the same gating, never as a per-query trigger.

**What "focused" means:** RN `useIsFocused` is true only for the topmost screen of the active navigator chain. A screen under a pushed screen, in an unselected tab, or under a modal or form sheet presented from the same stack is **unfocused**, and it re-reads when it is uncovered. SwiftUI does not reproduce this with `onAppear`/`onDisappear`: a view that presents a `.sheet` or `.fullScreenCover` gets neither callback when the sheet appears or is dismissed. Model focus explicitly. A screen is focused when it is the top of its `NavigationStack`, its tab is selected and it presents no sheet. Count the transition from covered to uncovered as gaining focus (bump `localNonce`). Otherwise two behaviours drift. Revisions that arrive while a sheet is up would re-read the screen underneath immediately, which means extra HTTP reads when paired. And dismissing a sheet that wrote nothing would not refresh the screen underneath.

**Do not** switch to GRDB `ValueObservation` as the primary mechanism: in paired mode reads are HTTP. `ValueObservation` could be added later for unpaired mode, but parity needs the explicit model.

### 9.2 `useSearch(query)` (`src/hooks/useSearch.ts`)

State: `settled = {query, run, results, cause}`, initially `{'', '', nil, nil}` (`:31-39`).

- `trimmed = query.trim()`.
- `run = "\(seenRevision)|\(nonce)"`. `seenRevision` follows the global revision only while Home is focused. `nonce` increments on every focus and on `retry()` (`:63-72,127-133`).
- Effect on `(trimmed, run)` (`:84-125`):
  - If `trimmed` is empty: reset `loggedQuery` and do nothing. **Results stay as they were**; the caller decides what to show.
  - Debounce: `wait = (trimmed == settled.query) ? 0 : 200 ms` (`delay.searchDebounce`, `src/ui/motion.ts:31`). A new query waits for a 200 ms pause; re-running the same query starts at once.
  - On success: `settled = {trimmed, run, found, nil}`, then `rememberCategories(found.items)`. If `loggedQuery != trimmed`, log `search_performed {termCount: found.terms.count, resultCount: items.count + locations.count, queryLength: trimmed.count}` and set `loggedQuery = trimmed`. That is once per distinct query until the field is cleared. **The query text is never logged.**
  - On failure: `settled = {trimmed, run, previous.query == trimmed ? previous.results : nil, cause}`.
  - Cancellation: the timer is cleared and the result ignored when inputs change.
- Derived values (`:135-144`):
  - `current = trimmed != '' && settled.query == trimmed`
  - `answered = current && settled.run == run`
  - returns `settledQuery`, `results`, `cause = answered ? settled.cause : nil`, `pending = trimmed != '' && !current`, `refreshing = current && !answered`, and `retry`.
- `queryLength` is JS `.length`, which counts UTF-16 code units. Use `trimmed.utf16.count` for parity.
- Native: an `@Observable SearchModel` with `Task.sleep(for: .milliseconds(200))` debounce and cancellation; the same derived flags.

### 9.3 `useSavedQuantity(item, {onError})` (`src/hooks/useSavedQuantity.ts`)

A coalescing writer: the number on screen changes immediately, and taps are collapsed into the fewest writes.

- `MAX_CONFLICT_RETRIES = 3` (`:11`).
- Error kinds: `offline | gone | other`. Messages: `strings.quantity.notSavedOffline`, `strings.quantity.gone` and `strings.quantity.notSaved` (`:13-20`).
- State: displayed `quantity`, `errorKind`.
- Refs: `confirmed {quantity, updatedAt}`, `pending: Int?`, `inFlight: Bool`, `retries: Int`.
- **Identity change** (a different `item.id`): reset the display to `item.quantity` and clear the error (`:55-59`); reset `pending = nil`, `inFlight = false`, `retries = 0`, `confirmed = item` (`:61-67`).
- **Prop refresh** (same id; `quantity` or `updatedAt` changed): only if `pending == nil && !inFlight`, set `confirmed = props` and display = `props.quantity` (`:69-73`).
- `setQuantity(next)` (`:146-155`): `clamped = clampQuantity(next)`; display = clamped; clear the error; `pending = clamped`; `flush()`.
- `flush()` (`:80-144`):

```text
if inFlight return; inFlight = true
loop while pending != nil && pending != confirmed.quantity:
  target = pending
  try:
    updated = items.update(id, {quantity: target, expectedUpdatedAt: confirmed.updatedAt})
    if updated == nil:                 # deleted elsewhere
      pending = nil; display = confirmed.quantity; fail(.gone); invalidate(); break
    confirmed = (updated.quantity, updated.updatedAt); retries = 0
    log "item_updated"; if pending == target { pending = nil }; invalidate()
  catch ConflictError where retries < 3:
    retries += 1
    try fresh = items.getById(id)
      if fresh == nil: pending = nil; display = confirmed.quantity; fail(.gone); invalidate(); break
      confirmed = (fresh.quantity, fresh.updatedAt); continue      # loop re-checks pending vs fresh
    catch: pending = nil; display = confirmed.quantity; fail(.other); break
  catch other (or 4th conflict):
    pending = nil; retries = 0; display = confirmed.quantity
    kind = describeError(cause, 'quantity', 'item').kind
    fail(kind == offline ? .offline : kind == gone ? .gone : .other)
    if kind == gone { invalidate() }
    haptics.error(); break
after loop: if pending == confirmed.quantity { pending = nil }
finally inFlight = false
```

- `fail(kind)` sets `errorKind` and calls `onError(kind)`, so a compact stepper can show a toast instead (`:75-78`).
- Haptic: `error` only on the generic failure path.
- Quirk to keep or decide: on the `gone` and `other` exits inside the conflict branch, `retries` is **not** reset.
- **Identity change while a flush is in flight (RN hazard, do not port):** the reset effect sets `pending = nil` and `inFlight = false` for the new item (`:61-67`). The old item's `flush` closure keeps running on the shared refs, though, and its later `setQuantityState(confirmed…)` calls can overwrite the new item's display. Native: give each `QuantityModel` exactly one item id, recreate it on identity change, and cancel or ignore the old model's task.
- All writes are `items.update(id, {quantity, expectedUpdatedAt})`. The model never sends other fields, so the server or repository keeps name, tags and photo.
- Returns `{quantity, setQuantity, error: message?, errorKind}`.
- Native: a `@MainActor @Observable QuantityModel` per row or item. `setQuantity` calls from the main actor while a flush is running just update `pending`, and the running loop picks them up.

### 9.4 Move and File (`src/hooks/useMove.ts`, `src/ui/item/moveFlow.ts`)

**Pure conflict rules (`moveFlow.ts`):**

- `attemptMove(items, before{id, containerId, updatedAt}, target)` (`:50-77`):
  1. `update(before.id, {containerId: target, expectedUpdatedAt: before.updatedAt})`: a result → `.moved(updatedAt)`; `nil` → `.gone`; a non-conflict error → `.failed(cause)` (no retry).
  2. On `ConflictError`: `fresh = getById(id)`. `nil` → `.gone`. If `fresh.containerId != before.containerId` → `.movedElsewhere(fresh)`, with no write. Otherwise retry **once** with `expectedUpdatedAt: fresh.updatedAt`: a result → `.moved`, `nil` → `.gone`, any error (including a second conflict) → `.failed(cause)`.
- `attemptUndo(items, move{itemId, from, updatedAt})` (`:91-104`): `update(itemId, {containerId: from, expectedUpdatedAt: move.updatedAt})`. A result → `.undone`; `nil` → `.gone`; `ConflictError` → `.conflict` (a later change elsewhere wins over Undo); other → `.failed(cause)`.
- `undoFailedMessage` (`:107-113`): gone → `strings.move.undoGone`; conflict → `strings.move.undoConflict`; failed and offline → `strings.move.undoFailed`; otherwise `strings.move.undoFailedOther`.
- `containerLabel(p)` = `name ?? shortCode` (`:116-118`).
- `movedMessage({fromDropZone, filing, moreWaiting, container, space})` (`:130-147`): not from the drop zone → `strings.move.movedTo`. From the drop zone, `filing && moreWaiting == false` → `strings.move.filedLast`; otherwise `strings.move.filedIn`.
- `afterFiling(items, itemId)` (`:156-166`): `waiting = listUnsorted().map(\.id)` → `{waiting, moreWaiting: waiting.contains { $0 != itemId }}`. On a read error → `{moreWaiting: nil}`.
- `movedElsewhereMessage(fresh)` (`:169-176`): the drop zone → `strings.move.alreadyMovedToDropZone`; otherwise `strings.move.alreadyMoved(containerName ?? containerShortCode)`.
- `moveFailedMessage(cause)` (`:179-183`): offline → `strings.move.failed`; otherwise `strings.move.failedOther`.
- `nextInRun(before, currentId, waiting)` (`:194-209`): `left = Set(waiting - currentId)`; empty → `nil`. Start at `before.indexOf(currentId) + 1`, which is 0 when the item was not in the list, and walk `before` circularly, returning the first id in `left`. Otherwise return the first id in `waiting` that is in `left`.

**Hook (`useMove({item, request, filing})`):**

- `current = newer(item, reread)`. With the same id, the one with the greater `updatedAt` wins, and ties go to the prop item. With a different id or a `nil`, it is `a ?? b` (`:55-58,83`).
- On unmount: `abandonResult(request)`, which answers the opener with nothing (`:87`).
- `pick(place)` (`:111-184`):
  - Ignore the pick unless `place.kind == 'container'`, `current` is set and not busy (`busyRef`, `:113`). Picking the current container is a no-op (`:116`).
  - Set busy and `busyId = target.id`, clear the notice, then `attemptMove`.
  - **moved:**
    - Build `MoveResult {itemId, from, to, updatedAt}`, log `item_moved`, `haptics.success()`, `rememberPlace(target.id)`.
    - If `filing && fromDropZone`: run `afterFiling`, then set `move.waiting` and `moreWaiting`.
    - `deliverResult(request, move)`.
    - If the sheet is still focused, `router.back()`.
    - `invalidate()`.
    - Show a toast with `movedMessage(...)` and an Undo action: label `strings.common.undo`, accessibility label `strings.move.undoA11y(name)` or `strings.move.undoA11yUnnamed`.
    - `busyRef` stays set; the sheet is closing.
  - **not moved:** clear busy; **no invalidate**. Then:
    - `gone` → notice `strings.move.gone`, `haptics.error`;
    - `movedElsewhere` → `reread = fresh`, notice `movedElsewhereMessage(fresh)`, `haptics.warning`;
    - `failed` → `logError('item_move_failed', {errorClass})`, notice `moveFailedMessage(cause)`, `haptics.error`.
- `undo(move)` (`:89-109`):
  - `undone` → log `item_move_undone`, `invalidate()`, `haptics.undo()`, toast `strings.move.undone`.
  - Otherwise → `haptics.warning` for a conflict and `haptics.error` for anything else, `logError('item_move_undo_failed', {outcome, errorClass?})`, an error toast with `undoFailedMessage`, then `invalidate()`.
- The drop zone is never offered as a move target (`:112`).

---

## 10. Existing on-device data to adopt on first native launch

### 10.1 SQLite

Open `Documents/SQLite/inventory.db` in place (§2.1), then run `migrate()`. Any `user_version` from 0 to 7 is handled (§3). Nothing else needs converting.

### 10.2 AsyncStorage values in this area

RN uses the **legacy** AsyncStorage backend: the v3 default export is `getLegacyStorage()` (`node_modules/@react-native-async-storage/async-storage/src/index.tsx`), which is backed by `RNCAsyncStorage`.

- Manifest: `Library/Application Support/com.wystudio.inventory/RCTAsyncLocalStorage_V1/manifest.json` (`apple/legacy_storage/RNCAsyncStorage.mm:17-20,129-150,538`). It is a JSON object `{key: string | null}`.
- Values up to 1024 UTF-16 units are stored inline. Longer values are stored as `null` in the manifest, and the data lives in a sibling file named by the lowercase hex MD5 of the UTF-8 key (`RNCAsyncStorage.mm:21,507-511,633-650`; `RCTUtils.mm:256-282`).
- Older installs may still have the directory under `Documents/RCTAsyncLocalStorage_V1` (the library migrates it at startup). Check both locations.
- The directory is excluded from iCloud backup by default (`RNCAsyncStorage.mm:530-535`).

| Key | Shape | MD5 file name (if not inline) | Native destination |
|---|---|---|---|
| `places.recent.v1` | JSON `string[]` (container ids, ≤ 6) | `29ce820024d261826454db01a9ea7e83` | `UserDefaults` same key |
| `categories.recent.v1` | JSON `string[]` (≤ 20) | `9355fb19fd0f6f39f84680882e0638d7` | `UserDefaults` same key |

**Owner of the import: `02-device-storage-migration.md` §5.4** (`LegacyAsyncStorageReader` + `LegacyImport`, marker `native.legacyImport.v1` as an Int). It copies all seven known keys, including these two, **verbatim as raw strings** into `UserDefaults` under the same key names; it does not parse them. The tolerant parsing above (non-arrays → `[]`, keep only strings, cap) therefore runs **on read** in the `RecentPlacesStore` / category store, exactly as RN parses on read. Do not write a second importer or a second marker for this area.

---

## 11. RN/Expo workarounds not needed natively, and native replacements

| RN/Expo construct | Why it exists | Native replacement |
|---|---|---|
| `SqlDatabase` interface plus a Node adapter (`src/db/types.ts:9-29`, `src/db/nodeDatabase.ts`) | Run repositories under Jest and the home server | GRDB `DatabaseWriter`. Tests use an in-memory `DatabaseQueue()`. |
| SAVEPOINT emulation of nested transactions (`nodeDatabase.ts:78-95`) | Node test and home-server parity. The adapter's comment claims expo "flattens" nested calls, but expo's `withTransactionAsync` is plain `BEGIN`/`COMMIT` (`node_modules/expo-sqlite/src/SQLiteDatabase.ts:140-149`), so a nested call on the phone would fail with "cannot start a transaction within a transaction". No production code nests (the home-server importer opens one transaction around raw `runAsync` calls, `home-server/src/importer.ts:16-45`). Only test `persistence.test.ts:396` nests. | Repository cores take a `Database` and use `inSavepoint` (§7 composition note) |
| expo `withTransactionAsync` is not isolated: other async queries can interleave into an open transaction (`expo-sqlite/src/SQLiteDatabase.ts:123-136`) | expo API limitation | GRDB `write {}` serialises. Run each repository mutation as one `write` closure. |
| `configureRandomBytes` injection (`src/core/id.ts:10-33`) | Same code on Node and Expo | `SecRandomCopyBytes`, behind a protocol for tests |
| `asBufferSource` cast (`src/core/bytes.ts:29-31`) | TypeScript typing | Not needed |
| `VACUUM INTO` snapshot in the Node adapter | Node 22 lacks `serialize()` | `sqlite3_serialize` or `VACUUM INTO`, either is fine |
| FNV token, `runRef`/`latest` refs, derived-state tricks in `useInventoryQuery`/`useSearch` | React render model and hooks lint rules | `@Observable` models, `.task(id:)`, `Task` cancellation |
| `useFocusEffect` re-reads | expo-router focus | An explicit focus model: top of the stack, tab selected, no sheet presented. `onAppear` alone misses sheet dismissal (§9.1). Use `scenePhase` only for the paired-mode resume `invalidate()`. |
| `useRecentPlaces` "held" list (Android `addViewAt` crash) | Android renderer | Capture at sheet presentation (UX only) |
| Lazy `import()` of AsyncStorage in `categoryMemory` (`:41-43`) | Avoid touching the native module at import | `UserDefaults` |
| `busyRef` double-submit guard (`useMove.ts:80-81`) | State updates are async in React | `@MainActor` model flag (still needed, because `pick` awaits) |
| `navigation.isFocused()` before `router.back()` (`useMove.ts:149`) | The header Cancel may have closed the sheet already | `dismiss()` only if still presented |
| GROUP_CONCAT with U+001F for tags | One round trip, comma-safe | Keep, for SQL parity and tag order |
| Nested-REPLACE `sqlCompact` "portable across expo-sqlite and node:sqlite" (`search.ts:36-46`) | No custom SQL functions in JS | Keep as SQL. A custom GRDB function would drift from the home server, which runs the TS search. |

Native APIs to use:
- `Date.now()` → `Int64(Date().timeIntervalSince1970 * 1000)`, floored.
- `String.prototype.trim()` → write a `jsTrim()` helper that strips the JS WhiteSpace and LineTerminator set: U+0009–000D, U+0020, U+00A0, U+1680, U+2000–200A, U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF. Foundation's `.whitespacesAndNewlines` differs: it excludes U+FEFF and includes U+0085. Use `jsTrim()` everywhere the TS code trims: names, categories, notes, tags, the search query, QR payloads.
- JS `\s` (used by `placeTerms` and `normalizeShortCode`) is the same set as `jsTrim()`.
- `localeCompare(…, 'en', {sensitivity:'base'})` → `compare(_:options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en"))`.

---

## 12. Behaviours to preserve (easy to "fix" by accident)

1. An omitted item name is stored as `''`; a provided blank name throws (`items.ts:229-230,295-300`).
2. `spaces.update` saves `''` for a provided blank name; `spaces.create` does not validate (`spaces.ts:93,117`).
3. `containers.create` reports an FK failure as "Could not allocate a unique container code…" after 10 attempts (`containers.ts:143-150`). See Q5.
4. `items.update({photo})` always assigns a new photo id and does not return the old file URIs (`items.ts:353-371`).
5. Tag display spelling = the first spelling ever saved. The tag order is by tag id (§7).
6. Search includes drop-zone items (as location matches); location lists exclude the drop zone (§7.5).
7. Search accent folding is one-sided (§7.5). See Q1.
8. Search subtitles are hard-coded English in the repository, not in `strings.ts` (`search.ts:191-193,236-238`). See Q2.
9. `listRecent` includes drop-zone items (`items.ts:194-201`).
10. Quantity: the DB accepts 0 and above with no upper bound. Only the stepper and `useSavedQuantity` clamp to 9999; the item form does not (§4.4, §6.4).
11. `migrate()` silently accepts `user_version > 7` (§3.1).
12. The drop-zone rows are protected only by the id checks in `spaces.update/delete`, `containers.update/delete` and `qr.bind`. There is no DB constraint.

---

## 13. Test inventory (port to Swift Testing)

Format: `path:line` › test name → what it asserts. Unless noted, tests use a fresh in-memory DB migrated to v7.

### 13.1 `src/core/__tests__/id.test.ts`
- `:10` newId › throws until an RNG is configured → `/not configured/`. Native: only if keeping injection.
- `:15` newId › formats RFC 4122 v4 from injected bytes → bytes 0…15 ⇒ `00010203-0405-4607-8809-0a0b0c0d0e0f`.
- `:26` newQrToken › hex-encodes the injected 16 bytes → 16×`0xab` ⇒ `"ab"`×16.

### 13.2 `src/core/__tests__/quantity.test.ts`
- `:10` clamp keeps a whole number in range → 0, 8, 9999 unchanged.
- `:16` clamp rejects fractions and NaN → 1.5 → 0; NaN → 0.
- `:21` clamp stops below zero and above the cap → −1 → 0; 10000 → 9999.
- `:28` parseQuantityInput rejects `''`, `'   '`, `'abc'`, `'1.5'`, `'-1'` → nil.
- `:32` accepts zero and trims → `'0'` → 0; `' 12 '` → 12.
- `:38` stepQuantity → 3+1=4, 3−1=2, 0−1=0, 9999+1=9999.

### 13.3 `src/core/__tests__/tokenize.test.ts`
- `:10` lowercases and splits on whitespace → `Cordless Drill` ⇒ `[cordless, drill]`.
- `:14` empty or whitespace-only → `''`, `'   '`, `'!!! ??? ...'` ⇒ `[]`.
- `:20` dedupes → `drill drill DRILL` ⇒ `[drill]`.
- `:24` keeps inner dashes, trims outer → `BOX-7K2M` ⇒ `[box-7k2m]`; `-drill-` ⇒ `[drill]`.
- `:29` splits on non-dash punctuation → `screws, nails; bolts` ⇒ 3 terms.
- `:33` strips accents → `Café` ⇒ `[cafe]`.
- `:37` keeps digits and non-Latin scripts → `18v battery` ⇒ `[18v, battery]`; `ワイヤー` ⇒ `[ワイヤー]`.
- `:42` caps terms → 40 distinct ⇒ 12.
- `:49` toLikePattern wraps → `%drill%`.
- `:53` escapes → `50%` ⇒ `%50\%%`; `a_b` ⇒ `%a\_b%`.
- `:60` short codes use the unambiguous alphabet → 200× `^BOX-[2-9A-HJ-NP-Z]{4}$`, no O/I/0/1.
- `:69` normalizeShortCode / normalizeForCodeMatch → `box-7k2m` ⇒ `BOX7K2M`; `BOX-7K2M` ⇒ `box7k2m`.
- `:76` compactAlphanumeric → `USB-C`, `usb c`, `usb/c`, `usbc` ⇒ `usbc`.

### 13.4 `src/db/__tests__/persistence.test.ts`
**migrations**
- `:22` new DB migrates to `LATEST_SCHEMA_VERSION`.
- `:28` idempotent: a second run returns 7.
- `:34` stop at v1, insert a legacy item, migrate → v7 and `search_text == 'legacy drill'` (v2 backfill).
- `:60` from v1 with `estimated_value`/`currency` → after migrating, neither column is in `PRAGMA table_info(items)` and the row survives.
- `:91` stop at v6, create an item with a tag and photo; `update(quantity: 0)` **rejects** (old CHECK); migrate → v7; `PRAGMA foreign_keys == 1`; `sqlite_master.sql` matches `CHECK (quantity >= 0)`; `update(quantity: 0)` now succeeds; photo URI, tags and container are preserved; `PRAGMA foreign_key_check` is empty.
- `:133` `version == index + 1` for every migration.

**spaces**
- `:141` create trims `'  Attic  '` → `Attic`; update keeps `id` and `createdAt`; the update is read back.
- `:157` `listWithCounts` → 1 container, 2 items.
- `:170` `deletionImpact` → `{1, 1, 1, 1}` (container, item, photo, QR).
- `:190` delete cascades: `deleted`; `orphanedPhotoUris == ['file:///photos/drill.jpg']`; `containers` count = **1** (the drop zone survives); items, photos and QR bindings = 0.

**drop zone**
- `:214` an item in the drop zone: `countUnsorted == 1`, `listUnsorted` names it, and `listWithCounts` excludes `drop-zone-space`.
- `:229` moving to a real container empties the drop zone; `listByContainer` contains the item.
- `:245` an unnamed capture (`create {containerId: drop-zone}` with no name) can be moved without a name.
- `:257` `update(name: '  ')` rejects with `/name is required/`.
- `:265` survives deleting every user space (`countUnsorted` is still 1).

**containers**
- `:277` short codes match `^BOX-[A-Z0-9]{4}$` / `^DRW-…`, distinct.
- `:289` a blank name is stored as null.
- `:302` an unknown space rejects.
- `:310` `update(spaceId)` moves the container; the target `listBySpace` has 1.
- `:322` `getWithCounts.itemCount` follows create and delete (1 → 0).

**items**
- `:335` create with photo and tags: name, quantity, photoUri, `photoId` matches `^[0-9a-f-]{36}$`, tags dedupe to `['DeWalt','power tool']` (sorted), spaceName.
- `:360` quantity 0 on create; update to 1 and back to 0.
- `:378` quantity −1 rejects with `/0 or more/`.
- `:387` name `'   '` rejects with `/name is required/`.
- `:396` an outer transaction with a valid create plus a CHECK-violating insert → everything rolls back (0 items).
- `:415` update name and tags keeps `id`/`createdAt`; tags become `['new']`.
- `:432` `expectedUpdatedAt: 1` after another update → rejects with `{name: 'ConflictError', status: 409}`; the name is unchanged.
- `:445` delete removes photos and item_tags, returns the orphaned URI; `tags` count stays 1.
- `:465` an unknown container rejects.

**qr bindings**
- `:473` `resolveScan('inventory://c/<token>')` → bound to the container.
- `:486` 32×`a` → `unknown`.
- `:492` `https://example.com` and `''` → `invalid`.
- `:498` rebinding a token to another container → resolves to the new one; exactly 1 binding row.
- `:512` a second `createAndBind` on the same container → the first token is `unknown`, the second `bound`.
- `:522` unbind keeps the container and items; 0 bindings.

**durability**
- `:537` close and reopen a file DB → items persist.

### 13.5 `src/db/__tests__/nodeDatabase.test.ts` (adapter; port as snapshot and restore tests)
- `:19` reopening a file keeps rows.
- `:31` in-memory snapshot, rename, restore → the old name is back.
- `:46` file snapshot is a `Uint8Array`; rename, restore, `initializeRepositories` again → the old name is back.

### 13.6 `src/repositories/__tests__/search.test.ts`
Seed (`:6-33`):
- spaces Garage (car, `#5B8DEF`) and Kitchen (pot, `#E4572E`);
- containers Tool Box (box, Garage) and Utensil Drawer (drawer, Kitchen);
- items Cordless Drill (Power Tools, tags `dewalt` and `18v`) and Hammer (Hand Tools) in Tool Box, Whisk (Utensils) in Utensil Drawer.

Tests:
- `:36` a blank query → `{terms:[], locations:[], items:[]}`.
- `:42` `usbc` and `usb-c` find `USB-C to USB-A cable`; adding `Microusb cable` does not match `usbc`.
- `:67` `DRILL` → `[Cordless Drill]`, direct.
- `:75` results carry spaceName, icon and colour.
- `:84` `power tools` → 1; `dewalt` → Drill; `18v` → 1.
- `:94` `kitchen` → `[Whisk]`, location.
- `:102` `garage` → locations include a space; `locations[0].title == 'Garage'`.
- `:110` the short code with and without the dash finds the container in `locations`.
- `:120` `garage drill` → `[Cordless Drill]`.
- `:129` `drill kitchen` → `[]`.
- `:135` add bin Spare Parts with `Garage Door Remote` → `garage` ranks it first, direct.
- `:150` `%` and `_` → no items.
- `:157` rename to `Angle Grinder` → `grinder` finds 1; after deleting, 0.
- `:168` `formatLocationPath` → `Garage > Tool Box`.
- `:174` an unnamed crate → `Garage > <shortCode>`.
- `:190` 10,000 items: `widget 4242` → exactly `[Widget 4242]` in < 1000 ms.

### 13.7 Places, categories and moves
- `src/services/places/__tests__/recentPlaces.test.ts`:
  - `:22` `mergeRecent(['a','b'],'c')` ⇒ `[c,a,b]`.
  - `:26` `([a,b,c],'b')` ⇒ `[b,a,c]`.
  - `:30` max 6: `([a..f],'g')` ⇒ `[g,a,b,c,d,e]`; with `max: 3` ⇒ `[g,a,b]`.
  - `:37` the drop zone is never stored: `([a],'drop-zone')` ⇒ `[a]`; `(['drop-zone','a'],'b')` ⇒ `[b,a]`.
  - `:44` remember `a`, `b`, `drop-zone`, `a` ⇒ read `[a,b]`, and the persisted JSON is `["a","b"]`.
- `src/hooks/__tests__/useRecentPlaces.test.tsx:33` → stored `[a,b,c]` is shown; after `rememberPlace('b')` the open picker still shows `[a,b,c]`; a newly opened picker shows `[b,a,c]`.
- `src/ui/__tests__/placeMatch.test.ts`:
  - `:32` `compact('DRW-7K2M')` ⇒ `drw7k2m`; `' Tool  chest! '` ⇒ `toolchest`.
  - `:37` `Küche` ⇒ `kuche`; `Кухня` ⇒ `кухня`.
  - `:44` `placeTerms('  drw-7k  garage - ')` ⇒ `[drw7k, garage]`; `''` ⇒ `[]`.
  - `:51` `drw7k` and `DRW-7K2M` match the drawer.
  - `:56` space name and type name match (`garage`, `cabinet`, `loft box`).
  - `:62` every term must match (`kitchen oven` ✓, `kitchen garage` ✗).
  - `:67` empty terms match.
  - `:76` `kuche` and `Küche` match `Küche`.
  - `:81` Cyrillic `кух` matches `Кухня`, and `кухня` does not match the Latin drawer.
  - `:89` `joinPlaceOptions` adds colour and icon.
  - `:121` an unknown space gives `''` colour and icon.
- `src/ui/components/__tests__/textHelpers.test.tsx`:
  - `:25` `suggestCategories(known,'to')` ⇒ `[Tools, Toys, Towels]`.
  - `:29` `'Tools'` ⇒ `[]`; `''` ⇒ 6 entries.
- `src/ui/item/__tests__/moveFlow.test.ts` (fixture `before = {id: 'item-1', containerId: 'box-a', updatedAt: 100}`; a fake `items` replays scripted `update` results and records calls and reads):
  - attemptMove `:45` moves with `expectedUpdatedAt: 100` to `box-b` ⇒ `moved(200)`, calls `[{item-1, box-b, 100}]`; `:54` update → `nil` ⇒ gone; `:59` Conflict(150) and fresh in `box-c` ⇒ `movedElsewhere(fresh)`, exactly 1 update; `:76` Conflict(150) and fresh in `box-a` @150 ⇒ retry ⇒ `moved(300)`, `expectedUpdatedAt` sequence `[100, 150]`; `:93` Conflict then a second Conflict(160) ⇒ `failed(cause: second)`, 2 updates; `:113` Conflict then `getById` nil ⇒ gone; `:125` `HouseholdHttpError(0,'offline')` ⇒ `failed(offline)`, 1 update, 0 reads.
  - attemptUndo (move `{item-1, from: box-a, updatedAt: 200}`) `:146` ⇒ undone, calls `[{item-1, box-a, 200}]`; `:152` nil ⇒ gone, Conflict(260) ⇒ conflict, offline ⇒ `failed`; `:182` `undoFailedMessage`: gone matches `/deleted/`, conflict `/changed again/`, failed+offline `/connection/`; `:190` failed with `HouseholdHttpError(500,'http_500')` or `Error('sqlite')` does not match `/connection/` but matches `/Try again/`.
  - messages `:200` `containerLabel({name: null, shortCode: 'CAB-J92R'})` ⇒ `CAB-J92R`, with name ⇒ `Tool chest`; `:205` `movedMessage` with `{Tool chest, Garage}`: not from the drop zone ⇒ `Moved to Tool chest (Garage).`; from the drop zone and not filing ⇒ `Filed in Tool chest (Garage).`; filing with `moreWaiting` true ⇒ `Filed in …`; filing with `moreWaiting` false ⇒ `Filed in Tool chest (Garage). Everything is filed.`; `:221` filing with `moreWaiting` null ⇒ `Filed in Tool chest (Garage).`; `:228` movedElsewhereMessage ⇒ `Someone already moved it to Garage shelf on another device.` / `… to SHF-1 …` when unnamed; the drop zone never shows `DROP-ZONE`; `:252` moveFailedMessage (`offline` and `http_502` → `/connection/`; `Error('SQLITE_BUSY')` → exactly `It was not moved. Try again.`).
  - nextInRun: `:260` `(['a','b','c'],'a',['b','c'])`⇒`b`; `:264` `(['a','b','c'],'c',['a','b'])`⇒`a`; `:268` `(['a','b','c','d'],'a',['c','d'])`⇒`c`; `:272` `(['a','b'],'a',['a','b'])`⇒`b` and `(['a'],'a',['a'])`⇒`nil`; `:277` `(['a','b'],'a',['z'])`⇒`z`; `:281` `(['a','b'],'x',['b','a'])`⇒`a`; `:285` `(['a','b'],'a',[])`⇒`nil` and `([],'a',[])`⇒`nil`.
  - afterFiling: `:307` drop zone reads `['b']`, item `a` ⇒ `{waiting: ['b'], moreWaiting: true}`, exactly 1 read, and `nextInRun(['a'],'a',['b'])`⇒`b`; `:316` reads `['a']` ⇒ `moreWaiting == false`, and `nextInRun(['a','b'],'a',['a'])`⇒`nil`; `:322` `listUnsorted` throws ⇒ exactly `{moreWaiting: nil}` (no `waiting` key).
- `src/ui/__tests__/errors.test.ts:52` → a `ConflictError` maps to kind `conflict` (UI spec owns the rest).
- `home-server/test/migrate.test.ts:10,27` → a new file reaches v7 (`LATEST_SCHEMA_VERSION == 7` and `PRAGMA user_version == 7`), and a second migrate on the reopened file is a no-op.

### 13.7a Tests in other areas that pin this area's schema (port with them or here)
- `src/services/sync/__tests__/photoSync.test.ts:164` › records a tombstone when a synced photo is deleted by cascade → a photo row with `remote_synced_at` set, then `items.delete(itemId)` ⇒ `SELECT photo_id FROM sync_deletions` == `[{photo_id: 'photo-a'}]` (the v4 trigger fires on a cascade).
- `photoSync.test.ts:178` › records no tombstone for a photo that was never uploaded → `remote_synced_at` NULL, then delete ⇒ `sync_deletions` empty.
- `src/services/sync/__tests__/backup.test.ts:241` › migrates a snapshot from an older build forward → a DB stopped at v1, snapshotted (`schemaVersion` 1) and restored into a seeded DB ⇒ `readSchemaVersion == LATEST_SCHEMA_VERSION` (restore then `migrate`).
- `backup.test.ts:260` › refuses a snapshot written by a newer build → `schemaVersion = LATEST + 1` ⇒ `{status: 'failed', reason: 'corrupted'}` (the refusal happens before `restoreAsync`, `src/services/sync/backup.ts:134-137`).

### 13.8 New Swift tests recommended (pin behaviours this spec found)
1. Folding vectors in §6.6, including `ガラス`, `ΟΔΟΣ` (final sigma), `ﬁle Ⅻ ①` and `İstanbul`.
2. `search('café')` does **not** find `Café Mug`; `search('caf')` does (until Q1 is decided).
3. `search('drop')`, `('zone')` and `('dropzone')` return drop-zone items as `location` matches; locations stay empty.
4. A real device file at each `user_version` from 1 to 7 (fixtures generated by running the TS migrations up to N) migrates to v7, and `sqlite_master` is byte-equal to §4.1.
5. `containers.create` with an unknown space throws (pin the chosen error per Q5).
6. `parseQuantityInput` vectors from §6.4 (per Q4).
7. Deleting a synced photo (`remote_synced_at` set) inserts a `sync_deletions` row; deleting an unsynced one does not; a cascade from deleting a space also tombstones.
8. `items.update` with `expectedUpdatedAt` on a missing row returns nil (not a conflict).
9. Opening a file that has a non-empty `-wal` keeps the WAL-only rows.
10. On-device check that `LOWER()` and `LIKE` stay ASCII-only (§2.1).
11. Tokenizer order: `tokenizeQuery("™ 𝐀BC ℌ ㎒")` ⇒ `["TM","Abc","H","MHz"]`; `placeTerms("™")` does not match a container named `tm` (§6.5 step 3).
12. Nesting: an outer `write` that runs `items.create` (through its `Database`-taking core) and then a CHECK-violating insert leaves 0 items. This is the Swift form of `persistence.test.ts:396`; see the §7 composition note.
13. `containers.update(id, {spaceId: 'drop-zone-space'})` succeeds (no guard) and `qr.bind(token, 'no-such-container')` throws and keeps the previous bindings. Pin the current behaviour, or change it deliberately.

---

## 14. Open questions

- **Q1. Search accent asymmetry.** Replicate it exactly (strict parity with the home server's search, which runs the same TS), or fix it on both sides? A fix would fold `search_text` and `normalized_name` on write, which needs a data migration (v8) that the RN Android app and the home server must also ship.
- **Q2.** The search subtitles (`"N containers · M items"`) are hard-coded English in the repository. Should native move them to the strings table (they are UI copy) while keeping the same format?
- **Q3.** `user_version > 7`: keep silently opening (current behaviour) or show a "this inventory was made by a newer app" state? Only reachable through manual file tampering on iOS.
- **Q4.** How much of the JS `Number()` grammar must `parseQuantityInput` accept (`1e2`, `0x1F`, `1.0`)? The recommendation is to accept only what the tests pin plus `1.0`-style integers.
- **Q5.** `containers.create`: keep "retry on any constraint, then report a short-code failure", or retry only on UNIQUE violations and surface FK failures? It is unreachable from the UI (spaces are picked from existing rows) but reachable from stale state.
- **Q6.** ~~Photo URI re-rooting~~ **Decided in `02-device-storage-migration.md` §3.3:** every stored URI is resolved at read time through `PhotoPathResolver` (by file name under the current `Documents/item-photos/` or `Caches/household-photos/`). Optionally rewriting rows ("self-heal") remains open as 02 Q4; if adopted it is a plain `UPDATE item_photos SET uri = ?, thumb_uri = ? WHERE id = ?` in the same shape-1 format, so the schema is unaffected.
- **Q7.** Should GRDB use a custom SQLite build to guarantee the same `LOWER`/`LIKE`/`NOCASE` behaviour and version as expo's vendored 3.50.3, or the system SQLite (verify ICU is off)?
- **Q8.** Should `useSavedQuantity` keep the quirk where `retries` is not reset on the gone and other exits from the conflict branch?
- **Q9.** Tag order is by random tag id. Keep it (parity) or sort by name in Swift? Sorting would diverge from the home server's results.
- **Q10. Text-folding parity target.** Existing on-device `search_text`, `tags.normalized_name` and category keys were written by Hermes on iOS, whose case mapping and NFKD likely come from CoreFoundation. The home server folds with V8 + ICU. Which one does Swift match when they disagree? Recommendation: use Foundation `NSString` case mapping (`(s as NSString).lowercased` / `lowercased(with: nil)`). Ship a vector test file that runs in Swift and in Node, and treat any mismatch as a bug to resolve explicitly. Do not hand-roll case tables.
- **Q11.** Should native add the guards the repositories lack (moving a container into `drop-zone-space`; `qr.bind` on a missing container surfacing as a plain error)? The home server runs the TS repositories, so a native-only guard creates asymmetry between paired and unpaired mode.

---

## 15. Dependencies on other areas

- **Household / HTTP repositories** (`src/services/household/httpRepositories.ts`, `client.ts`, `shadow.ts`): the same protocol surface as §7; `ConflictError` from 409; the shadow mirror writes the local DB with the UPSERTs in `shadow.ts:116-259`. The JSON uses the camelCase field names of §5.
- **Sync / backup** (`src/services/sync/*`): snapshot and restore (§2.5), `user_version` as `x-snapshot-schema-version`, photo sync SQL (§4.5), and calling `invalidate()` after a restore.
- **Capture / photos** (`src/services/capture/*`): photo file layout `Documents/item-photos/<id>.webp` and `<id>-thumb.webp`; deleting orphaned files after deletes; cleaning up old files when `items.update({photo})` replaces a photo; re-rooting stale absolute URIs (Q6). Fast capture creates unnamed items (`name` omitted) and then updates them with `expectedUpdatedAt` (`src/services/capture/fastCapture.ts:55-102`).
- **UI screens** (Home `src/ui/home/homeList.ts` grouping and totals over `SearchResults`; the item, container, space and picker screens): consume the query keys and `invalidate()` calls of §9.1; `describeError` (`src/ui/errors.ts`) for every error kind; toasts and haptics.
- **Connection provider**: the resume and recovery invalidation triggers (§9.1).
- **Telemetry**: events named in §2.3 and §9 (`database_ready`, `database_open_failed`, `search_performed`, `item_updated`, `item_moved`, `item_move_undone`, `item_move_failed`, `item_move_undo_failed`, `household_shadow_failed`).
- **Storage migration (cross-cutting)**: the one-shot AsyncStorage importer is owned by `02-device-storage-migration.md` §5.4 (§10.2 here). Keychain entries (expo-secure-store) are not in this area.
- **Strings**: `strings.boot.*`, `strings.quantity.*`, `strings.move.*`, `strings.errors.*`, `strings.entities.typeNames` / `unnamedItem`, `strings.common.undo` in `src/i18n/strings.ts`.

---

## Reviewer notes

An adversarial review re-read every source file in scope independently: `src/db/*`, `src/core/*`, `src/repositories/*`, the five hooks, `recentPlaces.ts`, `placeMatch.ts`, `categoryMemory.ts`, `moveFlow.ts`, `DatabaseProvider.tsx`, `ConnectionProvider.tsx`, `DropZoneProvider.tsx` and all related tests. It re-ran the migrations, the tokenizer vectors, the tag-order query plan, the FK-retry quirk and the drop-zone search in Node 24 (SQLite 3.53.1). The SQL text, constants, migration list, `sqlite_master` dump, repository semantics and most citations were confirmed accurate. Changes:

1. **§6.5 step 3 / §6.6:** corrected the description of the tokenizer order. NFKD runs *after* lowercasing and is not lowercased again, so capitals can survive (`™`→`TM`, `𝐀BC`→`Abc`, `ℌ`→`H`, `㎒`→`MHz`, verified). Added vectors and the placeMatch consequence. The old text ("`Ⅻ`→`XII`→lower") implied the opposite order.
2. **§6.5 native notes, Q10:** removed the claim that Hermes is V8. The device data was written by Hermes, whose Apple builds are understood to use CoreFoundation for case mapping and normalization (unverifiable here, so flagged as Q10). The vectors were verified on V8 + ICU.
3. **§9.1 ConnectionProvider:** resume and recovery invalidation happen **only while paired** (`ConnectionProvider.tsx:82,151`). The "first run" skip applies per session, not per launch. Unpaired mode has no resume refresh.
4. **§9.1 native design:** removed `scenePhase` as a per-query focus trigger (RN has no such trigger). Defined RN focus precisely and flagged that SwiftUI `onAppear` does not fire on sheet present or dismiss. Documented that `run` is read through a ref (every input must be in `key`), added the sentinel keys `containers-none`, `drop-zone:unused` and `space:none`, and noted the RN double read on mount.
5. **§1 decision 6 / §11:** aligned with point 4.
6. **§3.2:** added the Swift multi-line literal indentation-stripping gotcha. `sqlite_master` stores in-statement whitespace, so byte-identical text needs exact indentation. Clarified that *every* `items.update` (even quantity-only) recomputes `search_text`.
7. **§4.1:** stored `sql` has no trailing `;`, and the autoindex rows have `NULL` sql. The dump itself was re-verified as correct.
8. **§4.4 / §12.10:** the 9999 cap is not UI-wide. `validateItemForm` and `app/item/new.tsx` do not clamp, so stored quantities above 9999 are possible.
9. **§7 general:** added `changes` semantics (direct rows only), the GRDB composition design (`Database`-taking cores plus `inSavepoint`; `write {}` is not reentrant) needed by `persistence.test.ts:396`, and the list of error messages.
10. **§11 SAVEPOINT row:** expo does not "flatten" nested transactions (the Node adapter's comment is wrong); a nested call on the phone would fail. No production code nests, and the home-server importer uses raw SQL in one transaction.
11. **§7.2 `containers.update`:** there is no guard on the target `spaceId` (a container can move into `drop-zone-space`), an FK failure is a plain throw, the result is not re-read, `changes` is ignored, and the prefix is kept when `visualType` changes.
12. **§7.3.3:** fixed the citation (`:396` is the nested-rollback test, `:465` the FK test). Documented the validation order (quantity before name).
13. **§7.4 `qr.bind`:** an unknown container fails with an FK error and rolls back, so the old bindings survive.
14. **§7.5:** equal-name ties come back in unspecified order.
15. **§8.3:** `loadSaved` is triggered only by a Category field mounting. Documented the RN `recordCategory`-before-load overwrite race (fix natively with a synchronous `UserDefaults` read) and the stable-sort tiebreak.
16. **§9.3:** documented the RN identity-change race while a flush is in flight.
17. **§6.4:** the Swift regex must use ASCII `[0-9]`, not `\d`, and `jsTrim()`.
18. **§2.3 / §2.5:** retry leaks the previous connection (close it natively). Added a hedge on `sqlite3_serialize` availability in the iOS SDK and a file-based restore alternative.
19. **§13:** fixed the `stepQuantity` line (`:38`). Spelled out every moveFlow vector (nextInRun, afterFiling, undo and moved messages) that was previously deferred to "see the source". Added §13.7a: the tombstone-trigger tests (`photoSync.test.ts:164,178`) and the restore-then-migrate tests (`backup.test.ts:241,260`). Added Swift tests 11–13.
20. **§14:** added Q10 (folding parity target) and Q11 (missing repository guards).

**Completeness / consistency pass (cross-spec critic)**

21. **§2.3 step 5 (corrects note 18):** the RN retry does not leak a connection. expo-sqlite hands back its cached native connection for the same path (`SQLiteModule.swift:107-111`). Aligned with 09 §2.4. Native still drops the old `DatabaseQueue` before reopening.
22. **§9.1 resume refresh (corrects note 3):** the "first run only arms" skip is per **process**, not per session. `lastResumeRef` (`ConnectionProvider.tsx:149`) is never reset, so a leave-and-rejoin more than 5 s later invalidates. Aligned with 09 §4.3 and 04 §9.3.
23. **§10.2 / §15:** the AsyncStorage import is owned by 02 §5.4 (raw-string copy, one shared Int marker). Parsing happens on read. Removed the suggestion of a per-area importer and flag.
24. **Q6:** marked as decided by 02 §3.3 (`PhotoPathResolver` at read time); the optional row rewrite is 02 Q4.
25. **Connection type (index decision):** every spec now recommends one GRDB `DatabaseQueue` (§2.2 here), not a `DatabasePool`; 02, 03 and 09 were aligned.
