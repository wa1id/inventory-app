import Foundation
import GRDB
import InventoryCore
import Testing
@testable import InventoryStorage
#if canImport(SQLite3)
import SQLite3
#endif

/// Ports `src/db/__tests__/nodeDatabase.test.ts` and the restore cases of
/// `src/services/sync/__tests__/backup.test.ts:225-275` at the database level (01 §2.5, 03 §5-6).
@Suite("snapshot and restore")
struct SnapshotRestoreTests {
    // MARK: nodeDatabase.test.ts

    @Test("reopens a file and still has the rows")
    func reopensFile() async throws {
        let scratch = try ScratchDirectory()
        let path = scratch.path("inventory.db")
        let first = try await LocalRepositories.initialize(DatabaseStore(path: path))
        let space = try await first.spaces.create(CreateSpaceInput(name: "Garage", icon: "car", color: "#5B8DEF"))
        try first.store.close()

        let second = try await LocalRepositories.initialize(DatabaseStore(path: path))
        #expect(try await second.spaces.getById(space.id)?.name == "Garage")
        try second.store.close()
    }

    @Test("round-trips an in-memory snapshot")
    func roundTripsInMemory() async throws {
        let repos = try freshRepos()
        let space = try await repos.spaces.create(CreateSpaceInput(name: "Loft", icon: "home", color: "#E4572E"))
        let snapshot = try await repos.store.snapshot()

        _ = try await repos.spaces.update(space.id, UpdateSpaceInput(name: "Attic"))
        try await repos.store.restore(from: snapshot)
        #expect(try await repos.spaces.getById(space.id)?.name == "Loft")
    }

    @Test("round-trips a snapshot through restore")
    func roundTripsFile() async throws {
        let store = try DatabaseStore.temporary()
        let repos = try await LocalRepositories.initialize(store)
        let space = try await repos.spaces.create(CreateSpaceInput(name: "Loft", icon: "home", color: "#E4572E"))

        let snapshot = try await store.snapshot()
        #expect(snapshot.prefix(16) == DatabaseStore.sqliteHeader)

        _ = try await repos.spaces.update(space.id, UpdateSpaceInput(name: "Attic"))
        #expect(try await repos.spaces.getById(space.id)?.name == "Attic")

        try await store.restore(from: snapshot)
        let restored = try await LocalRepositories.initialize(store)
        #expect(try await restored.spaces.getById(space.id)?.name == "Loft")
    }

    // MARK: backup.test.ts › restoreBackup

    @Test("brings back data that was deleted after the snapshot")
    func bringsBackDeletedData() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        _ = try await repos.items.create(ItemDraft(containerId: container.id, name: "Cordless Drill"))
        let snapshot = try await repos.store.snapshot()

        try await repos.store.queue.write { db in try db.execute(sql: "DELETE FROM items") }
        #expect(try count(repos.store, "items") == 0)

        #expect(try await repos.store.restore(from: snapshot) == 7)
        let names = try await repos.store.queue.read { db in try String.fetchAll(db, sql: "SELECT name FROM items") }
        #expect(names == ["Cordless Drill"])
    }

    @Test("migrates a snapshot from an older build forward")
    func migratesOlderSnapshot() async throws {
        // A database that only ever saw migration 1, snapshotted by an old build.
        let old = try DatabaseStore.inMemory()
        try await old.migrate(Array(Migration.all.prefix(1)))
        let snapshot = try await old.snapshot()
        #expect(try DatabaseStore.schemaVersion(ofSnapshot: snapshot) == 1)

        let repos = try freshRepos()
        try await seedSpaceAndContainer(repos)

        #expect(try await repos.store.restore(from: snapshot) == Migration.latestSchemaVersion)
        // Restored at v1, then carried forward.
        #expect(try await repos.store.schemaVersion() == Migration.latestSchemaVersion)
        #expect(try await repos.store.queue.read { db in try sqliteMaster(db) } == SqliteMasterFixture.load().rows)
        // The snapshot's data replaced the seeded rows: only the drop zone migration 3 adds.
        #expect(try await repos.spaces.listWithCounts().isEmpty)
    }

    @Test("refuses a snapshot written by a newer build and leaves local data alone")
    func refusesNewerSnapshot() async throws {
        let newer = try DatabaseStore.inMemory()
        try await newer.migrate()
        try await newer.queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA user_version = 8") }
        let snapshot = try await newer.snapshot()
        #expect(try DatabaseStore.schemaVersion(ofSnapshot: snapshot) == 8)

        let repos = try freshRepos()
        let (space, _) = try await seedSpaceAndContainer(repos)

        #expect(throws: SnapshotError.newerSchema(8)) { try repos.store.restore(from: snapshot) }
        #expect(try await repos.store.schemaVersion() == 7)
        #expect(try await repos.spaces.getById(space.id) != nil)
    }

    // MARK: Native additions (03 §5.1, §6.2, B11)

    @Test("restores every historical fixture file as an older snapshot", arguments: 0..<7)
    func restoresHistoricalSnapshots(version: Int) async throws {
        let bytes = try Data(contentsOf: DatabaseFixtures.url("historical/v\(version).db"))
        #expect(try DatabaseStore.schemaVersion(ofSnapshot: bytes) == version)

        let repos = try freshRepos()
        try await seedSpaceAndContainer(repos)
        #expect(try await repos.store.restore(from: bytes) == 7)
        if version >= 1 {
            #expect(try await repos.items.getById("it-drill")?.photoId == "ph-drill")
            #expect(try await repos.items.getById("it-drill")?.tags.count == 2)
        } else {
            #expect(try await repos.spaces.listWithCounts().isEmpty)
        }
        #expect(try pragma(repos.store, "foreign_keys") == "1")
    }

    @Test("puts the previous contents back when migrating the restored snapshot fails")
    func rollsBackFailedMigration() async throws {
        let old = try DatabaseStore.inMemory()
        try await old.migrate(Array(Migration.all.prefix(1)))
        let snapshot = try await old.snapshot()

        let store = try DatabaseStore.temporary()
        let repos = try await LocalRepositories.initialize(store)
        let (space, container) = try await seedSpaceAndContainer(repos)
        _ = try await repos.items.create(ItemDraft(containerId: container.id, name: "Keep me"))
        let before = try await store.queue.read { db in try dumpTable(db, "items") }

        var migrations = Array(Migration.all.prefix(2))
        migrations.append(Migration(version: 3, name: "broken", up: "SELECT nope FROM nowhere;"))
        #expect(throws: DatabaseError.self) { try store.restore(from: snapshot, migrations: migrations) }

        #expect(try await store.schemaVersion() == 7)
        #expect(try await store.queue.read { db in try dumpTable(db, "items") } == before)
        #expect(try await repos.spaces.getById(space.id)?.name == "Garage")
        #expect(try pragma(store, "journal_mode") == "wal")
    }

    @Test("a failed rollback says local data changed instead of surfacing the migration error")
    func reportsFailedRollback() async throws {
        let old = try DatabaseStore.inMemory()
        try await old.migrate(Array(Migration.all.prefix(1)))
        let snapshot = try await old.snapshot()

        let store = try DatabaseStore.temporary()
        let repos = try await LocalRepositories.initialize(store)
        try await seedSpaceAndContainer(repos)

        var migrations = Array(Migration.all.prefix(2))
        migrations.append(Migration(version: 3, name: "broken", up: "SELECT nope FROM nowhere;"))
        struct DiskFull: Error {}
        do {
            try store.restore(from: snapshot, migrations: migrations, rollback: { _, _ in throw DiskFull() })
            Issue.record("expected the restore to fail")
        } catch SnapshotError.rollbackFailed(let detail) {
            #expect(detail.contains("nowhere"))
            #expect(detail.contains("DiskFull"))
        }
        // The snapshot stayed, migrated as far as it got; the next open carries it forward.
        #expect(try await store.schemaVersion() == 2)
        #expect(try await store.migrate() == 7)
        #expect(try await repos.spaces.listWithCounts().isEmpty)
    }

    @Test("a restore into the live WAL file survives closing and reopening it")
    func restoreIsDurable() async throws {
        let scratch = try ScratchDirectory()
        let path = scratch.path("inventory.db")
        let first = try await LocalRepositories.initialize(DatabaseStore(path: path))
        let (space, container) = try await seedSpaceAndContainer(first)
        _ = try await first.items.create(ItemDraft(containerId: container.id, name: "Snapshotted"))
        let snapshot = try await first.store.snapshot()

        // Grow the live file past the snapshot, so the restore also has to shrink it.
        for index in 0..<300 {
            _ = try await first.items.create(ItemDraft(containerId: container.id, name: "Later \(index)", notes: String(repeating: "x", count: 400)))
        }
        _ = try await first.spaces.update(space.id, UpdateSpaceInput(name: "Renamed"))
        #expect(try await first.store.restore(from: snapshot) == 7)
        try first.store.close()

        let reopened = try await LocalRepositories.initialize(DatabaseStore(path: path))
        #expect(try await reopened.items.listByContainer(container.id).map(\.name) == ["Snapshotted"])
        #expect(try await reopened.spaces.getById(space.id)?.name == "Garage")
        #expect(try pragma(reopened.store, "integrity_check") == "ok")
        #expect(try pragma(reopened.store, "journal_mode") == "wal")
        try reopened.store.close()
    }

    @Test("snapshots go through sqlite3_serialize on this platform")
    func serializeIsAvailable() throws {
        let store = try DatabaseStore.temporary()
        try store.migrate()
        let image = try store.queue.writeWithoutTransaction { db in DatabaseStore.serialize(db) }
        let bytes = try #require(image)
        #expect(bytes.prefix(16) == DatabaseStore.sqliteHeader)
        // Header bytes 18-19 say WAL, as in the snapshots the Expo build uploaded.
        #expect(bytes.count > 19 && bytes[18] == 2 && bytes[19] == 2)
    }

    @Test("refuses bytes that are not an SQLite database")
    func refusesGarbage() async throws {
        let repos = try freshRepos()
        try await seedSpaceAndContainer(repos)
        #expect(throws: SnapshotError.notADatabase) { try repos.store.restore(from: Data("hello".utf8)) }
        #expect(throws: SnapshotError.notADatabase) { try repos.store.restore(from: Data()) }

        var damaged = DatabaseStore.sqliteHeader
        damaged.append(Data(repeating: 0xAB, count: 8192))
        #expect(throws: SnapshotError.self) { try repos.store.restore(from: damaged) }
        #expect(try await repos.spaces.listWithCounts().count == 1)
    }

    @Test("a snapshot includes writes still in the WAL and carries the app schema only")
    func snapshotIncludesWal() async throws {
        let store = try DatabaseStore.temporary()
        let repos = try await LocalRepositories.initialize(store)
        try await store.queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA wal_autocheckpoint = 0") }
        let (space, _) = try await seedSpaceAndContainer(repos)

        let snapshot = try await store.snapshot()

        let scratch = try ScratchDirectory()
        let file = scratch.path("copy.db")
        try snapshot.write(to: URL(fileURLWithPath: file))
        let copy = try DatabaseQueue(path: file)
        let (name, version, master) = try await copy.read { db in
            (
                try String.fetchOne(db, sql: "SELECT name FROM spaces WHERE id = ?", arguments: [space.id]),
                try MigrationRunner.userVersion(db),
                try sqliteMaster(db)
            )
        }
        #expect(name == "Garage")
        #expect(version == 7)
        #expect(master == (try SqliteMasterFixture.load().rows))
    }

    @Test("VACUUM INTO gives an equivalent snapshot", arguments: [DatabaseStore.SnapshotMethod.serialize, .vacuumInto])
    func snapshotMethods(method: DatabaseStore.SnapshotMethod) async throws {
        let store = try DatabaseStore.temporary()
        let repos = try await LocalRepositories.initialize(store)
        let (_, container) = try await seedSpaceAndContainer(repos)
        _ = try await repos.items.create(ItemDraft(containerId: container.id, name: "Drill", tags: ["tools"]))

        let snapshot = try store.snapshot(method: method)

        let target = try freshRepos()
        #expect(try await target.store.restore(from: snapshot) == 7)
        #expect(try await target.items.listByContainer(container.id).map(\.name) == ["Drill"])
        #expect(try await target.items.listByContainer(container.id).first?.tags == ["tools"])
    }

    #if canImport(SQLite3)
    @Test("a native snapshot restores the way expo-sqlite restores it: deserialize, then the backup API")
    func expoRestorePath() async throws {
        let repos = try freshRepos()
        let (space, _) = try await seedSpaceAndContainer(repos)
        let snapshot = try await repos.store.snapshot()

        // RN Android: SQLite.deserializeDatabaseAsync(bytes) + backupDatabaseAsync into the live db.
        let source = try DatabaseQueue()
        try await source.writeWithoutTransaction { db in
            let connection = try #require(db.sqliteConnection)
            let size = snapshot.count
            let buffer = try #require(sqlite3_malloc64(sqlite3_uint64(size)))
            snapshot.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { buffer.copyMemory(from: base, byteCount: size) }
            }
            let flags = UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_RESIZEABLE)
            let rc = sqlite3_deserialize(connection, "main", buffer.assumingMemoryBound(to: UInt8.self),
                                         sqlite3_int64(size), sqlite3_int64(size), flags)
            #expect(rc == SQLITE_OK)
        }
        // The Android build's own database: a WAL file with rows of its own.
        let android = try DatabaseStore.temporary()
        let androidRepos = try await LocalRepositories.initialize(android)
        let (otherSpace, _) = try await seedSpaceAndContainer(androidRepos)
        try await source.read { image in
            try android.queue.writeWithoutTransaction { live in try image.backup(to: live) }
        }
        #expect(try await android.migrate() == 7)
        #expect(try await androidRepos.spaces.getById(space.id)?.name == "Garage")
        #expect(try await androidRepos.spaces.getById(otherSpace.id) == nil)
        #expect(try pragma(android, "journal_mode") == "wal")
        #expect(try pragma(android, "integrity_check") == "ok")
    }
    #endif
}
