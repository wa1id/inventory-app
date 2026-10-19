# 02: In-place upgrade (device storage and the iOS project config)

**Area:** every byte the Expo/React Native build persists on an iOS device, how the native Swift app finds and adopts each one on first launch, and the Xcode target settings that let the native app ship as an App Store update to the same app.

**Sources read:** the app code (`src/`, `app/`), the iOS native sources of every persisting dependency in `node_modules/` (expo-sqlite 57.0.1, expo-secure-store 57.0.1, expo-file-system 57.0.1, @react-native-async-storage/async-storage 3.1.1, expo-modules-core, expo-image-manipulator, expo-camera, expo-image-picker, expo-system-ui, expo-constants, react-native), the generated Xcode project `ios/` (gitignored, generated 2026-07-24 21:57 by `expo prebuild` from the current `app.json`), `app.json`, `eas.json` and `.env.example`.

**Hard requirement:** same bundle id (`com.wystudio.inventory`), same Apple team. On first launch the native app opens the data the Expo build left behind, without asking the user to do anything.

---

## 0. Summary: every persisted artifact

| # | Artifact | Location in the app container | Format | Native strategy |
|---|---|---|---|---|
| 1 | Inventory database | `Documents/SQLite/inventory.db` (+ `-wal`, `-shm`) | SQLite 3, WAL mode, `user_version` 0–7 | **Read in place.** Open the same path. Never copy or move it. |
| 2 | Item photos | `Documents/item-photos/*.webp`, `*-thumb.webp`, legacy `*.jpg` | Files whose absolute `file://` URIs are stored in `item_photos.uri` / `thumb_uri` | **Read in place**, but every stored URI goes through a **path resolver** (§3.3), because the container path is not stable. |
| 3 | Household photo cache | `Library/Caches/household-photos/<photoId>.webp`, `<photoId>-thumb.webp` | WebP bytes from the home server | Disposable. Read in place or ignore. |
| 4 | Backup recovery code | Keychain: service `app:no-auth`, account/generic = UTF-8 bytes of `sync.accountSecret.v1` | UTF-8 string, 26-char Crockford base32 | **Read in place**, using the exact query (§4). |
| 5 | Household session | Keychain: service `app:no-auth`, account/generic = UTF-8 bytes of `household.session.v1` | UTF-8 JSON | **Read in place** (§4). |
| 6 | Seven device preferences | `Library/Application Support/com.wystudio.inventory/RCTAsyncLocalStorage_V1/manifest.json` (+ MD5-named overflow files) | Legacy AsyncStorage v2 manifest | **Copy once** into the native preference store (§5). |
| 7 | `ExpoSystemUI.backgroundColor` | `NSUserDefaults` standard domain | Int | Ignore or delete (§6). |
| 8 | Temporary images and share PNGs | `Library/Caches/{ImageManipulator,Camera,ImagePicker}/`, `Library/Caches/label-*.png` | Temporary files | Disposable. It is safe to purge them (§3.5). |

Nothing else is persisted. `src/services/telemetry/index.ts`, `src/services/household/devices.ts` and the Add-sheet draft (`src/ui/add/addDraft.ts:3-12`, in memory only) write nothing to disk (§7).

---

## 1. Container layout the Expo build leaves on device

```
<Data container>/                          (path not stable, see §3.3)
├── Documents/                             (backed up to iCloud and Finder)
│   ├── SQLite/
│   │   ├── inventory.db                   §2
│   │   ├── inventory.db-wal               present while the connection is open or after a crash
│   │   └── inventory.db-shm
│   └── item-photos/                       §3
│       ├── <uuid>.webp                    full image, longer edge ≤ 1400 px (≥ commit 4fa33a6)
│       ├── <uuid>-thumb.webp              list thumbnail, longer edge ≤ 320 px (≥ 4fa33a6)
│       └── <uuid>.jpg                     MVP builds 67185d8..9d24ddf (2026-07-24 → 2026-08-03), no thumb
├── Library/
│   ├── Application Support/
│   │   └── com.wystudio.inventory/
│   │       └── RCTAsyncLocalStorage_V1/   §5 (flagged isExcludedFromBackup)
│   │           ├── manifest.json
│   │           └── <md5(key)>             only for values longer than 1024 UTF-16 units
│   ├── Caches/                            (never backed up; the OS may purge it)
│   │   ├── household-photos/              §3.4
│   │   ├── ImageManipulator/<UUID>.webp   temporary output of expo-image-manipulator
│   │   ├── Camera/<UUID>.jpg              temporary output of expo-camera takePictureAsync (never deleted by the app)
│   │   ├── ImagePicker/<UUID>.<ext>       temporary output of expo-image-picker
│   │   └── label-<CODE>.png               QR label share image
│   └── Preferences/com.wystudio.inventory.plist   §6
└── tmp/                                   nothing app-owned
```

Directory resolution in the Expo build. Standalone builds are not "scoped", so the plain sandbox directories are used:
- `documentDirectory = FileManager.urls(for: .documentDirectory, in: .userDomainMask).first` and `cacheDirectory = …(.cachesDirectory…)` (`node_modules/expo-modules-core/ios/Core/AppContextConfig.swift:9-12`, `AppContext.swift:162`).
- AsyncStorage uses `NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory…)` + `[[NSBundle mainBundle] bundleIdentifier]` (`node_modules/@react-native-async-storage/async-storage/apple/legacy_storage/RNCAsyncStorage.mm:129-151`).

Native equivalents (iOS 16+ API, fine on 26): `URL.documentsDirectory`, `URL.cachesDirectory`, `URL.applicationSupportDirectory`. All three return the same URLs as the APIs above, so URIs the native app writes have exactly the RN format (§3.2).

Data protection: `ios/Inventory/Inventory.entitlements` is an empty dict, so every file has the default class `NSFileProtectionCompleteUntilFirstUserAuthentication`. expo-file-system writes with `data.write(to: url)` and no options, both for `Data` (base64 label PNG) and for typed arrays (restored photo bytes) (`node_modules/expo-file-system/ios/FileSystemFile.swift:96-116`). The native target must also have **no** `com.apple.developer.default-data-protection` entitlement.

Every file above is therefore unreadable between a reboot and the first unlock. The native app must not read `manifest.json`, the database or the keychain from a code path that can run before first unlock (for example a prewarmed launch). Gate first-launch adoption on `UIApplication.shared.isProtectedDataAvailable` (§8).

Not exposed in the Files app: `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` are absent. The native app must not add them, because they would expose the database and the photos.

---

## 2. SQLite database

### 2.1 Path and naming (exact)

- App code: `DATABASE_NAME = 'inventory.db'` (`src/db/expoDatabase.ts:63`), opened with `SQLite.openDatabaseAsync(name)` and no `directory` and no options (`src/db/expoDatabase.ts:72-73`). The only caller is `DatabaseProvider` (`src/providers/DatabaseProvider.tsx:47`).
- expo-sqlite path: `createDatabasePath(name, directory)` gives `"<defaultDatabaseDirectory without trailing slashes>/<name without leading slashes>"` (`node_modules/expo-sqlite/src/pathUtils.ts:24-36`). `openDatabaseAsync` calls `ensureDatabasePathExistsAsync` and then constructs `NativeDatabase(path)` (`node_modules/expo-sqlite/src/SQLiteDatabase.ts:576-594`).
- `defaultDatabaseDirectory = appContext.config.documentDirectory.appendingPathComponent("SQLite").standardized.path`. This is a plain path with no `file://` (`node_modules/expo-sqlite/ios/SQLiteModule.swift:24-30`). On tvOS it would be Caches, which does not apply here.
- The parent directory is created with `fileSystem.ensureDirExists(withPath:)` (`SQLiteModule.swift:303-320`). The file is opened with `sqlite3_open(path)`, so the default flags are READWRITE|CREATE (`SQLiteModule.swift:113-116`).
- **Result:** `<Documents>/SQLite/inventory.db`. `SQLite` is capitalised. There is no file extension trickery and no URL encoding.

### 2.2 Open sequence, pragmas, sidecars

`openExpoDatabase` (`src/db/expoDatabase.ts:72-77`):
1. `PRAGMA journal_mode = WAL`. WAL is persistent in the file header (bytes 18–19 = 2), so the file stays WAL even when it is opened without this pragma. Sidecars `inventory.db-wal` and `inventory.db-shm` sit next to the database. There is never a rollback `-journal`.
2. `PRAGMA foreign_keys = ON` (per connection; not persistent).
3. Then `initializeRepositories(db)` → `migrate(db)` (`src/db/repositories.ts:31-34`, `src/db/migrations.ts:284-313`). These use `PRAGMA user_version` as the schema version, with migrations 1..7 (`src/db/migrations.ts:24-262`) and `LATEST_SCHEMA_VERSION = 7` (`:265`). A device can be at **any** `user_version` from 0 to 7, depending on the last RN build that ran. The schema and migration runner are specified by the database area. This area only requires that they be applied to this exact file, in place.

Other connection facts that the native app inherits or can drop:
- One connection. No change listener (`enableChangeListener` default false), no `useNewConnection` (default false), `finalizeUnusedStatementsBeforeClosing` default true (`node_modules/expo-sqlite/ios/SQLiteOptions.swift:5-13`). No busy timeout is set. `synchronous` is the vendored build's compile-time default, FULL (`SQLITE_DEFAULT_SYNCHRONOUS 2` and `SQLITE_DEFAULT_WAL_SYNCHRONOUS = SQLITE_DEFAULT_SYNCHRONOUS`, `node_modules/expo-sqlite/vendor/sqlite3/sqlite3.c:17833-17838`).
- Vendored SQLite **3.50.3** (`node_modules/expo-sqlite/vendor/sqlite3/sqlite3.h:149`) compiled with `HAVE_USLEEP, SQLITE_ENABLE_LOCKING_STYLE=0, BYTECODE_VTAB, TEMP_STORE=2, SESSION, PREUPDATE_HOOK, MATH_FUNCTIONS, FTS3/4/5 (+FTS3_PARENTHESIS)` (`node_modules/expo-sqlite/ios/ExpoSQLite.podspec:38-43`). Its C symbols are renamed with an `ex` prefix (`exsqlite3_open`, `exsqlite3_serialize`, …, used throughout `SQLiteModule.swift`), so it never collided with the system library. None of these affect the on-disk format, and `LOCKING_STYLE=0` means standard POSIX locks, the same as the system SQLite. The schema uses no FTS, math, JSON or session features. Repositories only use core SQL (`REPLACE`, `LOWER`, `TRIM`, `GROUP_CONCAT`, `strftime`, a partial index and a trigger). Migration 6 uses `ALTER TABLE … DROP COLUMN` (`src/db/migrations.ts:215-216`), which needs SQLite ≥ 3.35.0. Every iOS 26 system SQLite is newer than that. **The iOS 26 system SQLite (which GRDB uses by default) reads and writes this file as is.**
- Backup snapshot (needed by the sync area): `PRAGMA wal_checkpoint(TRUNCATE)` then `serializeAsync('main')`, which is `sqlite3_serialize(db, "main", &size, 0)` → raw database image bytes (`src/db/expoDatabase.ts:31-34`, `node_modules/expo-sqlite/ios/SQLiteModule.swift:364-375`, `node_modules/expo-sqlite/src/SQLiteDatabase.ts:66-67`).
- Restore: `deserializeDatabaseAsync(bytes)` opens `:memory:` and calls `sqlite3_deserialize(…, SQLITE_DESERIALIZE_RESIZEABLE|FREEONCLOSE)`. Then `backupDatabaseAsync` runs `sqlite3_backup_init(dest "main", src "main")`, `backup_step(-1)` and `backup_finish`, and finally `migrate(db)` (`src/db/expoDatabase.ts:47-59`, `SQLiteModule.swift:322-344, 531-541`, `src/services/sync/backup.ts:139-143`).

### 2.3 Native recipe (GRDB)

```swift
import GRDB

enum LegacyPaths {
    static var databaseDirectory: URL { URL.documentsDirectory.appending(path: "SQLite", directoryHint: .isDirectory) }
    static var databaseFile: URL { databaseDirectory.appending(path: "inventory.db", directoryHint: .notDirectory) }
}

func openInventoryDatabase() throws -> DatabaseQueue {
    // Mirrors fileSystem.ensureDirExists (SQLiteModule.swift:317). On an upgraded device it already exists.
    try FileManager.default.createDirectory(at: LegacyPaths.databaseDirectory, withIntermediateDirectories: true)
    var config = Configuration()
    config.foreignKeysEnabled = true            // == PRAGMA foreign_keys = ON (expoDatabase.ts:75); GRDB default
    config.prepareDatabase { db in
        try db.execute(sql: "PRAGMA journal_mode = WAL")   // == expoDatabase.ts:74 (already persistent in the header)
        try db.execute(sql: "PRAGMA synchronous = FULL")   // RN ran with FULL (§2.2); parity
    }
    // Do NOT change page_size, auto_vacuum, or encoding in prepareDatabase.
    // One connection, like RN (expo-sqlite opens exactly one). See 01-data.md §2.2.
    let queue = try DatabaseQueue(path: LegacyPaths.databaseFile.path, configuration: config)
    // Then run the user_version migration runner from the database spec, NOT GRDB's DatabaseMigrator.
    return queue
}
```

Rules:
1. **Read in place. Never copy, move or rename** `inventory.db`. If the RN process was killed, the last committed transactions may exist only in `inventory.db-wal`. SQLite replays them when it opens the file at the same path with the sidecars next to it. A copy without its `-wal` silently loses those writes.
2. **Do not use `DatabaseMigrator`.** It creates a `grdb_migrations` table. That table would then travel inside every backup snapshot (`sqlite3_serialize` of `main`) and change the schema that the worker, the Android RN app and household dumps receive. Port the `user_version` runner exactly (database area).
3. Do not open the database before `Documents/SQLite/` exists (fresh install), and do not delete stray `-wal` or `-shm` files.
4. Error UX on open failure is unchanged: the copy is `strings.boot.failedTitle` / `strings.boot.failedBody` with Retry (`app/_layout.tsx:142-151`). The loading copy is `strings.boot.opening` (`src/ui/components/BootScreen.tsx:25`). Retry resets to loading and re-runs open + migrate (`src/providers/DatabaseProvider.tsx:69-72`).
5. **Use a `DatabaseQueue`, not a `DatabasePool`** (cross-spec decision, `00-index.md`; `01-data.md` §2.2). Reasons: RN used one connection; restore through the backup API and the `wal_checkpoint(TRUNCATE)` before a snapshot cannot be blocked by concurrent readers (§10); and GRDB's `DatabasePool` is believed to force `PRAGMA synchronous = NORMAL` on its writer after `prepareDatabase`, while a `DatabaseQueue` keeps the `FULL` set above. Verify the effective `synchronous` against the pinned GRDB version (§12 Q11). If a pool is ever adopted, re-run `PRAGMA synchronous = FULL` in `writeWithoutTransaction` after creation and run checkpoints in `barrierWriteWithoutTransaction`.
6. **Data-loss trap for devices at `user_version` ≤ 6.** Migration 7 rebuilds `items` (`DROP TABLE items` + rename, `src/db/migrations.ts:219-261`). The runner turns `PRAGMA foreign_keys = OFF` around it (`src/db/migrations.ts:291-310`). SQLite ignores that pragma inside a transaction. If the native runner wraps the migration in GRDB's `write {}` (which opens a transaction), the pragma does nothing. `DROP TABLE items` then cascades (`ON DELETE CASCADE`, `src/db/migrations.ts:66, 83`) and **deletes every `item_photos` and `item_tags` row on the user's phone**. Run the FK toggle in `writeWithoutTransaction`, then start the migration transaction inside it, exactly as the database spec shows (`01-data.md`, migration runner). A Swift test must upgrade a v6 fixture with photos and tags and assert that both survive.

---

## 3. Photo files

### 3.1 Writers, naming history and readers

| Era (commit) | Full image file | Thumbnail | Name source |
|---|---|---|---|
| 67185d8 → before 9d24ddf (2026-07-24 → 08-03) | `Documents/item-photos/<random uuid>.jpg` (JPEG q 0.7, width 1600) | none (`thumb_uri` column did not exist) | fresh `newId()`, **not** the `item_photos.id` |
| 9d24ddf (restore path only) | `item-photos/<photoRowId>.jpg` | none | `item_photos.id` |
| ≥ 4fa33a6 (2026-08-03) capture | `item-photos/<uuid>.webp` | `item-photos/<uuid>-thumb.webp` | fresh `newId()` per capture (`src/services/capture/imageStore.ts:100-111`), **not** the row id. The row id is another `newId()` (`src/repositories/items.ts:269, 360`) |
| ≥ 4fa33a6 restore and rehydrate | `item-photos/<photoRowId>.webp` | `item-photos/<photoRowId>-thumb.webp` | `item_photos.id` (`imageStore.ts:161-178`) |

Consequence: **a filename cannot be derived from a row id.** The only reliable link is the last path component of the stored URI.

Current constants: directory `item-photos` (`imageStore.ts:28`), extension `webp` (`:24-25`), `fullName = "<id>.webp"`, `thumbName = "<id>-thumb.webp"` (`:47-53`). The image size and quality limits live in `src/services/capture/imageScaling.ts` (capture area).

Write mechanics (`imageStore.ts:39-45, 76-87`):
1. Ensure `Documents/item-photos/` exists (`create({intermediates:true})`).
2. ImageManipulator saves to `Caches/ImageManipulator/<UUID>.webp`, encoded with `SDImageWebPCoder` (libwebp) (`node_modules/expo-image-manipulator/ios/ImageManipulatorUtils.swift:1, 79-80, 113-120`).
3. Delete any existing destination file (`:78`), read the temporary file's size (`:83`), then **move** it into `item-photos/` (`:84`).
4. The URI saved in SQLite is `destination.uri`, the `URL.absoluteString` of the file (§3.2).

**RN quirk: the move is fire-and-forget.** In expo-file-system 57.0.1, `File.move()` and `File.copy()` are native `AsyncFunction`s that return a `Promise<void>`. The synchronous variants are `moveSync` / `copySync` (`node_modules/expo-file-system/src/internal/NativeFileSystem.types.ts:240-255`; `ios/FileSystemModule.swift` `AsyncFunction("move")` / `Function("moveSync")`). `adopt()` calls `temporary.move(destination)` without `await` (`imageStore.ts:84`), and so did the MVP code (`git show 67185d8:src/services/capture/imageStore.ts`). Consequences on real devices:
- `storeItemPhoto` returns, and the row is inserted, before the file has necessarily landed in `item-photos/`.
- A failed move is an unhandled rejection. The row then points at a file that never arrived, and the temporary file stays in `Caches/ImageManipulator/`. Later `uploadPendingPhotos` deletes such a row if backup is on (§3.3).

Native: move synchronously (`FileManager.moveItem`, or write straight into `item-photos/`) and fail `storeItemPhoto` if it throws. This is a fix. The file names and URIs stay the same.

Restore writes the bytes with `create()` and `write(bytes)`, then regenerates the thumbnail (`imageStore.ts:161-178`). The thumbnail also goes through the un-awaited `adopt()`.

Readers and deleters, all by stored URI:
- `readStoredPhoto(uri)`: `new File(uri)`. If it does not exist the result is `null`, otherwise its bytes (`imageStore.ts:137-145`). Used by photo sync upload and rehydrate (`src/services/sync/photoSync.ts:63, 147`), household import (`src/services/household/importHousehold.ts:28-29, 48`) and household upload (`src/services/household/httpRepositories.ts:250, 374-375`).
- `deleteStoredPhotos(uris)`: best-effort deletes, nulls skipped (`imageStore.ts:188-198`). Callers: `app/item/new.tsx:376,450,480`, `app/item/[id]/index.tsx:238`, `app/space/[id]/edit.tsx:164`, `app/container/[id]/edit.tsx:176`, `app/capture/review.tsx:158`, `app/capture/index.tsx:186`, `src/ui/add/addDraft.ts:40,57`, `photoSync.ts:68`.
- Display: `<Thumb uri={photoThumbUri ?? photoUri}>` (`src/ui/components/Thumb.tsx:9`, `ItemRow.tsx:178,278`). The fallback applies only when the **column** is NULL. A non-NULL `thumb_uri` whose file is missing shows the placeholder, not the full image. The full photo screen uses `photoUri ?? photoThumbUri` (`app/item/[id]/photo.tsx:101`).
- Free-space check before capture (`hasRoomForPhoto`, called at `app/capture/index.tsx:172, 245`): `Paths.availableDiskSpace > estimatedBytes * 2`, with default estimate 1 000 000. A thrown error returns true (`imageStore.ts:201-207`). expo implements this as `attributesOfFileSystem(forPath: Documents)[.systemFreeSize]` and returns **nil** when the attributes cannot be read (`node_modules/expo-file-system/ios/FileSystemModule.swift:29-35`). In JS `null > 2000000` is `false`, so a nil reading means "no room" (`strings.capture.noRoom`), not "room". For exact parity, read `attributesOfFileSystem(forPath:)[.systemFreeSize]`, map nil to `false` and a throw to `true`. `.volumeAvailableCapacityForImportantUsageKey` is a reasonable improvement because it counts purgeable space and so reports more room, but it is a behaviour change. Both need privacy reason E174.1 (§9.9).

Orphans exist on real devices. A photo stored for an Add-sheet draft that was never saved (the draft is in memory only, `src/ui/add/addDraft.ts:4-13`) stays in `item-photos/` if the app is killed. So does a capture whose save failed after `storeItemPhoto`. The reverse also happens: a row can point at a file whose un-awaited move failed (above). The RN app never sweeps `item-photos/`.

### 3.2 Shapes of `item_photos.uri` / `thumb_uri` found on an iOS device

expo-file-system's `uri` is `url.absoluteString` (`node_modules/expo-file-system/ios/FileSystemModule.swift:250-251`). The URL is standardised as `deletingLastPathComponent().appendingPathComponent(last, isDirectory:)` (`FileSystemPath.swift:11-14`). Shapes:

1. `file:///var/mobile/Containers/Data/Application/<CONTAINER-UUID>/Documents/item-photos/<uuid>.webp`, with `thumb_uri` = `…/item-photos/<uuid>-thumb.webp`. This is the normal case.
2. Same shape with a `.jpg` file and `thumb_uri` NULL (MVP-era rows, and any row written before migration 5).
3. `r2:household/primary/photos/<photoId>.webp`, with thumb `r2:household/primary/photos/<photoId>-thumb.webp`. These are household shadow rows: `withLocalShadow` copies the server's `photoUri` into local SQLite with `remote_synced_at = now` (`src/services/household/shadow.ts:200-221`). The server format is `home-server/src/photos.ts:27-30, 65-66`. This shape is not a local file.
4. Rows restored from a backup taken on **Android**: `file:///data/user/0/com.wystudio.inventory/files/item-photos/<…>.webp` (no file on iOS; rehydrated later).
5. Rows restored from a backup taken in an **older iOS container**: shape 1 with a different `<CONTAINER-UUID>`.

Simulator paths look like `file:///Users/<u>/Library/Developer/CoreSimulator/Devices/<D>/data/Containers/Data/Application/<U>/Documents/item-photos/…`. They may be percent-encoded, so always parse with `URL(string:)` and use `.path`.

Native writes must keep producing shape 1, with the format `URL.documentsDirectory.appending(path: "item-photos/\(name)").absoluteString`. Backups are restored by the RN Android app and by RN TestFlight builds, and `photoSync.rehydrateMissingPhotos` repairs any foreign absolute path. A new relative format would be a cross-platform contract change, so do not introduce one.

### 3.3 The container path is not stable: required resolver

Apple does not guarantee that the data-container path (`…/Application/<UUID>/`) stays the same. It changes at least on restore from backup and on migration to a new device, and may change on app updates. The RN code itself admits this for restores (`src/services/sync/photoSync.ts:126-130`). The RN app does **not** rebase stale paths. When the path moves:
- thumbnails and photos go blank;
- when backup is on, `uploadPendingPhotos` **deletes the row** of every unsynced photo (`remote_synced_at IS NULL`) whose file it cannot read, and best-effort deletes its `thumb_uri` file (`photoSync.ts:52-70`, asserted by the test "drops a row whose local file has vanished…");
- synced rows (`remote_synced_at IS NOT NULL`) are re-downloaded by `rehydrateMissingPhotos` into `item-photos/<rowId>.webp`, and the row's `uri`/`thumb_uri`/`byte_size` are rewritten (`photoSync.ts:131-168`). Household shadow rows (`r2:` URIs, `remote_synced_at` = shadow time) never resolve locally, so every pass asks the sync worker for them by row id and skips them on `not_found` (`:149-153`). Keep that behaviour; it belongs to the sync area.

The native app must resolve every stored URI through one function before it checks existence, reads, displays or deletes. This is a deliberate fix to latent RN behaviour. It changes no wire contract.

```swift
struct PhotoPathResolver: Sendable {
    let documents = URL.documentsDirectory
    let caches = URL.cachesDirectory

    /// Returns a URL that exists on disk now, or nil (not a local file, or the bytes are gone).
    func resolve(_ stored: String?) -> URL? {
        guard let stored, let url = URL(string: stored), url.isFileURL else { return nil }   // r2:, http(s): → nil
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return url }                                       // same container (common case)
        let name = url.lastPathComponent
        guard !name.isEmpty else { return nil }
        let candidate: URL
        switch url.deletingLastPathComponent().lastPathComponent {
        case "item-photos":      candidate = documents.appending(path: "item-photos").appending(path: name)
        case "household-photos": candidate = caches.appending(path: "household-photos").appending(path: name)
        default:                 return nil
        }
        return fm.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// The URI string to persist for a file in the current container (shape 1).
    func storedURI(forPhotoNamed name: String) -> String {
        documents.appending(path: "item-photos").appending(path: name).absoluteString
    }
}
```

Required uses (cross-area): native ports of `readStoredPhoto`, `deleteStoredPhotos`, `uploadPendingPhotos` (vanished-file check), `rehydrateMissingPhotos` (`if await readStoredPhoto(uri)` skip), household import, and every image view.

Optional self-heal: when `resolve` finds a file only through the rebase branch, the app may run `UPDATE item_photos SET uri = ?, thumb_uri = ? WHERE id = ?` with `storedURI(...)`. This is safe because it is the same format in the current container, and RN TestFlight builds read it fine. See §12 Q4.

### 3.4 Household photo cache

- Location: `Caches/household-photos/`, created on demand (`src/services/household/photoCache.ts:18-20, 50-52`).
- Names: `<photoId>.webp` (full) and `<photoId>-thumb.webp` (thumb) (`photoCache.ts:21-23`).
- Filled two ways. (a) Downloads from `GET <origin>/v1/photos/<encodeURIComponent(id)>` or `…?thumb=1` through `householdFetch` (headers `Accept: application/json`, `Authorization: Bearer <token>`, default timeout 20 000 ms, `src/services/household/client.ts:154-168`). The response is used only if `response.ok`, and any throw returns `null` (`photoCache.ts:26-40`). (b) A copy of a local capture after it was posted (`rememberHouseholdPhoto`, `photoCache.ts:44-58`, called from `httpRepositories.ts:265-267`). The copy uses `source.copy(destination)` without `await` (`photoCache.ts:68`), which is fire-and-forget like the move in §3.1.
- The app treats an existing file as authoritative and never re-fetches it (`photoCache.ts:24`). A truncated or empty cached file therefore stays until iOS purges Caches. Paired-mode items get `photoUri` / `photoThumbUri` rewritten **in memory** to these `file://` URIs (`httpRepositories.ts:88-121`). Shadow rows keep `r2:` (§3.2).
- Native: this is a cache, so the app can reuse the directory and names (no migration needed) or replace it with its own cache. Wire details belong to the household area.

### 3.5 Temporary files (disposable)

| Path | Producer | Cited |
|---|---|---|
| `Caches/ImageManipulator/<UUID>.<webp|jpg|png>` | every `saveAsync`. Moved out by `adopt()` on success, left behind on failure | `node_modules/expo-image-manipulator/ios/ImageManipulatorUtils.swift:113-120` |
| `Caches/Camera/<UUID>.jpg` | `takePictureAsync({quality:1, skipProcessing:false})` (`app/capture/index.tsx:224,254`). **Never deleted by the app** | `node_modules/expo-camera/ios/Current/CameraPhotoCapture.swift:259-263`, `expo-modules-core/ios/FileSystemUtilities/FileSystemUtilities.swift:30-36` |
| `Caches/ImagePicker/<UUID>.<ext>` | `launchImageLibraryAsync` (`app/capture/index.tsx:353`) | `node_modules/expo-image-picker/ios/MediaHandler.swift:489-498` |
| `Caches/label-<CODE>.png` | QR label share image, written from `app/container/[id]/qr.tsx:213`. 1024×1024 PNG from `react-native-svg` `toDataURL` with a 4000 ms timeout. Name = shortCode with `[^A-Za-z0-9-]` removed, else `label`. Overwritten on every share | `src/ui/container/labelImage.ts:12-15, 43-51` |

Native first-launch cleanup may delete these three directories and `Caches/label-*.png`. Nothing references them.

---

## 4. Keychain (expo-secure-store 57.0.1)

### 4.1 Exact item attributes

The app never passes `SecureStoreOptions` (`src/services/account/identity.ts:45,55,82,106,117`; `src/services/household/session.ts:9,32,37`), so every default applies:

| Attribute | Value | Source |
|---|---|---|
| `kSecClass` | `kSecClassGenericPassword` | `SecureStoreModule.swift:181` |
| `kSecAttrService` | `"app:no-auth"`, from `keychainService ?? "app"` plus `":no-auth"` because `requireAuthentication` defaults to `false`. The JS side passes `{}` (`SecureStore.ts` default `options = {}`), and the non-optional `@Field var requireAuthentication: Bool` takes `Field<Bool>`'s default `false` | `SecureStoreModule.swift:173-176`, `SecureStoreOptions.swift:13-14`, `node_modules/expo-modules-core/ios/Core/Records/FieldExtensions.swift:30-33` |
| `kSecAttrAccount` | **`Data(key.utf8)`** (a CFData blob, not a CFString) | `SecureStoreModule.swift:178, 184` |
| `kSecAttrGeneric` | **`Data(key.utf8)`** (same bytes) | `SecureStoreModule.swift:183` |
| `kSecValueData` | `value.data(using: .utf8)` | `SecureStoreModule.swift:92-93` |
| `kSecAttrAccessible` | `kSecAttrAccessibleWhenUnlocked` (default `.whenUnlocked` = raw value 5) | `SecureStoreOptions.swift:8`, `SecureStoreModule.swift:95-98, 194-211` |
| `kSecAttrAccessGroup` | not set → the default group = the application-identifier `<TeamID>.com.wystudio.inventory` (no `keychain-access-groups` entitlement: `ios/Inventory/Inventory.entitlements` is empty) | `SecureStoreModule.swift:187-189` |
| `kSecAttrSynchronizable` | not set → not iCloud Keychain-synced | (absent) |

Every unqualified path in this table and the list below is under `node_modules/expo-secure-store/ios/`.

Algorithms as implemented by expo:
- **get** (`SecureStoreModule.swift:69-87, 146-170`): probes services in the order `app:no-auth`, `app:auth`, `app` (legacy, no suffix). Each probe uses `kSecMatchLimitOne` and `kSecReturnData`. `errSecItemNotFound` (or a non-`Data` result) moves on to the next probe. Any other status **throws**. A found item returns `String(data:encoding:.utf8)`. If nothing is found the result is `nil`.
- **set** (`:89-125`): `SecItemAdd`. On success it deletes the `app` and `app:auth` variants. On `errSecDuplicateItem` it calls `SecItemUpdate(query, [kSecValueData: data])`, which does **not** touch accessibility (`:127-144`). Any other status throws `KeyChainException(status)`.
- **delete** (`:43-51`): `SecItemDelete` on `app`, then `app:auth`, then `app:no-auth`. Statuses are ignored.
- Key validation: JS `/^[\w.-]+$/` (`node_modules/expo-secure-store/src/SecureStore.ts:229-239`) and native "trimmed not empty" (`:213-219`).
- `isAvailableAsync()` returns `!!ExpoSecureStore.getValueWithKeyAsync`, so it is always true on iOS (`SecureStore.ts:115-117`). Its wrapper `isSecureStoreAvailable` (`identity.ts:43-49`) has **no callers** in `src/` or `app/`. Do not port it.
- **`app:auth` items cannot exist.** The primary reason is that no call site passes `requireAuthentication: true` (all calls use `{}`, see above), so every write goes to `app:no-auth`. A secondary guard: with `requireAuthentication: true`, expo throws `MissingPlistKeyException` when `NSFaceIDUsageDescription` is missing (`SecureStoreModule.swift:100-102`), and current builds set `faceIDPermission: false` (`app.json:47-51`). Builds from 67185d8 and 83c8639 used the plugin default and probably did ship the key; `faceIDPermission: false` arrived in 14aa749. The legacy `app` service (no suffix) cannot exist either. The app has used expo-secure-store 57.x since its first commit (`git show 67185d8:package.json`), and that version always writes `app:no-auth` and deletes `app` and `app:auth` after every successful add (`:115-119`). Probing is cheap and harmless.

### 4.2 The two items

| Key (exact) | Account/generic bytes (hex) | Value | Writer | Reader | Validation on read |
|---|---|---|---|---|---|
| `sync.accountSecret.v1` (`identity.ts:30`) | `73796e632e6163636f756e745365637265742e7631` | Canonical **unformatted, uppercase Crockford base32**, 26 characters, of 16 CSPRNG bytes (`identity.ts:78-85, 95-112`; alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ`, `src/services/account/base32.ts:15`; `SECRET_BYTES = 16`, `src/services/sync/contract.ts:16`) | `createAccount` (from `SyncProvider.enable`, `src/providers/SyncProvider.tsx:128`), `importAccount` (from `restoreFromCode`, `:163`). Deleted by `forgetAccount` after a failed restore (`:190`) | `loadAccount`, from `SyncProvider` mount (`:79`, **only when `appConfig.syncEndpoint` is set**, `:75`), `app/backup.tsx:130` and `importHousehold.ts:86-87` | Empty or missing means no account (`identity.ts:63`). `decodeBase32(stored)` must give exactly 16 bytes, otherwise "no account" (`identity.ts:64-66`). The decoder removes `-`, trims, uppercases and folds `I`/`L`→1 and `O`→0. Any character outside the alphabet gives `null` (`base32.ts:58-79`). `recoveryCode` is returned exactly as stored, not re-canonicalised (`identity.ts:68`). **Any keychain error means no account, never a newly minted one** (`identity.ts:53-61`). Account id = hex of the first 16 bytes of SHA-256(secret) (`identity.ts:131-134`) |
| `household.session.v1` (`session.ts:5`) | `686f757365686f6c642e73657373696f6e2e7631` | `JSON.stringify(session)` with keys in this order: `{"origin":string,"token":string,"deviceId":string,"deviceName":string,"householdName":string}` (`src/services/household/client.ts:62-68, 94-100`; `session.ts:31-33`). `origin` is the server-returned origin with trailing `/+` stripped, `deviceName` is the typed name `.trim()`ed, and `householdName` falls back to `'Home'` when the server sends none (`client.ts:95-99`). Written only once, at pairing. Nothing rewrites it later (`saveHouseholdSession` has one caller) | `HouseholdProvider.pair` (`src/providers/HouseholdProvider.tsx:50-54`). Cleared by `disconnect` (`:56-59`, called from `app/household.tsx:219` and `src/ui/components/ConnectionBanner.tsx:73,79`) | `HouseholdProvider` mount (`:37`), `JoinForm` (`src/ui/household/JoinForm.tsx:121`) | Must parse. `origin`, `token` and `deviceId` must be strings, else `null`. `deviceName` defaults to the literal `'This phone'` and `householdName` to the literal `'Home'` (hard-coded English, not keys in `strings.ts`). Any throw gives `null` (`session.ts:7-29`) |

`expo-constants` would write an installation id item (service = bundle id, key `EXDeviceInstallationUUIDKey`, `AfterFirstUnlockThisDeviceOnly`), but nothing in SDK 57 calls `getOrCreateInstallationId` (`node_modules/expo-constants/ios/EXConstantsInstallationIdProvider.m:9-20`; `EXConstantsService.m` only imports it). **That item does not exist.** Ignore it.

### 4.3 Swift recipe: keep Expo's coordinates forever

Read in place, with no migration. Keep writing with the same coordinates, so an RN TestFlight build installed over the native one still finds the items:

```swift
import Foundation
import Security

/// Byte-compatible with expo-secure-store 57.0.1 defaults (SecureStoreModule.swift:172-192).
enum ExpoCompatibleKeychain {
    enum Service: String, CaseIterable { case noAuth = "app:no-auth", auth = "app:auth", legacy = "app" }
    enum Failure: Error, Sendable { case status(OSStatus) }

    static func query(_ key: String, _ service: Service) -> [String: Any] {
        let encodedKey = Data(key.utf8)                     // Data, NOT String: matches how expo stored it
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.rawValue,
            kSecAttrGeneric as String: encodedKey,
            kSecAttrAccount as String: encodedKey,
        ]
    }

    /// get(with:) — no-auth, then legacy. (`app:auth` cannot exist, §4.1; skipping it avoids any chance of a biometric prompt.)
    static func read(_ key: String) throws(Failure) -> String? {
        for service in [Service.noAuth, .legacy] {
            var q = query(key, service)
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            q[kSecReturnData as String] = true
            var item: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                guard let data = item as? Data else { continue }
                return String(data: data, encoding: .utf8)
            case errSecItemNotFound: continue
            default: throw .status(status)            // e.g. errSecInteractionNotAllowed (-25308) while locked
            }
        }
        return nil
    }

    static func write(_ key: String, _ value: String) throws(Failure) {
        let data = Data(value.utf8)
        var add = query(key, .noAuth)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            SecItemDelete(query(key, .legacy) as CFDictionary)
            SecItemDelete(query(key, .auth) as CFDictionary)
        case errSecDuplicateItem:
            let s = SecItemUpdate(query(key, .noAuth) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard s == errSecSuccess else { throw .status(s) }
        default:
            throw .status(status)
        }
    }

    static func delete(_ key: String) {              // ignores statuses, like expo
        for service in [Service.legacy, .auth, .noAuth] { SecItemDelete(query(key, service) as CFDictionary) }
    }
}
```

Error mapping that must be preserved (owned by the account and household areas):
- `loadAccount`: any throw → `nil`.
- `importAccount`: a write throw → `.unavailable`.
- `createAccount`: a write throw propagates.
- `forgetAccount`, `clearHouseholdSession`: swallow errors.
- `loadHouseholdSession`: any throw or bad JSON → `nil`.
- `saveHouseholdSession`: propagates.

Signing prerequisite: the native build must be signed by the **same Team** (App ID prefix). Keychain access is scoped to `<AppIDPrefix>.com.wystudio.inventory`, not to the certificate, so a new distribution certificate or profile is fine. Do **not** add `keychain-access-groups` in v1. If an extension needs the items later, reads without `kSecAttrAccessGroup` still search every group the app belongs to, but new items would land in the first listed group.

### 4.4 Lifecycle semantics the native app inherits

- **Uninstall/reinstall:** iOS keeps keychain items across uninstall. A fresh install (native or RN) silently finds the old recovery code and the old household session, while `Documents/` is empty. RN relies on this (`identity.ts:23-25`). Keep the same behaviour, and do not "clean up" keychain items on first launch.
- **Device restore or migration:** `WhenUnlocked` (not `ThisDeviceOnly`) items travel in encrypted backups and Quick Start migrations, so both items move to the new phone.
- **Locked device:** reads fail with `errSecInteractionNotAllowed` (-25308) while the device is locked. RN only touches the keychain from the foreground (mount and user actions; the sync pass runs on `AppState` `active`, `SyncProvider.tsx:112-123`). Both RN readers turn that error into "absent": `loadAccount` gives no account, and `loadHouseholdSession` gives **not paired**. So the native app must not read these items before protected data is available (§8 step 0). If native ever adds background refresh, see §12 Q10.

---

## 5. AsyncStorage: the legacy v2 format under package v3.1.1

### 5.1 Which backend the app uses

Every call site imports the **default** export (`import AsyncStorage from '@react-native-async-storage/async-storage'`, plus the dynamic `import(...).default` in `src/ui/categoryMemory.ts:41-43`). In v3 the default export is `getLegacyStorage()` (`node_modules/@react-native-async-storage/async-storage/src/index.tsx:9`). Its methods call the `legacy_multiGet/Set/Remove` TurboModule methods (`src/createAsyncStorage.native.ts:127-200`). Those methods go to the classic `RNCAsyncStorage` sharedInstance (`apple/AsyncStorage.mm:74-190`). The app never calls `createAsyncStorage(name)`, so **the v3 Kotlin Multiplatform `SharedAsyncStorage` SQLite database is never created** (`apple/storage/StorageRegistry.swift:21-38` is only reached through that API).

### 5.2 On-disk format (exact)

All lines are in `node_modules/@react-native-async-storage/async-storage/apple/legacy_storage/RNCAsyncStorage.mm`:

- Directory: `<Application Support>/<bundleIdentifier>/RCTAsyncLocalStorage_V1`, which is **`Library/Application Support/com.wystudio.inventory/RCTAsyncLocalStorage_V1/`** (`:17, 129-151, 153-165`). It is created with intermediates on first use (`:283-289, 518-524`).
- Manifest: `<dir>/manifest.json` (`:20, 167-180, 538`). It is a UTF-8 JSON **object** written with `writeToFile:atomically:YES encoding:NSUTF8StringEncoding` after every mutation (`:570-584`). Each entry maps `key → string` (value inlined) or `key → null` (value stored in a separate file). A missing key means no value.
- Inline threshold: `RCTInlineValueThreshold = 1024`, compared against `NSString.length`, i.e. **UTF-16 code units** (`:21, 633`). A value longer than 1024 goes to `<dir>/<RCTMD5Hash(key)>`, written atomically as UTF-8 (`:643`), and the manifest entry becomes `null` (`:647-650`). `RCTMD5Hash` = lowercase hex MD5 of the key's UTF-8 bytes (`node_modules/react-native/React/Base/RCTUtils.mm:256-268`). The file name is `_filePathForKey` (`RNCAsyncStorage.mm:507-511`). Shrinking a value back under the threshold deletes the file and inlines it (`:633-641`).
- Read: a manifest value that is a string is returned. `null` reads the MD5 file. If that file is **missing**, the key is treated as absent and dropped from the in-memory manifest (`:598-617`). If it **exists but cannot be read** (data protection, I/O) or is not UTF-8, `RCTReadFile` reports an error (`:82-110`). `multiGet` then fails the whole call (`:688-697`), and the app's call sites fall back to their defaults for that launch. They do not treat the key as gone.
- Serialisation: `RCTJSONStringify` → `NSJSONSerialization dataWithJSONObject:options:4` (fragments allowed, compact, unsorted, `/` escaped as `\/`) (`node_modules/react-native/React/Base/RCTUtils.mm:95-99`). Parsing: `RCTJSONParseMutable` (`RCTUtils.mm:129-195`).
- Manifest problems: if the file is missing, the store starts empty. If the file exists but cannot be read (data protection), the call **errors**, and every app call site catches that and falls back to its default. If the file cannot be parsed, the store starts empty (`:537-563`).
- Remove: deletes the overflow file if there is one, removes the key and rewrites the manifest (`:738-781`).
- Backup: the directory is flagged `NSURLIsExcludedFromBackupKey = YES`, because `RCTAsyncStorageExcludeFromBackup` is absent from Info.plist (`:527-535`, `ios/Inventory/Info.plist` has no such key). **These preferences are not in iCloud or Finder backups.**
- Startup migrations from `Documents/RNCAsyncLocalStorage_V1`, `Documents/RCTAsyncLocalStorage` and `Documents/RCTAsyncLocalStorage_V1` (`:332-462`). These cannot apply to this app, which shipped v3 from its first commit (67185d8). The reader may still fall back to `Documents/RCTAsyncLocalStorage_V1/manifest.json` if the Application Support directory is missing. This costs nothing.

### 5.3 The seven keys

| Key (exact) | Value written | Writer (path:line) | Reader and how it interprets the value | MD5 file name (only used if > 1024 chars) |
|---|---|---|---|---|
| `onboarding.completed.v1` | `"true"`. **Removed** on replay | `setOnboardingCompleted` (`src/services/onboarding.ts:20-30`) via `OnboardingProvider.complete` / `replay` (`src/providers/OnboardingProvider.tsx:33-41`), called from `app/onboarding.tsx:51` and Settings replay (`app/settings.tsx:89`) | `hasCompletedOnboarding`: completed iff `=== 'true'`. A read error means not completed (`onboarding.ts:10-18`). Read before the database is ready (`:6-9`) | `4efd6215b53ae2eccc3504de2a5a5352` |
| `places.recent.v1` | JSON array of container-id strings (lowercase UUID v4, `src/core/id.ts:41-54`), most recent first, ≤ 6, never `drop-zone` | `rememberPlace` (`src/services/places/recentPlaces.ts:57-66`), called from `src/hooks/useMove.ts:134`, `app/item/new.tsx:547`, `app/c/[token].tsx:131` | `readRecentPlaces`: parse. Non-array gives `[]`. Non-strings are filtered out, then `slice(0, 6)`. A read or parse error gives `[]`. The list is cached in memory after the first read (`recentPlaces.ts:40-54`) | `29ce820024d261826454db01a9ea7e83` |
| `categories.recent.v1` | JSON array of trimmed strings, case-insensitively unique, most recent first, ≤ 20. **The only key that can plausibly exceed 1024 UTF-16 units.** Read the overflow file | `recordCategory` (`src/ui/categoryMemory.ts:88-100`), called from `app/item/new.tsx:548`, `app/item/[id]/edit.tsx:198` | `loadSaved`: parse. If it is not an array, ignore it. Non-strings are filtered out, then `mergeSaved([...inMemory, ...restored])`, which trims, dedupes on `trim().toLowerCase()`, drops empties and caps at 20 (`categoryMemory.ts:45-73`). It runs at most once per process (`loading` is never reset, even after a failure), triggered by the first mounted `useKnownCategories` (`:138`). **RN race (do not port):** `recordCategory` persists the in-memory list (`:95`). If the load has not finished or has failed, that write overwrites the stored list with one that lacks the stored entries. Native: load before the first write | `9355fb19fd0f6f39f84680882e0638d7` |
| `notice.unpaired.dismissed.v1` | `"1"` | `useUnpairedNotice().dismiss` (`src/ui/home/unpairedNotice.ts:34-39`), from `app/(tabs)/index.tsx:595` | dismissed iff `=== '1'`. A read error means not dismissed (`unpairedNotice.ts:19-32`) | `85473032ec85220ff4db0e47bb85ea0c` |
| `sync.lastBackupAt.v1` | `String(capturedAt)`: integer ms epoch from the **server's** backup summary | `recordBackup` after a successful upload (`src/services/sync/backup.ts:39-46, 91-93`) | `lastBackupAt`: `stored ? Number(stored) : NaN`. A finite result is the value, otherwise `null`. An error gives `null` (`backup.ts:29-37`). JS `Number` trims whitespace, so the Swift version is `Double(s.trimmingCharacters(in: .whitespacesAndNewlines))`, and an empty string gives `nil`. When native writes it, use the integer form (`String(Int64(capturedAt))`, never a `".0"` suffix). This matches `String(number)` for an integral JS number, so a TestFlight rollback that still reads AsyncStorage would parse it the same way | `4102c4cb6d3d14e013e7d1264995f65b` |
| `household.importOffer.v1` | `{"spaces":<int>,"items":<int>}` (key order as written by `JSON.stringify`; `spaces` = `listWithCounts().length`, `items` = `countAll()`). **Removed** when there is nothing to offer (0 spaces and 0 items), after a successful copy (`app/household.tsx:148`), on "not needed" (`:167`) and on leaving the household (`:226`) | `snapshotBeforeJoin` (`src/services/household/importOffer.ts:24-42`) from `JoinForm.tsx:117`. Skipped entirely if `household.joinedBefore.v1 === 'true'`. Any error writes nothing (`:39-41`). `clearImportOffer` (`:75-81`) from `app/household.tsx:148,167,226` | `readImportOffer`: an object with numeric `spaces` and `items`, else `null` (`importOffer.ts:53-72`) | `53ba6e24df460ea0df0bec2d52664252` |
| `household.joinedBefore.v1` | `"true"` | `markJoinedBefore` (`importOffer.ts:45-51`) from `JoinForm.tsx:119` and on every start that has a session (`src/providers/ConnectionProvider.tsx:83`) | `snapshotBeforeJoin` returns early iff `=== 'true'` (`importOffer.ts:28`) | `56c32de8db5d6d12a35b329fcc891dac` |

The MD5 values were computed with `printf '%s' "<key>" | md5sum`. Use them as Swift test vectors.

Example of the manifest the native reader will meet (NSJSONSerialization writes compact JSON and escapes `/` as `\/`):

```json
{"onboarding.completed.v1":"true","household.joinedBefore.v1":"true","sync.lastBackupAt.v1":"1754236800000","places.recent.v1":"[\"3f1c2a9e-8b7d-4c1e-9f00-1a2b3c4d5e6f\"]","categories.recent.v1":null}
```

### 5.4 Swift reader and one-time import

```swift
import CryptoKit
import Foundation

struct LegacyAsyncStorageReader: Sendable {
    var directory: URL = URL.applicationSupportDirectory
        .appending(path: Bundle.main.bundleIdentifier ?? "com.wystudio.inventory", directoryHint: .isDirectory)
        .appending(path: "RCTAsyncLocalStorage_V1", directoryHint: .isDirectory)

    enum Failure: Error, Sendable { case unreadableManifest(any Error), notUTF8, unreadableValue(key: String) }

    /// [:] when the RN app never wrote anything. Throws when the manifest, or an overflow file that exists,
    /// cannot be read. The caller then leaves the marker unset and retries next launch, as RN would.
    func readAll() throws(Failure) -> [String: String] {
        let fm = FileManager.default
        let manifestURL = directory.appending(path: "manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) else { return [:] }
        let data: Data
        do { data = try Data(contentsOf: manifestURL) } catch { throw .unreadableManifest(error) }
        guard String(data: data, encoding: .utf8) != nil else { throw .notUTF8 }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] } // RN: unparsable → empty
        var values: [String: String] = [:]
        for (key, raw) in object {
            if let string = raw as? String {
                values[key] = string
            } else if raw is NSNull {
                let file = directory.appending(path: Self.md5Hex(key))
                guard fm.fileExists(atPath: file.path) else { continue }          // missing → absent (RNCAsyncStorage.mm:610-613)
                guard let fileData = try? Data(contentsOf: file),
                      let string = String(data: fileData, encoding: .utf8) else {
                    throw .unreadableValue(key: key)                              // exists but unreadable → error, not absent
                }
                values[key] = string
            }
        }
        return values
    }

    static func md5Hex(_ key: String) -> String {
        Insecure.MD5.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
```

Import policy (recommended): **copy once into `UserDefaults.standard`, with the same key names and the same string values**. Every reader then ports one-for-one ("true", "1", JSON strings, numeric string):

```swift
import UIKit

enum LegacyImport {
    static let marker = "native.legacyImport.v1"           // Int; 1 = done
    static let keys = ["onboarding.completed.v1", "places.recent.v1", "categories.recent.v1",
                       "notice.unpaired.dismissed.v1", "sync.lastBackupAt.v1",
                       "household.importOffer.v1", "household.joinedBefore.v1"]

    @MainActor
    static func runIfNeeded(defaults: UserDefaults = .standard, reader: LegacyAsyncStorageReader = .init()) {
        guard defaults.integer(forKey: marker) < 1 else { return }
        guard UIApplication.shared.isProtectedDataAvailable else { return }   // before first unlock: files unreadable (§1)
        let legacy: [String: String]
        do { legacy = try reader.readAll() }
        catch { return }                                   // locked or unreadable: RN would show defaults this launch; retry next launch
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = legacy[key] { defaults.set(value, forKey: key) }   // never overwrite a native value
        }
        defaults.removeObject(forKey: "ExpoSystemUI.backgroundColor")        // §6
        defaults.set(1, forKey: marker)
    }
}
```

- Ignore any manifest keys that are not in the list. No other library writes AsyncStorage in this app.
- Do **not** delete or modify `RCTAsyncLocalStorage_V1/`. An RN TestFlight build installed over the native one would read it (stale but valid). Deleting it can wait for a later release (§12 Q6).
- Values are copied verbatim, so the readers keep every one of the RN validation rules in §5.3.

**Deliberate behaviour difference to approve (§12 Q3):** `UserDefaults` is included in iCloud and Finder backups. The RN AsyncStorage directory was excluded. After a device restore the native app will remember onboarding, recent places and categories, the dismissed notice, `lastBackupAt` and `joinedBefore`. RN would have forgotten them, shown onboarding again and taken an immediate backup. For strict parity, store the same `[String: String]` in a JSON file under `Application Support/com.wystudio.inventory/` with `isExcludedFromBackup = true`.

---

## 6. NSUserDefaults written by RN dependencies

- `ExpoSystemUI.backgroundColor` (Int): written every time the root layout calls `SystemUI.setBackgroundColorAsync(colors.plaster)` (`app/_layout.tsx:113-115`; `node_modules/expo-system-ui/ios/ExpoSystemUI/ExpoSystemUIModule.swift:6, 62`). It is meaningless to the native app. Delete it in the legacy import (§5.4) or ignore it.
- React Native's `RCTBundleURLProvider` keys are written only in debug or dev-client builds (`node_modules/react-native/React/Base/RCTBundleURLProvider.mm:532`). `RCTI18nUtil_allowRTL` / `_forceRTL` / `_makeRTLFlipLeftAndRightStyles` are written only when JS calls `I18nManager.allowRTL/forceRTL/swapLeftAndRightInRTL` (`React/Modules/RCTI18nUtil.m:59, 75, 86`). The app never calls `I18nManager` (no match in `src/` or `app/`), so they do not exist. Ignore all of them.
- Native preference keys must not collide with these names. The keys in §5.3 do not.

---

## 7. Modules that persist nothing (checked)

- `src/services/telemetry/index.ts:69-91`: console sink only, no storage.
- `src/services/household/devices.ts`: network only.
- `src/ui/add/addDraft.ts:23`: in-memory `slot`, lost on restart (its photo file is the only disk effect, §3.1).
- `src/ui/categoryMemory.ts:19` "seen" map and `src/services/places/recentPlaces.ts:27` cache: in memory.
- `expo-router`, `expo-crypto`, `expo-haptics`, `expo-linking`, `expo-status-bar`: no persistence. `expo-font` does not embed fonts through its config plugin here. Instead `FontProvider` calls `loadAsync` at runtime on five bundled Atkinson Hyperlegible Next assets (`src/providers/FontProvider.tsx:21-27, 49`), and expo-asset resolves them inside the app bundle, so nothing is written. The transitive, autolinked `expo-asset` and `expo-keep-awake` (`node_modules/expo/node_modules/`) persist nothing for bundled assets.
- `URLSession` caches and HTTP storage (`Library/Caches/com.wystudio.inventory/`, `Library/HTTPStorages/…`) are OS-managed and disposable.

---

## 8. First-launch adoption sequence (native)

RN boot order for reference: `DatabaseProvider` opens and migrates the database, `HouseholdProvider` loads the session from the keychain, and `OnboardingProvider` reads its AsyncStorage flag, all concurrently. The database error screen takes precedence: it shows as soon as the open fails, even while the other two are still loading (`app/_layout.tsx:142-152`). Otherwise the navigator shows `BootScreen` until all three are ready (`app/_layout.tsx:154-156, 223-249`). `SyncProvider` loads the account after mount, and only when `SYNC_URL` is configured (`SyncProvider.tsx:74-88`; guard at `:75`). Fonts are never waited for.

Native sequence. Every step is idempotent and safe to repeat on every launch:

```
On the first scene activation (not in App.init: a prewarmed or pre-first-unlock launch
cannot read the Data-Protection files or the WhenUnlocked keychain items, §1 and §4.4):
  0. If !UIApplication.shared.isProtectedDataAvailable, wait for
     UIApplication.protectedDataDidBecomeAvailableNotification before steps 1–2.
  1. LegacyImport.runIfNeeded()                      // §5.4: one small file read; sets marker only on success
  2. In parallel:
     a. openInventoryDatabase() + user_version migrations      // §2.3: in place
        failure → strings.boot.failedTitle / failedBody + Retry (shown even if b/c are pending)
     b. household session = ExpoCompatibleKeychain.read("household.session.v1") → decode (§4.2 rules)
        (any throw → nil, i.e. "not paired", exactly like RN; that is why step 0 matters)
     c. onboarding = UserDefaults "onboarding.completed.v1" == "true"
  3. Gate the UI until a, b, c have all resolved (same as app/_layout.tsx:154).
  4. After the UI is up, and only if SYNC_URL is configured (SyncProvider.tsx:75):
     account = ExpoCompatibleKeychain.read("sync.accountSecret.v1") (§4.2); if present, sync pass on foreground (sync area).
  5. Optional, low priority, background queue: purge Caches/{ImageManipulator,Camera,ImagePicker} and Caches/label-*.png (§3.5).
```

Invariants:
- Never delete, rename or rewrite the database file, the photos, the keychain items or the AsyncStorage directory during adoption.
- Every photo path goes through `PhotoPathResolver` (§3.3).
- **TestFlight rollback compatibility.** Testers can install an older RN build over the native one, so while both coexist:
  - native writes keychain items with the Expo coordinates;
  - native writes photo URIs in shape 1;
  - native keeps the SQLite schema readable by the last RN build. Bumping `user_version` past 7 needs coordination: an RN build at 7 would skip every migration and run against an unknown schema. This belongs to the database area.

---

## 9. iOS project configuration for the native target

The `ios/` folder is gitignored and generated (`.gitignore:51`). EAS Build re-runs prebuild in the cloud from `app.json` and the plugins, so the shipped settings are `app.json` plus Expo defaults. The local `ios/` (generated 2026-07-24 21:57, the same minute as the last `app.json` change) reflects them.

### 9.1 Identity and signing

| Setting | RN value | Native target |
|---|---|---|
| Bundle id | `com.wystudio.inventory` (`app.json:13`; `PRODUCT_BUNDLE_IDENTIFIER`, `ios/Inventory.xcodeproj/project.pbxproj:263`) | **identical** |
| Team / App ID prefix | EAS-managed credentials (not in the repo) | **identical team** (keychain access group, §4.3) |
| Product name / display name | `Inventory` (`project.pbxproj:264`; `CFBundleDisplayName`, `ios/Inventory/Info.plist:9-10`) | `Inventory` |
| App Store Connect app | `ascAppId: 6795274058` (`eas.json:42-47`) | same app record |
| EAS project | `extra.eas.projectId 8c2fe54e-a90e-43ef-ad56-5905d4f8905e`, owner `wa1id` (`app.json:70-76`) | only relevant if EAS keeps building (§12 Q2) |

### 9.2 Version and build number

- `CFBundleShortVersionString` = `app.json` `"version": "0.1.0"` (`app.json:5`; hard-coded in `Info.plist:21-22`). `MARKETING_VERSION = 1.0` in the pbxproj is unused because the plist does not reference it. In-app, Settings and Privacy show `Constants.expoConfig.version` (`src/services/appInfo.ts:4`), i.e. the `app.json` value, not the bundle. Native should read `CFBundleShortVersionString`.
- `CFBundleVersion`: `app.json` `buildNumber: "1"` (`app.json:14`) is **ignored**, because `eas.json` has `cli.appVersionSource: "remote"` (`eas.json:2-5`) and production has `autoIncrement: true` (`eas.json:31`). EAS stores the iOS build number on its servers and increments it every production build. Only the build number is remote. The version string stays local (`app.json`).
- Native: use `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` in Info.plist. The **first native upload needs a build number greater than the last EAS-uploaded build** for the same version (query with `eas build:version:get -p ios`, or look in TestFlight). For an App Store release it also needs a version greater than the live one (§12 Q1).

### 9.3 Platform, devices, capabilities (App Store update constraints)

- Deployment target: RN `IPHONEOS_DEPLOYMENT_TARGET = 16.4` (`project.pbxproj:251,281`; `Podfile` `platform :ios, '16.4'`). Native: **26.0** (decided). Devices on iOS 16.4–25 stay on the last RN version, with their data untouched.
- Device family: `TARGETED_DEVICE_FAMILY = "1,2"` (`project.pbxproj:269`), from `supportsTablet: true` (`app.json:12`). **Keep iPhone and iPad.** App Store Connect rejects an update that drops a device family the previous version supported.
- `UIRequiredDeviceCapabilities = [arm64]` (`Info.plist:60-63`). **Keep exactly this.** An update may not add more restrictive required capabilities (for example `still-camera`).
- Swift: Swift 6 language mode, complete strict concurrency (the RN template had `SWIFT_VERSION = 5.0`).
- No app extensions, widgets, App Clips or watch app exist today.

### 9.4 Info.plist, key by key (`ios/Inventory/Info.plist`)

| Key | RN value (line) | Native |
|---|---|---|
| `CFBundleDisplayName` | `Inventory` (9-10) | keep |
| `CFBundleDevelopmentRegion` | `$(DEVELOPMENT_LANGUAGE)` (7-8) | keep (en; copy is English-only) |
| `CFBundleShortVersionString` / `CFBundleVersion` | `0.1.0` / `1` (21-22, 35-36) | `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` (§9.2) |
| `CFBundleURLTypes` | one entry, schemes `inventory`, `com.wystudio.inventory` (25-34) | **keep `inventory` (required, §9.6)**. `com.wystudio.inventory` was auto-added by Expo and no code uses it. Keeping it is harmless (§12 Q7) |
| `ITSAppUsesNonExemptEncryption` | `false` (37-38; `app.json:18`) | keep |
| `LSRequiresIPhoneOS` | `true` (41-42) | keep |
| `LSMinimumSystemVersion` | `12.0` (39-40) | drop (macOS key from the Expo template) |
| `CFBundleSignature` | `????` (23-24) | drop (obsolete) |
| `NSAppTransportSecurity` | `NSAllowsArbitraryLoads=false`, `NSAllowsLocalNetworking=true` (43-49) | Every production origin is https (`eas.json:34-35`; household `https://inventory.wystudio.be`, `src/services/config.ts:72-74`; `home-server/src/index.ts:53`). Keep `NSAllowsLocalNetworking` at least in Debug for LAN dev servers (§12 Q7) |
| `NSCameraUsageDescription` | "Inventory uses the camera so you can photograph items you are adding and scan QR labels on your containers." (50-51; `app.json:16, 55`; not a `strings.ts` key) | keep **exactly** |
| `NSPhotoLibraryUsageDescription` | "Inventory can import a photo from your library to illustrate an item you are adding." (52-53; `app.json:17, 63`) | **keep.** Import through `PhotosPicker` / PHPicker does not need it, but the QR label share sheet offers **Save Image** for the label PNG (`app/container/[id]/qr.tsx:202-232`, `07-screens-entities.md` §5.3), which writes to the photo library. Today that key is what covers the write; without it (and without `NSPhotoLibraryAddUsageDescription`) iOS may terminate the app on Save Image. Verify on device before ever removing it |
| `NSMicrophoneUsageDescription` | **absent**. The expo-image-picker plugin would add a default one (`node_modules/expo-image-picker/plugin/build/withImagePicker.js:8, 48-57`), and expo-camera's `microphonePermission: false` (`app.json:56`) deletes it | keep absent |
| `NSFaceIDUsageDescription` | **absent** (`expo-secure-store` `faceIDPermission: false`, `app.json:49`) | keep absent |
| `NSUserActivityTypes` | `$(PRODUCT_BUNDLE_IDENTIFIER).expo.index_route` (54-57) | drop (expo-router handoff) |
| `UILaunchStoryboardName` | `SplashScreen` (58-59) | replace with a `UILaunchScreen` dict (§9.8) |
| `UIRequiredDeviceCapabilities` | `[arm64]` (60-63) | keep exactly |
| `UIRequiresFullScreen` | `false` (64-65) | keep or omit. `false` is the system default, so both allow iPad multitasking. Never set `true` |
| `UISupportedInterfaceOrientations` | Portrait, PortraitUpsideDown (68-72; `app.json:6` `orientation: portrait`) | keep (iPhone is portrait-only) |
| `UISupportedInterfaceOrientations~ipad` | all four (73-79) | keep (required with `UIRequiresFullScreen=false`) |
| `UIUserInterfaceStyle` | `Automatic` (80-81; `app.json:9`) | keep or omit (the default) |
| `UIStatusBarStyle`, `UIViewControllerBasedStatusBarAppearance=false` | (66-67, 82-83) | drop (SwiftUI owns the status bar) |
| `CADisableMinimumFrameDurationOnPhone` | `true` (5-6) | optional (120 Hz for custom animations) |
| `UIDesignRequiresCompatibility` | absent | **must stay absent** (Liquid Glass on iOS 26) |
| `UIBackgroundModes`, `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`, `RCTAsyncStorageExcludeFromBackup` | absent | keep absent |

`ios/Inventory/Supporting/Expo.plist` (`EXUpdatesEnabled=false`, etc.) belongs to expo-updates, which is not installed. Drop it.

### 9.5 Entitlements

`ios/Inventory/Inventory.entitlements` is `<dict/>`: no associated domains, no app groups, no keychain groups, no push, no iCloud, no data-protection override. Native: **empty** as well (keychain §4.3, files §1).

### 9.6 URL scheme and deep links

- Scheme `inventory` (`app.json:8`). Printed QR labels encode `inventory://c/<32 hex>` (`src/repositories/qr.ts:29-33`), so the iPhone Camera app opens the app on route `c/[token]` (`app/c/[token].tsx:29-31`). Parsing: trim, strip the prefix if present, accept `/^[0-9a-f]{32}$/i`, lowercase (`qr.ts:41-46`). **Labels already in the world depend on this scheme. It can never be dropped.** A cold-start deep link gets Home underneath it (`app/_layout.tsx:37`). Handle with `.onOpenURL` (deep-link/QR area).
- Universal links: the AppDelegate forwards `continue userActivity` (`ios/Inventory/AppDelegate.swift:43-51`), but there is no associated-domains entitlement, so no universal links exist. The native app needs none.

### 9.7 Background execution

There are no `UIBackgroundModes` and no BGTaskScheduler. Backup and photo sync run on foreground and app-active only (`SyncProvider.tsx:112-123`). Matching that requires no capability.

### 9.8 App icon, launch screen, accent colour

- Icon: one universal 1024×1024 PNG with no alpha (`ios/Inventory/Images.xcassets/AppIcon.appiconset/Contents.json`), generated from `assets/icon.png` (`app.json:7`; 1024×1024, PNG colour type 2 = RGB). **The artwork is the stock Expo template icon** (blue chevron on a blueprint grid; `assets/icon.png` has not changed since the first commit 67185d8). Native: single-size AppIcon, or an Icon Composer `.icon` for Liquid Glass (§12 Q8).
- Launch screen: `SplashScreen.storyboard` is an empty `systemBackgroundColor` view with an image named `SplashScreen` that is not in the asset catalog. `expo-splash-screen` is not installed, so users see a blank system background. Native: a `UILaunchScreen` dict, empty (system background) or with `UIColorName`. Fully native look: plain system background.
- Accent colour: **which colour is "the brand accent" is an open user decision** (`08-design-i18n-platform.md` §4.1 / Q3; also 06 Q7, 07 Q8, 09 Q18). The design has two brand colours: **ink** `#1C211E` / `#E8ECE8` (today's interactive tint) and label-tape **yellow** `#FFD23F` (light) / `#F4CA3C` (dark) (`src/ui/tokens.ts:40, 77`; camera accent `#FFD23F`, `tokens.ts:125`). 08 recommends `AccentColor` = ink plus a named `Tape` colour for the tape, mark, badge and camera accent, because yellow as a control tint fails contrast (about 1.4:1 on white). This target only needs an `AccentColor` asset with light and dark appearances once that decision is made. *(Consistency pass: this bullet previously stated yellow as decided.)*

### 9.9 Privacy manifest

The local, never-`pod install`ed `ios/` has no app-level `PrivacyInfo.xcprivacy`, but **the shipped RN binary does**. The generated Podfile enables RN's privacy-manifest aggregation by default (`ios/Podfile:58`, `privacy_file_aggregation_enabled => … != 'false'`). During `pod install` on EAS, `PrivacyManifestUtils.add_aggregated_privacy_manifest` creates `Inventory/PrivacyInfo.xcprivacy` next to `Info.plist`, adds it to the app target, and fills it with `NSPrivacyTracking = false`, empty `NSPrivacyCollectedDataTypes`, and the union of every pod's accessed-API reasons plus RN core's (`node_modules/react-native/scripts/cocoapods/privacy_manifest_utils.rb:7-50, 96-116, 156-171`; `scripts/react_native_pods.rb:585-588`). The sources of that union:
- RN core: FileTimestamp C617.1, UserDefaults CA92.1 (`node_modules/react-native/React/Resources/PrivacyInfo.xcprivacy`), SystemBootTime 35F9.1 (`ReactCommon/react/timing/PrivacyInfo.xcprivacy`, also hard-coded in `get_core_accessed_apis`).
- AsyncStorage: C617.1.
- expo-file-system: FileTimestamp 0A2A.1 / 3B52.1, DiskSpace E174.1 / 85F4.1.
- expo-constants and expo-system-ui: UserDefaults CA92.1.

The live app's App Store privacy answers were made against that aggregated manifest. The native manifest below declares less (no 35F9.1, 0A2A.1, 3B52.1 or 85F4.1 unless used), and that is allowed.

The native app needs its own `PrivacyInfo.xcprivacy` declaring what it actually calls:
- `NSPrivacyAccessedAPICategoryUserDefaults`: **CA92.1** (preferences, §5.4).
- `NSPrivacyAccessedAPICategoryDiskSpace`: **E174.1** (free-space check before writing a photo, `imageStore.ts:201-207`).
- `NSPrivacyAccessedAPICategoryFileTimestamp`: **C617.1**, only if cache cleanup reads file dates.
- `NSPrivacyAccessedAPICategorySystemBootTime`: **35F9.1**, only if durations use `systemUptime` / `mach_absolute_time`. RN telemetry uses `Date.now()`.
- `NSPrivacyTracking = false`, no tracking domains.
- Collected data types need an owner decision (§12 Q15): photos go to the recognition backend, opt-in backups upload the database and photos, and household sync goes to the home server.

Check whether GRDB's SPM package ships its own manifest.

### 9.10 Build configurations and environment (eas.json → xcconfig)

| EAS profile (`eas.json`) | Distribution | Env |
|---|---|---|
| `development` (7-20) | internal, `developmentClient: true` (but `expo-dev-client` is not in `package.json`, so this builds a plain debug app), `ios.simulator: false` | `EXPO_PUBLIC_ENV=development` |
| `preview` (21-29) | internal (ad hoc) | `EXPO_PUBLIC_ENV=preview` |
| `production` (30-40) | store, `autoIncrement: true` | `EXPO_PUBLIC_ENV=production`, `EXPO_PUBLIC_RECOGNITION_URL=https://server-wy-studio.vercel.app/api/recognize`, `EXPO_PUBLIC_SYNC_URL=https://inventory-sync.wyachou95.workers.dev` |

Every config key and its normalisation (`src/services/config.ts:59-76`). Each is an `EXPO_PUBLIC_<NAME>` variable, and all but `HOUSEHOLD_ORIGIN` are listed in `.env.example`. Native should put these in per-configuration `.xcconfig` → custom Info.plist keys → an `AppConfig` struct:
- `RECOGNITION_URL`: trim, empty → nil.
- `RECOGNITION_KEY`: trim, empty → nil. **Not in `eas.json`**; source unknown (§12 Q16).
- `RECOGNITION_TIMEOUT_MS`: `Number(value ?? 15000)`. The fallback applies only when the variable is **unset**. Set but empty gives `Number("") = 0`, and non-numeric gives `NaN`. Native: treat empty or unparsable as the default, and flag it as an intentional difference.
- `SYNC_URL`: trim, strip trailing `/+`, empty → nil.
- `SYNC_KEY`: trim, empty → nil. Not in `eas.json`.
- `SYNC_TIMEOUT_MS`: `Number(value ?? 60000)`, with the same unset/empty caveat.
- `HOUSEHOLD_ORIGIN`: trim, strip trailing `/+`, empty → default `https://inventory.wystudio.be`. Not in `.env.example` or `eas.json`, so every shipped build uses the default.
- `ENV`: `production` | `preview`, else `development`.

These values ship inside the bundle and are public by design (`config.ts:21-28, 39-47`).

---

## 10. RN/Expo workarounds the native app does not need

| RN code | Why it exists | Native replacement |
|---|---|---|
| Lazy `await import('expo-file-system' / async-storage)` (`photoCache.ts:8-18`, `categoryMemory.ts:39-43`, `recognition.ts:33-37`, `importHousehold.ts:28-29`) | Keep native modules out of Node Jest | Plain dependencies behind protocols |
| `adopt()` reads the size before `move` "because move retargets the handle" (`imageStore.ts:81-84`). The `move` (and `photoCache`'s `copy`) are un-awaited Promises (§3.1) | expo-file-system `File` handle semantics (`FileSystemPath.swift:81-92`). In expo-file-system 57.0.1, `move` and `copy` are async (`moveSync` and `copySync` are the blocking variants) | Synchronous `FileManager.moveItem` / `copyItem` with errors propagated, + `attributesOfItem[.size]` |
| Encode into Caches, then move to Documents (`imageStore.ts:70-87`) | `ImageManipulator.saveAsync` always writes to Caches | Encode straight to a temp file in `item-photos/` and replace atomically (keep the names) |
| QR label PNG via `react-native-svg` `toDataURL` + base64 write + 4 s timeout (`labelImage.ts:17-51`) | No native QR rasteriser in JS | `CIFilter.qrCodeGenerator` / `ImageRenderer` + `ShareLink` with a `Transferable` image. No cache file needed |
| Household photos rewritten to `file://` cache URIs so `<Image>` can show them (`photoCache.ts:3-6`, `httpRepositories.ts:88-121`) | RN `<Image>` wants a URI | Any image pipeline with a disk cache (keep the cache directory if reused) |
| expo-secure-store's three-service probe and JSON-in-string values | Library generality | `ExpoCompatibleKeychain` (§4.3), same coordinates |
| AsyncStorage (strings only, async, manifest file) | RN has no synchronous native preferences store | `UserDefaults` / `@AppStorage` after the one-time import |
| `SystemUI.setBackgroundColorAsync` (`app/_layout.tsx:113-115`) | Stop white flashes behind RN modals | Nothing (SwiftUI) |
| `configureRandomBytes(Crypto.getRandomBytes)` at module load (`DatabaseProvider.tsx:13-15`) | Inject a CSPRNG into shared TS | `SystemRandomNumberGenerator` / `SecRandomCopyBytes` |
| `PRAGMA wal_checkpoint(TRUNCATE)` before serialize | **Still needed** natively (a snapshot must include the WAL contents) | Same SQL via GRDB `checkpoint(.truncate)` inside `writeWithoutTransaction`. RN had a single connection, so the checkpoint could never be blocked; the recommended single `DatabaseQueue` keeps that property. (In a `DatabasePool`, open readers can make a TRUNCATE checkpoint return `SQLITE_BUSY` or leave WAL frames behind; it would need `barrierWriteWithoutTransaction`.) `VACUUM INTO` is an alternative (sync area) |

---

## 11. Tests

### 11.1 Existing TS tests to port (Swift Testing)

Mocks used by these tests:
- the keychain: in-memory map with fail-next-read and fail-next-write switches (`identity.test.ts:11-40`);
- AsyncStorage: an in-memory `Map` (`recentPlaces.test.ts:9-19`, `backup.test.ts:15-28`, `useRecentPlaces.test.tsx:6-16`);
- the photo store: a `Map` keyed by URI (`photoSync.test.ts:15-34`).

Port them as Swift protocols (`SecureStoring`, `PreferenceStoring`, `PhotoStoring`) with in-memory fakes.

`src/services/account/__tests__/identity.test.ts`:
- *cross-implementation vectors / encodes a known secret…*: 16×`0x42` encodes to `89144GJ289144GJ289144GJ288`.
- *…derives the account id the service derives*: the same secret gives `900dfeb7f1b5e344209e2abce56c333d`.
- *recovery code encoding / round-trips random secrets*: 50 random 16-byte secrets.
- *…survives the transcription mistakes*: formatted in groups of 5, lowercased, `1→l`, `0→o`, decodes to the same bytes.
- *account lifecycle / reports no account on a device that has never had one*.
- */ creates an account and finds it again*: code length 26, and load equals create.
- */ gives different devices different accounts*.
- */ adopts an account from a code typed in any reasonable shape*: same id, and the persisted code is canonical.
- */ refuses a code that decodes to too few bytes*: `'89144'` gives malformed, and nothing is stored.
- */ refuses a code containing characters outside the alphabet*: `'U'×26` gives malformed.
- */ reports an unwritable keystore…*: write failure gives `unavailable`.
- */ treats a keystore read failure as no account, not a new one*.
- */ forgets an account without touching anything else*.

`src/services/places/__tests__/recentPlaces.test.ts`:
- *mergeRecent / puts the place first*.
- */ moves a place already in the list to the front instead of repeating it*.
- */ keeps at most six*: `MAX_RECENT_PLACES == 6`; with explicit max 3 it gives `['g','a','b']`.
- */ never stores the drop zone*.
- *rememberPlace / persists the merged list and reads it back*: after a, b, drop-zone, a, the result is `['a','b']`, and storage under `places.recent.v1` holds `["a","b"]`.

`src/hooks/__tests__/useRecentPlaces.test.tsx`, *takes the stored list, then holds it while the screen stays open*:
- with stored `["a","b","c"]`, the open screen shows a, b, c;
- after `rememberPlace('b')` the open screen is unchanged;
- a new screen shows `['b','a','c']`.

`src/ui/components/__tests__/textHelpers.test.tsx`:
- *suggestCategories / offers known categories that start with what is typed, once each*: `'to'` gives `['Tools','Toys','Towels']`.
- */ hides an exact match and caps the list at six*.

`src/services/sync/__tests__/backup.test.ts`, the preference-related assertions:
- *runBackup / reports failure without recording a backup time*: the preferences store stays empty.
- *maybeBackup / backs up when nothing has been backed up yet*: no stored `sync.lastBackupAt.v1` means `lastBackupAt()` is `null`, so the result is non-null and one upload happens.
- */ skips a backup taken too recently*: `capturedAt` 1000 is recorded, and `now = 1000 + 15 min − 1` gives `null` with still one upload.
- */ backs up again once the interval has passed*: `now = 1000 + 15 min + 1` gives two uploads.

The other 8 cases in that file (snapshot, checksum, too large, restore, newer schema) belong to the sync area.

`src/services/sync/__tests__/photoSync.test.ts`, path-sensitive cases:
- *uploadPendingPhotos / drops a row whose local file has vanished rather than retrying forever*.
- *rehydrateMissingPhotos / pulls back files that a restore left behind, re-pointing the row*: the row ends with the same `uri` and `thumb_uri` (`file:///documents/item-photos/<id>.webp` / `-thumb.webp`) and `byte_size` 4.
- */ leaves photos alone when the local file is present*.
- */ skips a photo missing remotely instead of stalling the pass*.

The other 9 cases belong to the sync area.

`src/db/__tests__/persistence.test.ts`:
- *migrations*: 6 cases (latest version, idempotent, upgrade from v1 with `search_text` backfilled to `'legacy drill'`, value columns dropped, quantity-0 rebuild keeps photos and tags with FKs back ON and an empty `foreign_key_check`, and versions equal index + 1).
- *data durability / keeps inventory after closing and reopening the database file*.

`src/db/__tests__/nodeDatabase.test.ts`:
- *reopens a file and still has the rows*;
- *round-trips an in-memory snapshot*;
- *round-trips a snapshot through restore*.

`src/ui/add/__tests__/addDraft.test.ts`, photo-file ownership (4 cases):
- a stale draft (> 30 min) deletes both files;
- a replaced draft deletes its photo unless the new one carries it.

There are **no existing tests** for `session.ts`, `onboarding.ts`, `importOffer.ts`, `unpairedNotice.ts`, the categoryMemory persistence, `photoCache.ts`, `imageStore.ts`, `labelImage.ts` or `expoDatabase.ts`.

### 11.2 New Swift tests this area needs

1. `LegacyAsyncStorageReader`:
   - inline string value;
   - `null` value with an overflow file;
   - `null` value with the file missing → absent;
   - `null` value with an overflow file that exists but is unreadable or not UTF-8 → throws `unreadableValue` (it is not treated as absent);
   - missing manifest → `[:]`;
   - unparsable manifest → `[:]`;
   - non-UTF-8 manifest → throws;
   - escaped slashes `\/` decode;
   - `md5Hex` equals the 7 vectors in §5.3.
2. `LegacyImport`:
   - imports the 7 keys verbatim;
   - ignores unknown keys;
   - never overwrites an existing native value;
   - leaves the marker unset when the reader throws (including `unreadableValue`);
   - leaves the marker unset and reads nothing while protected data is unavailable (inject the check);
   - is a no-op once the marker is set;
   - removes `ExpoSystemUI.backgroundColor`.
3. `ExpoCompatibleKeychain`:
   - the query dictionary has exactly 4 keys, `Data` account and generic, service `app:no-auth`;
   - write then read round-trip (simulator host app);
   - a second write takes the update path;
   - delete removes every variant;
   - an item pre-seeded under service `app` is still read.
4. Preference decoders, matching §5.3 exactly:
   - `lastBackupAt`: `"" → nil`, `"abc" → nil`, `" 1754236800000 " → 1754236800000`;
   - `importOffer`: `{"spaces":1,"items":"2"} → nil`;
   - onboarding: only `"true"`;
   - notice: only `"1"`;
   - places: `[1,"a"] → ["a"]`, capped at 6, `{"a":1}` → `[]`;
   - categories: `{"a":1}` → ignored. `[" Tools ","tools",2,"","Toys"]` → `["Tools","Toys"]` (trimmed, case-insensitive dedupe, non-strings and empties dropped), capped at 20.
5. `HouseholdSession` decode: missing `deviceName` → `"This phone"`, missing `householdName` → `"Home"`, missing `token` → nil, `deviceId` a number → nil, invalid JSON → nil. Encode: keys in the order `origin, token, deviceId, deviceName, householdName`.
5a. `hasRoomForPhoto` parity: free-space reading nil → `false`, a throw → `true`, `2_000_001` bytes → `true`, `2_000_000` → `false` (strict `>`).
5b. `storeItemPhoto` (native): a failing move makes the call throw, and no row is created. The two files are `<id>.webp` and `<id>-thumb.webp` in `Documents/item-photos/`.
6. `PhotoPathResolver`:
   - same-container hit;
   - rebased `item-photos` hit (old container UUID);
   - rebased `household-photos` hit;
   - `r2:` → nil;
   - Android path whose file exists under the current `item-photos` → hit;
   - Android path with no file → nil;
   - percent-encoded simulator path;
   - `storedURI` equals `URL.documentsDirectory.appending(path:"item-photos/x.webp").absoluteString`.
7. Database adoption: copy a fixture `inventory.db` produced by expo-sqlite at `user_version` 4 together with a non-empty `-wal`, open it with `openInventoryDatabase()`, and assert that the WAL rows are visible and the migrations reach 7. Generate the fixture once from the RN app on a simulator.
8. Rebuild-migration safety (§2.3 rule 6): a fixture at `user_version` 6 with one item that has an `item_photos` row and an `item_tags` row. After migrating to 7, both child rows still exist, `PRAGMA foreign_keys` is back to 1, and `PRAGMA foreign_key_check` is empty. This mirrors the TS test *keeps photos and tags when quantity 0 becomes allowed* (`src/db/__tests__/persistence.test.ts:91`).

---

## 12. Open questions

1. **What is live?** Is the RN app on the App Store or only in TestFlight, and at which version and build? This decides `MARKETING_VERSION` and whether MVP-era `.jpg` photos (§3.1) exist on user devices.
2. **Who builds and signs native?** EAS (`appVersionSource: remote` + `autoIncrement` keep working) or Xcode Cloud / fastlane (the remote build number must be read first, and EAS-managed credentials exported or re-created). The Team ID must stay the same.
3. **Backup inclusion of preferences:** accept `UserDefaults` (backed up, an improvement) or keep strict parity with a backup-excluded JSON file (§5.4)?
4. **Self-heal stale photo URIs** in SQLite when the resolver rebases, or resolve at read time only? Both are safe. Self-heal makes backups carry current paths.
5. **Orphan sweep of `Documents/item-photos/`** (drafts or failed saves, §3.1): add one, carefully (only names not referenced by any `uri`/`thumb_uri` last path component, older than N days), or keep RN behaviour (never)?
6. **When to delete the RN artifacts** (`RCTAsyncLocalStorage_V1/`, Caches temporaries)? Keeping them preserves TestFlight rollback. Suggest deleting the AsyncStorage directory one release after native GA.
7. **Info.plist trims:** drop the `com.wystudio.inventory` URL scheme and `NSAllowsLocalNetworking` in Release? Neither is used by production code paths.
8. **App icon:** the shipped icon is the Expo template placeholder. Is there real artwork, and should it be a Liquid Glass `.icon`?
9. ~~**Photo-library usage string:** keep it if the native import uses `PhotosPicker`, which does not need it?~~ **Keep it** (consistency pass): the label share sheet's Save Image writes to the photo library (§9.4 row). Not a user decision unless the share flow changes.
10. **Keychain accessibility:** if native adds background tasks (BGAppRefresh backups), `WhenUnlocked` items cannot be read while the device is locked. Should they be migrated to `AfterFirstUnlock` with `SecItemUpdate`? RN does not care about accessibility on reads.
11. **SQLite `synchronous`:** confirm GRDB's default in WAL, and whether to force FULL for parity with RN.
12. **Snapshot API:** is `sqlite3_serialize` exported by the iOS 26 SDK's system SQLite? If not, use backup-to-memory or `VACUUM INTO` (sync area).
13. **iOS < 26 users** stay on the RN build: household and server APIs must stay backward compatible for them (owner confirmation).
14. **iPad:** the update cannot drop iPad. Confirm the native UI ships an acceptable iPad layout.
15. **Privacy manifest collected-data declarations** and parity with the App Store privacy label.
16. **Where do production `EXPO_PUBLIC_RECOGNITION_KEY` / `EXPO_PUBLIC_SYNC_KEY` come from** (EAS environment variables?) so native CI can inject them? A local `.env.local` exists, but it is gitignored (`.gitignore:42, 53`), there is no `.easignore`, and EAS archives the project by `.gitignore`. So EAS cloud builds never saw it. If no EAS environment variables are set, shipped builds have neither key.
17. **Prewarm / pre-first-unlock launches:** confirm the native app never reads the keychain or `manifest.json` before `isProtectedDataAvailable` (§8 step 0). RN had the same exposure, and a failed session read silently looks like "not paired".

---

## 13. Dependencies on other areas

- **Database/schema:**
  - the exact `user_version` runner (no GRDB `DatabaseMigrator`) and the `rebuild` foreign-key toggling, which must run outside a transaction or v≤6 devices lose all photo and tag rows (§2.3 rule 6);
  - schema compatibility with the last RN build while TestFlight overlap exists;
  - the WAL and foreign-key pragmas (§2.2).
- **Sync/backup:**
  - snapshot (`wal_checkpoint(TRUNCATE)` + serialize) and restore (deserialize + backup API + migrate) (§2.2);
  - the `sync.lastBackupAt.v1` preference;
  - the `sync.accountSecret.v1` keychain item;
  - **`photoSync` must use `PhotoPathResolver`** (§3.3).
- **Household:**
  - the `household.session.v1` keychain item;
  - the `household.joinedBefore.v1` and `household.importOffer.v1` preferences;
  - the `household-photos` cache naming and `/v1/photos/:id[?thumb=1]`;
  - `r2:` URIs in shadow rows;
  - import reading photos through the resolver.
- **Capture/photos:**
  - the `item-photos/<uuid>.webp` + `-thumb.webp` naming and the shape-1 URI format;
  - native **WebP encoding**: RN encodes with `SDImageWebPCoder` from `SDWebImageWebPCoder` (libwebp), quality = `compress` (`node_modules/expo-image-manipulator/ios/ImageManipulatorUtils.swift:79-80`, podspec dependency). ImageIO historically decodes WebP but cannot encode it, so check iOS 26 or bundle libwebp / SDWebImageWebPCoder via SPM;
  - synchronous file moves (the RN fire-and-forget `move` is a bug not to port, §3.1);
  - the free-space check (E174.1).
- **Onboarding/settings:** the `onboarding.completed.v1` semantics (replay removes the key) and the app version from the bundle.
- **Home:** `notice.unpaired.dismissed.v1`.
- **Item forms and pickers:** `places.recent.v1` (hold-while-open semantics) and `categories.recent.v1`.
- **QR/deep links:** the `inventory://c/<token>` scheme registration.
- **Config/build:** the env keys and normalisation (§9.10).
- **UI:** the `AccentColor` values and the launch screen.

---

## Reviewer notes

An adversarial review re-read every cited source: app code, `node_modules` iOS sources, the generated `ios/`, `app.json`, `eas.json` and the tests. The SecItem coordinates, key hex encodings, the seven MD5 vectors, the SQLite path, the AsyncStorage location and format, the photo naming eras and the Info.plist line map were all independently confirmed. Changes made:

**Corrections**
- §2.2: the `SQLiteOptions.swift` citation was `:15-23` (the libSQL fields). It is now `:5-13`, and adds `finalizeUnusedStatementsBeforeClosing = true`. FULL `synchronous` is now cited to the vendored `sqlite3.c:17833-17838`.
- §3.1: the order of the write steps is fixed (delete destination, then read size, then move, per `imageStore.ts:78-84`).
- §3.1: the free-space check was wrong for a nil reading. expo returns nil when the attributes cannot be read, and `null > n` is `false`, so RN says "no room". The suggested native API is now marked as a behaviour change.
- §4.1: the `requireAuthentication` default is now cited to `expo-modules-core/.../FieldExtensions.swift:30-33`. The reason `app:auth` cannot exist is corrected: the primary reason is that no call site passes the option. The plist-key argument is secondary, and pre-14aa749 builds probably shipped `NSFaceIDUsageDescription`.
- §5.4 reader: an overflow file that **exists but is unreadable** used to be silently treated as absent, and the import marker was then set, which would permanently lose `categories.recent.v1`. RN reports an error in that case (`RNCAsyncStorage.mm:82-110, 688-697`). The reader now throws, and the import now also waits for `isProtectedDataAvailable`.
- §5.3: `household.importOffer.v1` is also removed on leaving the household (`app/household.tsx:226`).
- §6: the `RCTI18nUtil` keys are not debug-only. They are written only if `I18nManager` RTL setters are called, which the app never does.
- §8: gate line citations corrected (`app/_layout.tsx:154-156`, was `:153`). The DB error screen takes precedence over the loading gate.
- §9.9: "the RN app has no `PrivacyInfo.xcprivacy`" was only true of the local, never-`pod install`ed project. RN's default privacy-manifest aggregation (`ios/Podfile:58`, `privacy_manifest_utils.rb`) generates one in every EAS build. Added RN's SystemBootTime 35F9.1.
- §9.10: `HOUSEHOLD_ORIGIN` is not in `.env.example`. `Number(env ?? default)` gives `0` or `NaN` for set-but-empty or garbage values. The `config.ts` line range is now `:59-76`, and in §9.4 the household-default citation is now `:72-74`.
- §11.1: the `recentPlaces.test.ts` mock citation was `:161-171` in a 52-line file. It is now `:9-19`. Added the missed backup test *backs up when nothing has been backed up yet*.
- §7: the `addDraft.ts` slot line is `:23`. `expo-font` here loads at runtime from bundled assets; it is not plugin-embedded.

**Additions**
- §2.3 rule 6 and test 8: if the native runner toggles `foreign_keys` inside a GRDB transaction, the pragma does nothing and migration 7's `DROP TABLE items` cascade-deletes every photo and tag row on devices at v≤6.
- §2.3 rule 5: GRDB `DatabasePool` may force `synchronous = NORMAL` after `prepareDatabase`. Shows how to restore FULL.
- §3.1, §3.4, §10: in expo-file-system 57.0.1, `File.move()`/`copy()` are async, and the RN code never awaits them (`imageStore.ts:84`, `photoCache.ts:68`). That gives a fire-and-forget move, silent failures, orphans and rows pointing at missing files. Native must move synchronously.
- §3.3: `rehydrateMissingPhotos` re-points only synced rows. Shadow `r2:` rows are retried against the worker on every pass.
- §3.1: thumbnail display falls back only on a NULL column, and the full screen prefers `uri`.
- §1, §4.4, §8 step 0, §12 Q17: Data Protection and `WhenUnlocked` mean adoption must wait for protected data. A failed session read looks like "not paired".
- §4.2: `loadAccount` runs at mount only when `SYNC_URL` is set. Session `origin`/`deviceName` normalisation. Exact base32 decoder folding.
- §5.2: the manifest serialisation options. §5.3: the `lastBackupAt` integer write format and the `categoryMemory` load/write race.
- §9.4: why `NSMicrophoneUsageDescription` is absent (image-picker default overridden by expo-camera).
- §9.10: the dev profile has no `expo-dev-client`. §12 Q16: `.env.local` is gitignored, so EAS never saw it.
- §10: a TRUNCATE checkpoint under a `DatabasePool` needs a barrier.
- §13: RN's WebP encoder is SDWebImageWebPCoder/libwebp.
- §11.2: new tests for the unreadable overflow file, the categories and places decoders, session encode order, `hasRoomForPhoto` parity, synchronous store failure, and the v6 to v7 FK-safety fixture.

**Completeness / consistency pass (cross-spec critic)**
- §2.3 recipe and rule 5, §10: switched from `DatabasePool` to a single `DatabaseQueue`, matching `01-data.md` §2.2 (which already recommended it) and the RN single connection. This removes the checkpoint-barrier and `synchronous = NORMAL` concerns; `synchronous = FULL` is now set in `prepareDatabase`. 03 and 09 were aligned to the same decision.
- §4.3 is now the single canonical keychain recipe: read `app:no-auth`, then legacy `app` (skipping `app:auth`, which cannot exist). 04 §5 and 09 §3.1 / §14.2 previously required the full three-service probe as a MUST; they now defer to this section.
- §3.3 is the single canonical photo resolver. 05 §9.7 described a different algorithm (`PhotoLocation`, rebasing the suffix after the last `/Documents/`), which would miss Android-restored paths (`…/files/item-photos/…`, shape 4 in §3.2). 05 now defers to `PhotoPathResolver`. 09 claimed this section forbids rewriting rows; it does not (self-heal stays open as Q4), and 09 was corrected.
- §9.4 / Q9: keep `NSPhotoLibraryUsageDescription` because the label share sheet exposes Save Image (08 §2.7 aligned).
- §9.8: the accent colour was stated as tape yellow; it is an open decision (08 Q3, which recommends ink as `AccentColor` and a named `Tape` colour).
