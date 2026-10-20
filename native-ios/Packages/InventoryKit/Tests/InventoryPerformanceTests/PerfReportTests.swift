import Foundation
import GRDB
import InventoryCore
import InventoryAppModels
import Testing
@testable import InventoryStorage

/// The numbers in docs/PERFORMANCE.md: every search class and list read on 10 000 items, best
/// and median of five, wall-clock and CPU. Measure-only, so it is off unless `INVENTORY_PERF=1`:
///
///     scripts/mac.sh shell 'cd Packages/InventoryKit && INVENTORY_PERF=1 swift test \
///       --scratch-path ~/inventory-native/<key>/spm-build --filter PerfReport' | grep 'PERF |'
@Suite("Perf report (INVENTORY_PERF=1)", .serialized, .enabled(if: PerfReport.enabled))
struct PerfReportTests {
    @Test("search and list reads on 10 000 items")
    func report() throws {
        let database = try PerfDatabase.large.get()
        let store = database.store
        let repositories = database.repositories
        let summary = database.summary
        PerfReport.line("seed: \(summary.itemCount) items, \(summary.containerIds.count) containers, \(summary.spaceIds.count) spaces, \(summary.dropZoneItemCount) in the drop zone, \(summary.photoCount) photos, \(summary.tagCount) tags; written in \(PerfSample.text(database.seedTime.wall)) wall, \(PerfSample.text(database.seedTime.cpu)) CPU")
        let pages = try store.queue.read { db in try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0 }
        let pageSize = try store.queue.read { db in try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0 }
        PerfReport.line("database: \(pages * pageSize / 1024) KiB")

        PerfReport.line("| Query | Class | Items | Places | Best wall | Best CPU | Median CPU |")
        for query in PerfQuery.allCases {
            let (measurement, results) = try perfMeasureRead(store) { db in
                try repositories.search.search(query.rawValue, in: db)
            }
            PerfReport.line("| `\(query.rawValue)` | \(query.label) | \(results.items.count) | \(results.locations.count) | \(PerfSample.text(measurement.best.wall)) | \(PerfSample.text(measurement.best.cpu)) | \(PerfSample.text(measurement.median.cpu)) |")
        }

        PerfReport.line("| Read | Rows | Best wall | Best CPU | Median CPU |")
        try reportRead("spaces.listWithCounts", store) { db in try repositories.spaces.listWithCounts(in: db).count }
        try reportRead("items.listRecent(12), RN's one statement (before)", store) { db in
            try Row.fetchAll(db, sql: "\(itemContextSelect) ORDER BY i.created_at DESC LIMIT 12").count
        }
        try reportRead("items.listRecent(12)", store) { db in try repositories.items.listRecent(limit: 12, in: db).count }
        try reportRead("items.listRecent(40)", store) { db in try repositories.items.listRecent(limit: 40, in: db).count }
        try reportRead("containers.listAllWithSpace", store) { db in try repositories.containers.listAllWithSpace(in: db).count }
        try reportRead("items.listUnsorted (drop zone)", store) { db in try repositories.items.listUnsorted(in: db).count }
        try reportRead("items.countUnsorted", store) { db in try repositories.items.countUnsorted(in: db) }
        try reportRead("items.listByContainer (500)", store) { db in try repositories.items.listByContainer(summary.bigContainerId, in: db).count }
        try reportRead("containers.listBySpace (Workshop)", store) { db in try repositories.containers.listBySpace(summary.bigSpaceId, in: db).count }
        try reportRead("containers.getWithCounts (500)", store) { db in try repositories.containers.getWithCounts(summary.bigContainerId, in: db) == nil ? 0 : 1 }
        try reportRead("items.countAll", store) { db in try repositories.items.countAll(in: db) }
    }

    @Test("Home's main-thread work per redraw for 230 results")
    @MainActor
    func homeRedraw() throws {
        let database = try PerfDatabase.large.get()
        let results = try database.store.queue.read { db in try database.repositories.search.search("a", in: db) }
        func measure(_ name: String, _ body: () -> Int) {
            var best = Duration.seconds(3600)
            var size = 0
            for _ in 0..<5 {
                let start = perfThreadCPUTime()
                size = body()
                best = min(best, perfThreadCPUTime() - start)
            }
            PerfReport.line("| \(name) | \(size) | \(PerfSample.text(best)) |")
        }
        PerfReport.line("| Main-thread step (230 results) | Size | Best CPU |")
        measure("HomeList.resultEntries") { HomeList.resultEntries(results, refreshFailed: false).count }
        measure("HomeSections.sections") { HomeSections.sections(HomeList.resultEntries(results, refreshFailed: false)).count }
        let texts = results.items.flatMap { [$0.item.item.name, formatLocationPath($0.item)] }
        measure("TextHighlight.split, every row's name and place") {
            texts.reduce(0) { $0 + TextHighlight.split($1, terms: ["scr", "ab"]).count }
        }
        let containers = try database.store.queue.read { db in try database.repositories.containers.listAllWithSpace(in: db) }
        measure("index of 250 containers per place row × 30 (before)") {
            (0..<30).reduce(0) { total, _ in
                total + Dictionary(containers.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }).count
            }
        }
    }

    @Test("correcting a misspelt search on 10 000 items: the vocabulary read and the correction")
    func correction() throws {
        let database = try PerfDatabase.large.get()
        let repositories = database.repositories
        let (read, words) = try perfMeasureRead(database.store) { db in try repositories.search.vocabulary(in: db) }
        PerfReport.line("| Correction step | Size | Best wall | Best CPU | Median CPU |")
        PerfReport.line("| vocabulary read (10 000 items) | \(words.counts.count) words | \(PerfSample.text(read.best.wall)) | \(PerfSample.text(read.best.cpu)) | \(PerfSample.text(read.median.cpu)) |")
        let synthetic = PerfSpelling.syntheticVocabulary(words: 8_000)
        for (name, vocabulary) in [("seed", words), ("8 000 distinct words", synthetic)] {
            for query in PerfSpelling.queries {
                var shown: String?
                let measurement = perfMeasure { shown = SearchSpelling.correctedQuery(query, vocabulary: vocabulary) }
                PerfReport.line("| correctedQuery `\(query)` → `\(shown ?? "nil")` | \(name) | \(PerfSample.text(measurement.best.wall)) | \(PerfSample.text(measurement.best.cpu)) | \(PerfSample.text(measurement.median.cpu)) |")
            }
        }
    }

    @Test("the v7 rebuild of an older phone's 10 000 items (once, on the first native launch)")
    func rebuild() throws {
        let store = try DatabaseStore.temporary()
        try store.migrate(Array(Migration.all.prefix(6)))
        try store.queue.write { db in
            let insert = try db.cachedStatement(sql: """
                INSERT INTO items (id, container_id, name, category, quantity, notes, created_at, updated_at, search_text)
                VALUES (?, ?, ?, ?, 1, NULL, ?, ?, ?)
                """)
            for index in 0..<10_000 {
                try insert.execute(arguments: ["item-\(index)", DropZone.containerId, "Widget \(index)", "Parts", index, index, "widget \(index) parts"])
            }
        }
        let wallStart = ContinuousClock.now
        let version = try store.migrate()
        let wall = ContinuousClock.now - wallStart
        #expect(version == 7)
        PerfReport.line("v6 → v7 rebuild of 10 000 items: \(PerfSample.text(wall)) wall")
    }

    private func reportRead(_ name: String, _ store: DatabaseStore, _ body: (Database) throws -> Int) throws {
        let (measurement, rows) = try perfMeasureRead(store, body)
        PerfReport.line("| \(name) | \(rows) | \(PerfSample.text(measurement.best.wall)) | \(PerfSample.text(measurement.best.cpu)) | \(PerfSample.text(measurement.median.cpu)) |")
    }
}
