import Foundation
import GRDB
import InventoryCore
import Testing
@testable import InventoryStorage

/// The final schema, byte for byte (01 §4.1, §13.8 #4), and the connection setup (01 §2).
@Suite("schema and connection")
struct SchemaTests {
    @Test("a fresh database's sqlite_master is byte-identical to what the RN migrations produce")
    func sqliteMasterMatchesTypeScript() throws {
        let fixture = try SqliteMasterFixture.load()
        let store = try DatabaseStore.inMemory()
        try store.migrate()
        let rows = try store.queue.read { db in try sqliteMaster(db) }
        #expect(rows.count == fixture.rows.count)
        for (actual, expected) in zip(rows, fixture.rows) {
            #expect(actual == expected)
        }
        #expect(try store.schemaVersion() == fixture.userVersion)
    }

    @Test("a fresh database file's sqlite_master is byte-identical too")
    func sqliteMasterOnFileMatches() throws {
        let fixture = try SqliteMasterFixture.load()
        let store = try DatabaseStore.temporary()
        try store.migrate()
        #expect(try store.queue.read { db in try sqliteMaster(db) } == fixture.rows)
    }

    @Test("has exactly one trigger and no views or virtual tables")
    func oneTrigger() throws {
        let store = try DatabaseStore.inMemory()
        try store.migrate()
        let kinds = try store.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT type, name FROM sqlite_master WHERE type IN ('trigger', 'view')")
                .map { row -> String in try row.decode(forColumn: "name") }
        }
        #expect(kinds == ["item_photos_tombstone"])
        let virtual = try store.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE sql LIKE '%VIRTUAL TABLE%'")
        }
        #expect(virtual == 0)
    }

    @Test("seeds the drop-zone space and container as system rows")
    func seedsDropZone() throws {
        let store = try DatabaseStore.inMemory()
        try store.migrate()
        let rows = try store.queue.read { db in
            (
                try Row.fetchOne(db, sql: "SELECT * FROM spaces WHERE id = 'drop-zone-space'"),
                try Row.fetchOne(db, sql: "SELECT * FROM containers WHERE id = 'drop-zone'")
            )
        }
        let space = try #require(rows.0)
        let container = try #require(rows.1)
        #expect(space["name"] as String? == "Drop zone")
        #expect(space["icon"] as String? == "\u{1F4E5}")
        #expect(space["color"] as String? == "#0F9BB0")
        #expect(space["kind"] as String? == "system")
        #expect(container["space_id"] as String? == DropZone.spaceId)
        #expect(container["visual_type"] as String? == "other")
        #expect(container["short_code"] as String? == "DROP-ZONE")
        #expect(container["kind"] as String? == "system")
        // Whole seconds × 1000.
        let createdAt: Int64 = try space.decode(forColumn: "created_at")
        #expect(createdAt % 1000 == 0)
    }

    @Test("opens with WAL, foreign keys on and synchronous FULL")
    func pragmasOnOpen() throws {
        let store = try DatabaseStore.temporary()
        #expect(try pragma(store, "journal_mode") == "wal")
        #expect(try pragma(store, "foreign_keys") == "1")
        #expect(try pragma(store, "synchronous") == "2")
    }

    @Test("keeps LOWER, LIKE and NOCASE ASCII-only, like expo's and node's SQLite")
    func asciiOnlyCaseFolding() throws {
        let store = try DatabaseStore.inMemory()
        let row = try #require(try store.queue.read { db in
            try Row.fetchOne(db, sql: "SELECT LOWER('ÄRMEL') AS lowered, 'ärmel' LIKE 'ÄRMEL' AS liked, 'ä' = 'Ä' COLLATE NOCASE AS nocase")
        })
        #expect(row["lowered"] as String? == "Ärmel")
        #expect(row["liked"] as Int? == 0)
        #expect(row["nocase"] as Int? == 0)
    }

    @Test("puts the live database at Documents/SQLite/inventory.db")
    func liveLocation() {
        let documents = URL(fileURLWithPath: "/tmp/container/Documents", isDirectory: true)
        #expect(DatabaseStore.liveURL(documents: documents).path == "/tmp/container/Documents/SQLite/inventory.db")
    }

    @Test("opens the live database in place, creating SQLite/ on a fresh install, and migrates it")
    func openLiveCreatesDirectory() throws {
        let scratch = try ScratchDirectory()
        let documents = scratch.url.appending(path: "Documents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)

        let store = try DatabaseStore.openLive(documents: documents)
        #expect(store.path == DatabaseStore.liveURL(documents: documents).path)
        #expect(try store.schemaVersion() == 7)
        try store.close()
        #expect(FileManager.default.fileExists(atPath: DatabaseStore.liveURL(documents: documents).path))
    }

    @Test("opens and migrates an upgraded phone's database off the caller's thread")
    func openLiveAsync() async throws {
        let scratch = try ScratchDirectory()
        let documents = scratch.url.appending(path: "Documents", directoryHint: .isDirectory)
        let live = DatabaseStore.liveURL(documents: documents)
        try FileManager.default.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: DatabaseFixtures.url("historical/v6.db"), to: live)

        let store = try await DatabaseStore.openLive(documents: documents)
        #expect(try await store.schemaVersion() == 7)
        #expect(try count(store, "item_photos") > 0)
        #expect(try count(store, "item_tags") > 0)
        try store.close()
    }
}
