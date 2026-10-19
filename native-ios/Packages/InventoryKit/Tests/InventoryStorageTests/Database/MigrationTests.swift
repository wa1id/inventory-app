import Foundation
import GRDB
import InventoryCore
import InventoryTestSupport
import Testing
@testable import InventoryStorage

/// Ports `src/db/__tests__/persistence.test.ts` › migrations and `home-server/test/migrate.test.ts`,
/// plus the runner rules of 01 §3.1.
@Suite("migrations")
struct MigrationTests {
    @Test("brings a new database to the latest schema version")
    func bringsNewDatabaseToLatest() throws {
        let store = try DatabaseStore.inMemory()
        let version = try store.migrate()
        #expect(version == Migration.latestSchemaVersion)
    }

    @Test("is idempotent when run twice")
    func idempotent() throws {
        let store = try DatabaseStore.inMemory()
        try store.migrate()
        #expect(try store.migrate() == Migration.latestSchemaVersion)
    }

    @Test("upgrades a database stopped at an older version without losing data")
    func upgradesFromV1() async throws {
        let store = try DatabaseStore.inMemory()
        // An install that only ever saw migration 1.
        try await store.migrate(Array(Migration.all.prefix(1)))

        let repos = repositories(store)
        let (_, container) = try await seedSpaceAndContainer(repos)
        let now = epochMillis()
        try await store.queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO items (id, container_id, name, quantity, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: ["legacy-item", container.id, "Legacy Drill", 1, now, now]
            )
        }

        let version = try await store.migrate()

        #expect(version == Migration.latestSchemaVersion)
        // Migration 2 backfills search_text for rows written before it existed.
        let searchText = try await store.queue.read { db in
            try String.fetchOne(db, sql: "SELECT search_text FROM items WHERE id = ?", arguments: ["legacy-item"])
        }
        #expect(searchText == "legacy drill")
    }

    @Test("leaves no value-estimate columns behind on an upgraded database")
    func dropsValueColumns() async throws {
        let store = try DatabaseStore.inMemory()
        try await store.migrate(Array(Migration.all.prefix(1)))

        let repos = repositories(store)
        let (_, container) = try await seedSpaceAndContainer(repos)
        let now = epochMillis()
        try await store.queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO items (id, container_id, name, quantity, estimated_value, currency,
                                       created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: ["priced-item", container.id, "Drill", 1, 129.99, "EUR", now, now]
            )
        }

        try await store.migrate()

        let names = try await store.queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(items)").map { row -> String in try row.decode(forColumn: "name") }
        }
        #expect(!names.contains("estimated_value"))
        #expect(!names.contains("currency"))

        // The row itself survives the drop; only the two fields go.
        let name = try await store.queue.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM items WHERE id = ?", arguments: ["priced-item"])
        }
        #expect(name == "Drill")
    }

    @Test("keeps photos and tags when quantity 0 becomes allowed")
    func keepsPhotosAndTagsThroughRebuild() async throws {
        let store = try DatabaseStore.inMemory()
        try await store.migrate(Migration.all.filter { $0.version <= 6 })

        let repos = repositories(store)
        let (_, container) = try await seedSpaceAndContainer(repos)
        let item = try await repos.items.create(ItemDraft(
            containerId: container.id,
            name: "Nails",
            quantity: 1,
            tags: ["hardware"],
            photo: ItemPhotoInput(uri: "file:///photos/nails.jpg", width: 100, height: 80, byteSize: 12)
        ))

        // Application code now accepts 0; the old CHECK still refuses it.
        await #expect(throws: (any Error).self) {
            try await repos.items.update(item.id, UpdateItemInput(quantity: 0))
        }

        let version = try await store.migrate()
        #expect(version == Migration.latestSchemaVersion)

        #expect(try pragma(store, "foreign_keys") == "1")

        let schema = try await store.queue.read { db in
            try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'items'")
        }
        #expect(schema?.contains("CHECK (quantity >= 0)") == true)

        let emptied = try await repos.items.update(item.id, UpdateItemInput(quantity: 0))
        #expect(emptied?.quantity == 0)

        let stored = try await repos.items.getById(item.id)
        #expect(stored?.photoUri == "file:///photos/nails.jpg")
        #expect(stored?.tags == ["hardware"])
        #expect(stored?.containerId == container.id)

        let violations = try await store.queue.read { db in try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count }
        #expect(violations == 0)
    }

    @Test("declares versions matching their position")
    func versionsMatchPosition() {
        for (index, migration) in Migration.all.enumerated() {
            #expect(migration.version == index + 1)
        }
        #expect(Migration.latestSchemaVersion == 7)
        #expect(Migration.all.map(\.rebuild) == [false, false, false, false, false, false, true])
    }

    // MARK: home-server/test/migrate.test.ts

    @Test("migrates a new file database to the latest schema")
    func migratesNewFile() throws {
        let scratch = try TemporaryDirectory()
        let store = try DatabaseStore(path: scratch.path("inventory.db"))
        let version = try store.migrate()
        #expect(version == Migration.latestSchemaVersion)
        #expect(Migration.latestSchemaVersion == 7)
        #expect(try store.schemaVersion() == 7)
        try store.close()
    }

    @Test("a second migrate on the same file is a no-op")
    func secondMigrateIsNoOp() throws {
        let scratch = try TemporaryDirectory()
        let path = scratch.path("inventory.db")
        let first = try DatabaseStore(path: path)
        try first.migrate()
        try first.close()

        let second = try DatabaseStore(path: path)
        #expect(try second.migrate() == Migration.latestSchemaVersion)
        try second.close()
    }

    // MARK: Runner rules (01 §3.1)

    @Test("embeds every migration verbatim from src/db/migrations.ts")
    func migrationsAreVerbatim() throws {
        struct Fixture: Decodable {
            struct Entry: Decodable {
                let version: Int
                let name: String
                let up: String
                let rebuild: Bool
            }
            let latestSchemaVersion: Int
            let migrations: [Entry]
        }
        let fixture = try DatabaseFixtures.decode(Fixture.self, from: "migrations.json")
        #expect(fixture.latestSchemaVersion == Migration.latestSchemaVersion)
        try #require(fixture.migrations.count == Migration.all.count)
        for (expected, actual) in zip(fixture.migrations, Migration.all) {
            #expect(actual.version == expected.version)
            #expect(actual.name == expected.name)
            #expect(actual.rebuild == expected.rebuild)
            #expect(Array(actual.up.utf8) == Array(expected.up.utf8), "migration \(expected.version) text differs")
        }
    }

    @Test("opens a file from a newer build silently, applying nothing")
    func newerFileOpensSilently() throws {
        let store = try DatabaseStore.inMemory()
        try store.migrate()
        try store.queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA user_version = 9") }
        let before = try store.queue.read { db in try sqliteMaster(db) }

        #expect(try store.migrate() == 9)
        #expect(try store.queue.read { db in try sqliteMaster(db) } == before)
    }

    @Test("stops at the first failing migration, keeps the last applied version and surfaces the error")
    func failingMigrationAborts() throws {
        let store = try DatabaseStore.inMemory()
        var migrations = Array(Migration.all.prefix(2))
        migrations.append(Migration(version: 3, name: "broken", up: "CREATE TABLE half (id TEXT); SELECT nope FROM nowhere;"))
        migrations.append(Migration.all[3])

        #expect(throws: DatabaseError.self) { try store.migrate(migrations) }
        #expect(try store.schemaVersion() == 2)
        // The failing migration's own statements rolled back with it.
        let half = try store.queue.read { db in try db.tableExists("half") }
        #expect(!half)
    }

    @Test("turns foreign keys back on after a rebuild migration fails")
    func restoresForeignKeysAfterFailedRebuild() throws {
        let store = try DatabaseStore.inMemory()
        try store.migrate(Array(Migration.all.prefix(6)))
        let broken = Migration(version: 7, name: "broken_rebuild", up: "DROP TABLE no_such_table;", rebuild: true)

        #expect(throws: DatabaseError.self) { try store.migrate([broken]) }
        #expect(try pragma(store, "foreign_keys") == "1")
        #expect(try store.schemaVersion() == 6)
    }

    @Test("leaves foreign keys off after a rebuild when they were off before")
    func keepsForeignKeysOff() throws {
        let store = try DatabaseStore.inMemory()
        try store.migrate(Array(Migration.all.prefix(6)))
        try store.queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA foreign_keys = OFF") }

        #expect(try store.migrate() == 7)
        #expect(try pragma(store, "foreign_keys") == "0")
    }

    @Test("refuses to run inside a transaction, where the foreign-key pragma is ignored")
    func refusesInsideTransaction() throws {
        let store = try DatabaseStore.inMemory()
        #expect(throws: MigrationRunnerError.insideTransaction) {
            try store.queue.write { db in try MigrationRunner.migrate(db) }
        }
        #expect(try store.schemaVersion() == 0)
    }

    @Test("never creates a grdb_migrations table or anything outside the migrations")
    func noExtraTables() throws {
        let store = try DatabaseStore.inMemory()
        try store.migrate()
        let tables = try store.queue.read { db in try userTables(db) }
        #expect(tables == ["spaces", "containers", "item_photos", "tags", "item_tags", "qr_bindings", "sync_deletions", "items"])
    }
}
