Database fixtures for InventoryStorageTests (`Database/` and `Repositories/`).

Everything here was produced by running the real TypeScript data layer
(`src/db/migrations.ts`, `src/db/nodeDatabase.ts`, `src/repositories/*`) on
`node:sqlite` (Node 24.18, SQLite 3.53.1), the same code the home server runs.
Do not edit by hand; regenerate with `generator/db-fixtures.test.ts` (its header
has the commands). Ids, short codes and clocks are seeded, so a regeneration
reproduces the same rows.

| File | Contents |
| --- | --- |
| `migrations.json` | The seven migrations' `up` text, verbatim. `Migrations.swift` was generated from it and `MigrationTests` pins them byte for byte. |
| `sqlite_master.json` | `type, name, tbl_name, sql` of every `sqlite_master` row after all migrations, in rowid order (01 §4.1). |
| `historical/v0.db` … `v6.db` | Databases at `user_version` 0 to 6: the TS migrations stopped at that version, then rows written in that version's shape (spaces, containers with and without names, items including non-ASCII capitals, value columns before v6 and a drop-zone item from v3, photos with and without thumbnails and sync stamps, tags, tag links, QR bindings, a `sync_deletions` row from v4). |
| `historical.json` | Per fixture: row counts and `sqlite_master` before opening, and every table's rows after the TS runner migrated a copy to 7. |
| `wal/v4.db`, `-wal`, `-shm` | A `user_version` 4 database copied while its writer was still open with auto-checkpoint off: the newest rows (a space, container, item, photo, tag link and a quantity change) exist only in the -wal file. |
| `wal.json` | Which rows live only in the WAL, and every table after the TS runner replayed and migrated it. |
| `search/inventory.db` | A v7 inventory built through the TS repositories: accents, Greek, Cyrillic, Japanese, apostrophes, underscores, `%`, backslashes, tags, multiple photos, drop-zone items, quantity 0, unnamed containers, 205 widgets and 34 bins (to hit the 200-item and 30-location caps), rebinds and a deleted item. |
| `search-vectors.json` | `search(query)` over that inventory for 166 queries: terms, locations, and item ids with match kinds in result order; each item's projection is stored once under `items`. |
| `reads.json` | Every other read the TS repositories offer, over the same inventory: dashboard counts, place picker, per-space and per-container reads, deletion impacts, item details and photos, recents with clamped limits, scans and token lookups. |

Notes checked while generating:

- `sqlite_master` text is identical on node's SQLite 3.53.1 and the macOS 15 test host's
  system SQLite 3.43.2; the iOS 26.3 simulator ships SQLite 3.51.0.
- `LOWER`, `LIKE` and `COLLATE NOCASE` fold ASCII only on all three (no ICU):
  `LOWER('ÄRMEL') = 'Ärmel'`, `'ärmel' LIKE 'ÄRMEL'` is 0 (01 §2.1, §13.8 #10;
  verified on the iOS 26.3 simulator with a small C program against the system
  `libsqlite3`, and pinned on the macOS host by `SchemaTests`).
