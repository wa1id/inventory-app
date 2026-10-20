import Foundation
import GRDB
import InventoryCore
import Testing
@testable import InventoryStorage

/// The reads reshaped for speed (docs/PERFORMANCE.md) return exactly what RN's statements
/// return: the same rows in the same order, ties and orphaned rows included. The home server
/// runs RN's statements, so a difference here would be a parity bug (DECISIONS U12).
@Suite("perf: reshaped reads keep RN's rows and order")
struct PerfReadParityTests {
    /// RN `listRecent`, verbatim (src/repositories/items.ts:194-201).
    static func rnListRecent(_ limit: Int, in db: Database) throws -> [ItemWithContext] {
        try Row.fetchAll(
            db,
            sql: "\(itemContextSelect) ORDER BY i.created_at DESC LIMIT ?",
            arguments: [max(1, min(limit, 100))]
        ).map(RowMapping.itemWithContext)
    }

    @Test("listRecent on the large inventory", arguments: [1, 12, 40, 100, 500, 0, -3])
    func largeInventory(limit: Int) throws {
        let store = try Self.largeStore()
        let repository = LocalItemsRepository(queue: store.queue)
        try store.queue.read { db in
            let expected = try Self.rnListRecent(limit, in: db)
            let actual = try repository.listRecent(limit: limit, in: db)
            #expect(actual == expected)
            #expect(!actual.isEmpty)
        }
    }

    @Test("listRecent with many items created in the same millisecond, some with photos and tags")
    func ties() throws {
        let store = try DatabaseStore.inMemory()
        try store.migrate()
        let repos = LocalRepositories(store: store)
        try store.queue.write { db in
            let space = "s-tie"
            try db.execute(sql: "INSERT INTO spaces (id, name, icon, color, created_at, updated_at) VALUES (?, 'Tie', 'x', '#5B8DEF', 1, 1)", arguments: [space])
            for container in 0..<3 {
                try db.execute(
                    sql: "INSERT INTO containers (id, space_id, name, visual_type, short_code, created_at, updated_at) VALUES (?, ?, ?, 'box', ?, 1, 1)",
                    arguments: ["c\(container)", space, "Box \(container)", "BOX-T\(container)ZZ"])
            }
            // Ids out of rowid order, three timestamps shared by twenty items each.
            for index in 0..<60 {
                let id = String(format: "%02d-item", (index * 37) % 60)
                let createdAt: Int64 = [1_000, 2_000, 2_000, 3_000][index % 4]
                try db.execute(
                    sql: """
                        INSERT INTO items (id, container_id, name, category, quantity, created_at, updated_at, search_text)
                        VALUES (?, ?, ?, NULL, ?, ?, ?, ?)
                        """,
                    arguments: [id, ["c0", "c1", "c2", DropZone.containerId][index % 4], "Thing \(index % 7)", index % 3, createdAt, createdAt, "thing \(index % 7)"])
                if index % 5 == 0 {
                    try db.execute(
                        sql: "INSERT INTO item_photos (id, item_id, uri, thumb_uri, created_at) VALUES (?, ?, ?, ?, ?)",
                        arguments: ["p\(index)", id, "file:///x/item-photos/\(index).webp", "file:///x/item-photos/\(index)-thumb.webp", createdAt])
                }
            }
        }
        _ = try store.queue.write { db in try repos.items.update("07-item", UpdateItemInput(tags: ["tied", "café"]), in: db) }

        for limit in [1, 5, 12, 20, 21, 40, 59, 60, 100] {
            let (actual, expected) = try store.queue.read { db in
                (try repos.items.listRecent(limit: limit, in: db), try Self.rnListRecent(limit, in: db))
            }
            #expect(actual == expected, "limit \(limit)")
        }
    }

    @Test("listRecent leaves out an item whose container is gone, as RN's inner joins do")
    func orphans() throws {
        let store = try DatabaseStore.inMemory()
        try store.migrate()
        let repos = LocalRepositories(store: store)
        try store.queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(
                sql: "INSERT INTO items (id, container_id, name, quantity, created_at, updated_at, search_text) VALUES ('orphan', 'no-such-container', 'Orphan', 1, 9000, 9000, 'orphan')")
            try db.execute(
                sql: "INSERT INTO items (id, container_id, name, quantity, created_at, updated_at, search_text) VALUES ('kept', ?, 'Kept', 1, 8000, 8000, 'kept')",
                arguments: [DropZone.containerId])
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        try store.queue.read { db in
            let expected = try Self.rnListRecent(10, in: db)
            #expect(expected.map(\.item.id) == ["kept"])
            #expect(try repos.items.listRecent(limit: 10, in: db) == expected)
        }
    }

    /// A file-backed store with the large inventory, written once for the suite's tests.
    static func largeStore() throws -> DatabaseStore {
        try sharedLarge.get()
    }

    private static let sharedLarge = Result { () throws -> DatabaseStore in
        let store = try DatabaseStore.temporary()
        try store.migrate()
        _ = try store.queue.write { db in
            try PerfInventorySeed.write(.large, photos: PerfInventorySeed.placeholderPhotos(count: 320), now: 1_790_000_000_000, in: db)
        }
        return store
    }
}
