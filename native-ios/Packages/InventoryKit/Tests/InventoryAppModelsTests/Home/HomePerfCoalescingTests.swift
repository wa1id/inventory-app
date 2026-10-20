import Foundation
import InventoryCore
import InventoryStorage
import InventoryTestSupport
import Synchronization
import Testing
@testable import InventoryAppModels

/// Typing on Home never queues stale searches (docs/PERFORMANCE.md, 06 §5.6): a search the next
/// keystroke supersedes is cancelled, not merely ignored, so the one database connection is
/// free for the words she has now; and the same holds for any screen's query.
@Suite("Home perf: superseded reads are cancelled")
@MainActor
struct HomePerfCoalescingTests {
    @Test("a search superseded while it runs is cancelled, and its answer never shows")
    func supersededSearchIsCancelled() async throws {
        let clock = ManualClock()
        let reads = HomePerfCancellableReads()
        let model = SearchModel(clock: clock, search: { try await reads.call($0) })

        model.setQuery("scr")
        try await clock.waitForSleepers(1, timeout: .seconds(60))
        await clock.advance(by: .milliseconds(200))
        await reads.waitForCalls(1)

        model.setQuery("screw")
        await reads.waitForCancellations(1)
        #expect(reads.cancelled == ["scr"])
        #expect(model.results == nil)
        #expect(model.pending)

        try await clock.waitForSleepers(1, timeout: .seconds(60))
        await clock.advance(by: .milliseconds(200))
        await reads.waitForCalls(2)
        reads.answer(SearchResults(terms: ["screw"], locations: [], items: []))
        await model.searchTask?.value
        #expect(model.settledQuery == "screw")
        #expect(reads.arguments == ["scr", "screw"])
    }

    @Test("letters typed faster than the pause search once, for the last word")
    func typingSearchesOnce() async throws {
        let clock = ManualClock()
        let reads = HomePerfCancellableReads()
        let model = SearchModel(clock: clock, search: { try await reads.call($0) })
        for word in ["s", "sc", "scr", "scre", "screw", "screwd", "screwdr"] {
            model.setQuery(word)
            try await clock.waitForSleepers(1, timeout: .seconds(60))
            await clock.advance(by: .milliseconds(120))
        }
        await clock.advance(by: .milliseconds(80))
        await reads.waitForCalls(1)
        reads.answer(SearchResults(terms: ["screwdr"], locations: [], items: []))
        await model.searchTask?.value
        #expect(reads.arguments == ["screwdr"])
        #expect(model.searchCount == 1)
    }

    @Test("a query's read superseded by a new key is cancelled")
    func supersededQueryReadIsCancelled() async throws {
        let reads = HomePerfCancellableReads()
        let query = InventoryQuery<SearchResults>(key: "a") { try await reads.call("a") }
        query.focusChanged(true, revision: 0)
        await reads.waitForCalls(1)
        query.setKey("b") { try await reads.call("b") }
        await reads.waitForCancellations(1)
        #expect(reads.cancelled == ["a"])
        await reads.waitForCalls(2)
        reads.answer(SearchResults(terms: ["b"], locations: [], items: []))
        await query.readTask?.value
        #expect(query.data?.terms == ["b"])
        #expect(query.dataKey == "b")
    }

    @Test("on 10 000 items, typing a word ends with the results for that word, searched once per pause")
    func largeInventory() async throws {
        let store = try DatabaseStore.inMemory()
        try await store.migrate()
        _ = try await store.queue.write { db in try PerfInventorySeed.write(.large, now: 1_790_000_000_000, in: db) }
        let repositories = LocalRepositories(store: store)
        let clock = ManualClock()
        let searched = HomePerfLog()
        let model = SearchModel(clock: clock) { query in
            searched.append(query)
            return try await repositories.search.search(query)
        }
        model.focusChanged(true, revision: 0)
        for word in ["c", "ca", "cab", "cabl", "cable"] {
            model.setQuery(word)
            try await clock.waitForSleepers(1, timeout: .seconds(60))
            await clock.advance(by: .milliseconds(100))
        }
        await clock.advance(by: .milliseconds(100))
        await model.searchTask?.value
        #expect(searched.entries == ["cable"])
        #expect(model.settledQuery == "cable")
        let results = try #require(model.results)
        #expect(!results.items.isEmpty)
        #expect(results.items.allSatisfy { hit in
            let item = hit.item
            let text = [item.item.name, item.item.category ?? "", item.containerName ?? "", item.spaceName, item.containerShortCode]
                .joined(separator: " ").lowercased() + " " + item.tags.joined(separator: " ")
            return text.contains("cable")
        })
    }
}

/// Reads held until the test answers them; a read whose task is cancelled ends at once with
/// `CancellationError` and is recorded, as a GRDB read is interrupted.
final class HomePerfCancellableReads: Sendable {
    private struct State {
        var calls: [String] = []
        var cancelled: [String] = []
        var cancelledIndexes: Set<Int> = []
        var waiting: [Int: CheckedContinuation<SearchResults, any Error>] = [:]
    }

    private let state = Mutex(State())

    var arguments: [String] { state.withLock { $0.calls } }
    var cancelled: [String] { state.withLock { $0.cancelled } }

    func call(_ argument: String) async throws -> SearchResults {
        let index = state.withLock { state -> Int in
            state.calls.append(argument)
            return state.calls.count - 1
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelledAlready = state.withLock { state -> Bool in
                    if Task.isCancelled { return true }
                    state.waiting[index] = continuation
                    return false
                }
                if cancelledAlready {
                    state.withLock { state in
                        state.cancelled.append(argument)
                        state.cancelledIndexes.insert(index)
                    }
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation = state.withLock { state -> CheckedContinuation<SearchResults, any Error>? in
                guard let continuation = state.waiting.removeValue(forKey: index) else { return nil }
                state.cancelled.append(argument)
                state.cancelledIndexes.insert(index)
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Answers the newest call still waiting.
    func answer(_ results: SearchResults) {
        let continuation = state.withLock { state -> CheckedContinuation<SearchResults, any Error>? in
            guard let newest = state.waiting.keys.max() else { return nil }
            return state.waiting.removeValue(forKey: newest)
        }
        continuation?.resume(returning: results)
    }

    func waitForCalls(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        // The newest call is waiting for its answer (or was cancelled meanwhile).
        await waitUntil("\(count) call(s)", sourceLocation: sourceLocation) { state in
            state.calls.count >= count
                && (state.waiting[count - 1] != nil || state.cancelledIndexes.contains(count - 1))
        }
    }

    func waitForCancellations(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        await waitUntil("\(count) cancellation(s)", sourceLocation: sourceLocation) { $0.cancelled.count >= count }
    }

    private func waitUntil(_ description: String, sourceLocation: SourceLocation, _ condition: (State) -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while !state.withLock({ condition($0) }) {
            if ContinuousClock.now > deadline {
                Issue.record("never happened: \(description)", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

/// What a closure was called with, oldest first.
final class HomePerfLog: Sendable {
    private let state = Mutex<[String]>([])

    var entries: [String] { state.withLock { $0 } }

    func append(_ entry: String) {
        state.withLock { $0.append(entry) }
    }
}
