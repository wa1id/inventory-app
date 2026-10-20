import Foundation
import GRDB
import InventoryCore
import Testing
@testable import InventoryStorage

/// Guards against the reads on 10 000 items getting slow (00-index M9: search under a second).
///
/// The limits are on CPU time spent in the read (best of five), far above what the build Mac
/// measures (docs/PERFORMANCE.md: search 20–45 ms, list reads under 10 ms), so a loaded Mac
/// does not fail them while an accidental full-table pass per row or a quadratic plan does.
@Suite("Perf regressions on 10 000 items", .serialized)
struct PerfRegressionTests {
    /// The M9 budget is a second on a phone; the build Mac is faster, so half of it here.
    static let searchLimit: Duration = .milliseconds(500)
    /// Lists Home and the place screens read on every focus.
    static let listLimit: Duration = .milliseconds(150)

    @Test("every query class searches 10 000 items well within the budget", arguments: PerfQuery.allCases)
    func search(query: PerfQuery) throws {
        let database = try PerfDatabase.large.get()
        let repositories = database.repositories
        let (measurement, results) = try perfMeasureRead(database.store) { db in
            try repositories.search.search(query.rawValue, in: db)
        }
        #expect(measurement.best.cpu < Self.searchLimit, "\(query.rawValue): \(PerfSample.text(measurement.best.cpu))")
        #expect(results.items.count <= LocalSearchRepository.itemResultLimit)
        #expect(results.locations.count <= LocalSearchRepository.locationResultLimit)
    }

    @Test("search cost grows with the inventory, not with its square")
    func searchScalesLinearly() throws {
        let large = try PerfDatabase.large.get()
        let quarter = try PerfDatabase.quarter.get()
        for query in [PerfQuery.oneLetter, .nothing, .commonWord] {
            let (big, _) = try perfMeasureRead(large.store) { db in try large.repositories.search.search(query.rawValue, in: db) }
            let (small, _) = try perfMeasureRead(quarter.store) { db in try quarter.repositories.search.search(query.rawValue, in: db) }
            // Four times the rows: about four times the work. Quadratic would be sixteen.
            let ratio = big.best.cpu.perfMilliseconds / max(0.001, small.best.cpu.perfMilliseconds)
            #expect(ratio < 9, "\(query.rawValue): 2 500 items \(PerfSample.text(small.best.cpu)), 10 000 items \(PerfSample.text(big.best.cpu))")
        }
    }

    @Test("Home's idle list and the place lists read in a few milliseconds")
    func listReads() throws {
        let database = try PerfDatabase.large.get()
        let repositories = database.repositories
        let summary = database.summary
        let reads: [(String, (Database) throws -> Int)] = [
            ("spaces.listWithCounts", { try repositories.spaces.listWithCounts(in: $0).count }),
            ("items.listRecent(12)", { try repositories.items.listRecent(limit: 12, in: $0).count }),
            ("items.listRecent(40)", { try repositories.items.listRecent(limit: 40, in: $0).count }),
            ("containers.listAllWithSpace", { try repositories.containers.listAllWithSpace(in: $0).count }),
            ("items.listUnsorted", { try repositories.items.listUnsorted(in: $0).count }),
            ("items.listByContainer(500)", { try repositories.items.listByContainer(summary.bigContainerId, in: $0).count }),
            ("containers.listBySpace", { try repositories.containers.listBySpace(summary.bigSpaceId, in: $0).count }),
        ]
        for (name, read) in reads {
            let (measurement, rows) = try perfMeasureRead(database.store, read)
            #expect(rows > 0, "\(name)")
            #expect(measurement.best.cpu < Self.listLimit, "\(name): \(PerfSample.text(measurement.best.cpu))")
        }
    }

    @Test("the recent list reads its context for the rows shown only")
    func recentReadsOnlyTheRowsShown() throws {
        // RN's single statement works out the photo and tag subqueries for all 10 000 items
        // (25 ms on the build Mac); the reshaped read costs about a fifth of that (5 ms). Asking
        // for less than a third leaves room for noise and still fails if the full pass returns.
        // Both are measured here, side by side, so a slow Mac slows both.
        let large = try PerfDatabase.large.get()
        let (recent, _) = try perfMeasureRead(large.store) { db in try large.repositories.items.listRecent(limit: 12, in: db) }
        let (subqueriesForAll, _) = try perfMeasureRead(large.store) { db in
            try Row.fetchAll(db, sql: "\(itemContextSelect) ORDER BY i.created_at DESC LIMIT 12").count
        }
        #expect(recent.best.cpu * 3 < subqueriesForAll.best.cpu,
                "listRecent \(PerfSample.text(recent.best.cpu)), RN's statement \(PerfSample.text(subqueriesForAll.best.cpu))")
    }

    @Test("correcting a misspelt search reads the words and corrects them within a fraction of the budget")
    func correction() throws {
        // Measured on the build Mac (docs/PERFORMANCE.md): the words of 10 000 items in 36–41 ms
        // (123 ms before each piece was folded once), a correction against the seed's 505 words
        // in under 5 ms and against 8 000 distinct words in 32–100 ms.
        let database = try PerfDatabase.large.get()
        let repositories = database.repositories
        let (read, words) = try perfMeasureRead(database.store) { db in try repositories.search.vocabulary(in: db) }
        #expect(read.best.cpu < Self.vocabularyLimit, "vocabulary: \(PerfSample.text(read.best.cpu))")
        let synthetic = PerfSpelling.syntheticVocabulary(words: 8_000)
        for (name, vocabulary, limit) in [("seed", words, Self.correctionLimit), ("8 000 words", synthetic, Self.largeCorrectionLimit)] {
            for query in PerfSpelling.queries {
                let measurement = perfMeasure { _ = SearchSpelling.correctedQuery(query, vocabulary: vocabulary) }
                #expect(measurement.best.cpu < limit, "\(query), \(name): \(PerfSample.text(measurement.best.cpu))")
            }
        }
    }

    /// The words of 10 000 items, five times what the build Mac measures.
    static let vocabularyLimit: Duration = .milliseconds(200)
    /// One correction against the seed's words, ten times what the build Mac measures.
    static let correctionLimit: Duration = .milliseconds(50)
    /// One correction against 8 000 distinct words: catches a quadratic pass, not noise.
    static let largeCorrectionLimit: Duration = .milliseconds(400)

    @Test("writing the large inventory takes one transaction and well under the demo's launch budget")
    func seedIsFast() throws {
        let database = try PerfDatabase.large.get()
        #expect(database.seedTime.cpu < .seconds(5), "\(PerfSample.text(database.seedTime.cpu))")
    }
}
