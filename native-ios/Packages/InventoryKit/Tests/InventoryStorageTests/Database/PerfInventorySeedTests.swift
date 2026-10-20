import Foundation
import GRDB
import InventoryCore
import Testing
@testable import InventoryStorage

/// The large demo inventory (`-demoSeed large`, docs/PERFORMANCE.md): its shape, that it is the
/// same every time, and that its rows are what the repositories themselves would write.
@Suite("perf: the large inventory seed")
struct PerfInventorySeedTests {
    private static let now: Int64 = 1_790_000_000_000

    private static func seeded(_ shape: PerfInventorySeed.Shape, photos: Int = 0) throws -> (DatabaseStore, PerfInventorySeed.Summary) {
        let store = try DatabaseStore.inMemory()
        try store.migrate()
        let summary = try store.queue.write { db in
            try PerfInventorySeed.write(shape, photos: PerfInventorySeed.placeholderPhotos(count: photos), now: now, in: db)
        }
        return (store, summary)
    }

    private static func count(_ db: Database, _ sql: String, _ arguments: StatementArguments = []) throws -> Int {
        try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
    }

    @Test("10 000 items in 20 spaces and 250 containers, 300 waiting and 500 in one container")
    func largeShape() throws {
        let (store, summary) = try Self.seeded(.large, photos: 320)
        try store.queue.read { db in
            #expect(try Self.count(db, "SELECT COUNT(*) FROM items") == 10_000)
            #expect(summary.itemCount == 10_000)
            #expect(try Self.count(db, "SELECT COUNT(*) FROM spaces WHERE kind = 'normal'") == 20)
            #expect(try Self.count(db, "SELECT COUNT(*) FROM containers WHERE kind = 'normal'") == 250)
            #expect(summary.containerIds.count == 250 && summary.spaceIds.count == 20)
            let waiting = try Self.count(db, "SELECT COUNT(*) FROM items WHERE container_id = ?", [DropZone.containerId])
            #expect(waiting == summary.dropZoneItemCount)
            #expect((290...310).contains(waiting))
            #expect(try Self.count(db, "SELECT COUNT(*) FROM items WHERE container_id = ?", [summary.bigContainerId]) == 500)
            #expect(try Self.count(db, "SELECT COUNT(*) FROM item_photos") == 320)
            #expect(summary.photoCount == 320)
            #expect(try Self.count(db, "SELECT COUNT(*) FROM qr_bindings") == 40)
            #expect(try Self.count(db, "SELECT COUNT(*) FROM tags") == summary.tagCount)
            #expect(summary.tagCount > 40)
            // Quantities from none left to hundreds, unnamed shots, accents, notes and tags.
            #expect(try Self.count(db, "SELECT COUNT(*) FROM items WHERE quantity = 0") > 300)
            #expect(try Self.count(db, "SELECT COUNT(*) FROM items WHERE quantity >= 20") > 100)
            #expect(try Self.count(db, "SELECT COUNT(*) FROM items WHERE name = '' AND container_id = ?", [DropZone.containerId]) > 5)
            #expect(try Self.count(db, "SELECT COUNT(*) FROM items WHERE name LIKE '%é%' OR name LIKE '%ü%' OR name LIKE '%ñ%'") > 300)
            #expect(try Self.count(db, "SELECT COUNT(*) FROM items WHERE notes IS NOT NULL") > 2_000)
            #expect(try Self.count(db, "SELECT COUNT(DISTINCT item_id) FROM item_tags") > 4_000)
            #expect(summary.recentPlaceIds.count == RecentPlacesStore.maxCount)
            #expect(summary.recentPlaceIds.first == summary.bigContainerId)
        }
    }

    @Test("the same shape writes the same rows, ids included")
    func deterministic() throws {
        let shape = PerfInventorySeed.Shape.scaled(items: 800)
        let (first, firstSummary) = try Self.seeded(shape, photos: 20)
        let (second, secondSummary) = try Self.seeded(shape, photos: 20)
        #expect(firstSummary == secondSummary)
        // The migration stamps the drop zone's own space and container with the wall clock, so
        // only the seeded rows are compared.
        for table in ["spaces WHERE kind = 'normal'", "containers WHERE kind = 'normal'", "items", "tags", "item_tags", "item_photos", "qr_bindings"] {
            let dump = { (store: DatabaseStore) in
                try store.queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY 1, 2") }
            }
            #expect(try dump(first) == dump(second), "\(table)")
        }
    }

    @Test("rows are what the repositories write: folded search text and tags, valid codes, no broken links")
    func rowsMatchTheRepositories() throws {
        let (store, _) = try Self.seeded(.scaled(items: 2_000), photos: 40)
        try store.queue.read { db in
            for row in try Row.fetchAll(db, sql: "SELECT name, category, search_text FROM items") {
                let name: String = row["name"]
                let category: String? = row["category"]
                let searchText: String = row["search_text"]
                #expect(searchText == itemSearchText(name: name, category: category))
            }
            for row in try Row.fetchAll(db, sql: "SELECT name, normalized_name FROM tags") {
                let name: String = row["name"]
                let normalized: String = row["normalized_name"]
                #expect(normalized == normalizedTagName(name))
            }
            let codes = try String.fetchAll(db, sql: "SELECT short_code FROM containers WHERE kind = 'normal'")
            #expect(Set(codes).count == codes.count)
            #expect(codes.allSatisfy { $0.wholeMatch(of: /[A-Z]{3}-[2-9A-HJ-NP-Z]{4}/) != nil })
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            #expect(try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
            // Every item is newer than the one written before it.
            let times = try Int64.fetchAll(db, sql: "SELECT created_at FROM items ORDER BY rowid")
            #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
            #expect(times.last.map { $0 <= Self.now } ?? false)
        }
    }

    @Test("the names the demo routes use are there, the small demo's items newest")
    func demoNames() throws {
        let (store, summary) = try Self.seeded(.large)
        let repos = LocalRepositories(store: store)
        try store.queue.read { db in
            let big = try #require(try repos.containers.getById(summary.bigContainerId, in: db))
            #expect(big.name == PerfInventorySeed.bigContainerName)
            #expect(big.shortCode == PerfInventorySeed.bigContainerCode)
            let workshop = try #require(try repos.spaces.getById(summary.bigSpaceId, in: db))
            #expect(workshop.name == PerfInventorySeed.bigSpaceName)
            #expect(try String.fetchOne(db, sql: "SELECT name FROM containers WHERE short_code = 'CAB-J92R'") == "Tool chest")
            let recent = try repos.items.listRecent(limit: 12, in: db)
            #expect(recent.first?.item.name == "Bike pump")
            #expect(recent.first?.item.containerId == DropZone.containerId)
            let drill = try #require(recent.first { $0.item.name == "Cordless drill" })
            #expect(drill.containerName == "Tool chest")
            #expect(drill.tags == ["power tools"])
        }
    }

    @Test("a scaled shape keeps the named places and the proportions")
    func scaled() {
        let quarter = PerfInventorySeed.Shape.scaled(items: 2_500)
        #expect(quarter.items == 2_500)
        #expect(quarter.containers == 63 && quarter.spaces == 5)
        #expect(quarter.dropZoneItems == 75 && quarter.bigContainerItems == 125)
        let tiny = PerfInventorySeed.Shape.scaled(items: 10)
        #expect(tiny.containers >= 8 && tiny.spaces >= 4)
    }
}
