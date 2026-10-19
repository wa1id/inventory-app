import InventoryCore
import InventoryStrings
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// 06 §5.6, §5.10, §21 and 01 §9.2 `SearchModel` (no RN tests exist for `useSearch`).
@Suite("SearchModel (src/hooks/useSearch.ts)")
@MainActor
struct SearchModelTests {
    private typealias Fixtures = ShellFixtures

    /// A model on a manual clock with held searches.
    @MainActor
    private final class Harness {
        let clock = ManualClock()
        let searches = ShellHeldReads<SearchResults>()
        let telemetry = RecordingTelemetry()
        let spoken = ShellEventLog()
        let categories = ShellEventLog()
        let model: SearchModel

        init(revision: Int = 0) {
            let searches = searches
            let spoken = spoken
            let categories = categories
            model = SearchModel(
                revision: revision, clock: clock, telemetry: TelemetryReporter(sink: telemetry),
                rememberCategories: { categories.record($0.map { $0 ?? "nil" }.joined(separator: ",")) },
                announce: { spoken.record($0) },
                search: { try await searches.call($0) })
        }

        /// Types `text` and lets the 200 ms debounce pass.
        func type(_ text: String) async throws {
            model.setQuery(text)
            try await clock.waitForSleepers()
            await clock.advance(by: .milliseconds(200))
        }

        /// Answers the newest search and waits for it to settle.
        func answer(_ results: SearchResults) async {
            searches.succeed(results)
            await model.searchTask?.value
        }

        func failNewest() async {
            searches.fail(ShellTestError("search"))
            await model.searchTask?.value
        }
    }

    private static let glue = Fixtures.results([Fixtures.hit("g", name: "Glue", category: "Craft")], terms: ["glue"])
    private static let tape = Fixtures.results([Fixtures.hit("t", name: "Tape")], [Fixtures.place("box")], terms: ["tape"])

    @Test("a new query waits for a 200 ms pause in typing")
    func debounce() async throws {
        let harness = Harness()
        harness.model.setQuery("glue")
        try await harness.clock.waitForSleepers()
        await harness.clock.advance(by: .milliseconds(199))
        #expect(harness.searches.callCount == 0)
        #expect(harness.model.pending)
        await harness.clock.advance(by: .milliseconds(1))
        await harness.searches.waitForCalls(1)
        #expect(harness.searches.arguments == ["glue"])
    }

    @Test("typing again within the pause restarts it, and only the last words are searched")
    func typingRestartsDebounce() async throws {
        let harness = Harness()
        harness.model.setQuery("gl")
        try await harness.clock.waitForSleepers()
        await harness.clock.advance(by: .milliseconds(150))
        harness.model.setQuery("glue")
        try await harness.clock.waitForSleepers()
        await harness.clock.advance(by: .milliseconds(199))
        #expect(harness.searches.callCount == 0)
        await harness.clock.advance(by: .milliseconds(1))
        await harness.searches.waitForCalls(1)
        await ShellWait.settle()
        #expect(harness.searches.arguments == ["glue"])
        #expect(harness.model.searchCount == 1)
    }

    @Test("settles with results for the query, no longer pending")
    func settles() async throws {
        let harness = Harness()
        try await harness.type("glue")
        await harness.searches.waitForCalls(1)
        await harness.answer(Self.glue)
        #expect(harness.model.results == Self.glue)
        #expect(harness.model.settledQuery == "glue")
        #expect(!harness.model.pending)
        #expect(!harness.model.refreshing)
        #expect(harness.model.cause == nil)
    }

    @Test("the same query again starts at once: on focus, on Try again, and after a write while focused")
    func sameQueryNoDebounce() async throws {
        let harness = Harness()
        harness.model.focusChanged(true)
        try await harness.type("glue")
        await harness.searches.waitForCalls(1)
        await harness.answer(Self.glue)

        harness.model.retry()
        #expect(harness.model.refreshing)
        #expect(!harness.model.pending)
        await harness.searches.waitForCalls(2)
        await harness.answer(Self.glue)
        #expect(!harness.model.refreshing)

        harness.model.revisionChanged(1)
        await harness.searches.waitForCalls(3)
        await harness.answer(Self.glue)

        harness.model.focusChanged(false)
        harness.model.focusChanged(true)
        await harness.searches.waitForCalls(4)
        await harness.answer(Self.glue)
        #expect(harness.clock.pendingSleeperCount == 0)
        #expect(harness.searches.arguments == ["glue", "glue", "glue", "glue"])
    }

    @Test("a write while Home is not focused waits; focus catches up in one run")
    func focusGatedRevision() async throws {
        let harness = Harness()
        harness.model.focusChanged(true)
        try await harness.type("glue")
        await harness.searches.waitForCalls(1)
        await harness.answer(Self.glue)

        harness.model.focusChanged(false)
        harness.model.revisionChanged(1)
        harness.model.revisionChanged(2)
        await ShellWait.settle()
        #expect(harness.searches.callCount == 1)
        #expect(harness.model.run.seenRevision == 0)

        harness.model.focusChanged(true)
        await harness.searches.waitForCalls(2)
        await ShellWait.settle()
        #expect(harness.searches.callCount == 2)
        #expect(harness.model.run == SearchModel.Run(seenRevision: 2, nonce: 2))
    }

    @Test("a change ignores the answer still in flight")
    func ignoresInFlight() async throws {
        let harness = Harness()
        try await harness.type("glue")
        await harness.searches.waitForCalls(1)
        harness.model.setQuery("tape")
        harness.searches.succeed(Self.glue, call: 0)
        await ShellWait.settle()
        #expect(harness.model.results == nil)
        #expect(harness.model.pending)

        try await harness.clock.waitForSleepers()
        await harness.clock.advance(by: .milliseconds(200))
        await harness.searches.waitForCalls(2)
        await harness.answer(Self.tape)
        #expect(harness.model.results == Self.tape)
        #expect(harness.model.settledQuery == "tape")
    }

    @Test("emptying the field keeps the last results; new words show them as pending until they settle")
    func keepsResultsWhenCleared() async throws {
        let harness = Harness()
        try await harness.type("glue")
        await harness.searches.waitForCalls(1)
        await harness.answer(Self.glue)

        harness.model.setQuery("")
        #expect(harness.model.results == Self.glue)
        #expect(!harness.model.pending)
        #expect(!harness.model.isSearching)

        harness.model.setQuery("tape")
        #expect(harness.model.pending)
        #expect(harness.model.results == Self.glue)
        #expect(harness.model.settledQuery == "glue")
    }

    @Test("back to the settled words, the re-run starts with no pause")
    func backToSettledWords() async throws {
        let harness = Harness()
        try await harness.type("glue")
        await harness.searches.waitForCalls(1)
        await harness.answer(Self.glue)
        harness.model.setQuery("glu")
        harness.model.setQuery("glue")
        // Current again, and answered for this run, as in RN: not pending, not refreshing.
        #expect(!harness.model.pending)
        #expect(!harness.model.refreshing)
        #expect(harness.model.results == Self.glue)
        await harness.searches.waitForCalls(2)
        #expect(harness.searches.arguments == ["glue", "glue"])
    }

    @Test("a failed re-run keeps the results for the same query; a new query's failure has none")
    func failures() async throws {
        let harness = Harness()
        try await harness.type("glue")
        await harness.searches.waitForCalls(1)
        await harness.answer(Self.glue)
        harness.model.retry()
        await harness.searches.waitForCalls(2)
        await harness.failNewest()
        #expect(harness.model.results == Self.glue)
        #expect(harness.model.cause != nil)
        #expect(!harness.model.refreshing)

        try await harness.type("tape")
        await harness.searches.waitForCalls(3)
        #expect(harness.model.cause == nil)
        await harness.failNewest()
        #expect(harness.model.results == nil)
        #expect(harness.model.cause != nil)
        #expect(harness.model.settledQuery == "tape")
    }

    @Test("the cause belongs to the run that answered: a re-run in flight clears it")
    func causeOnlyWhenAnswered() async throws {
        let harness = Harness()
        try await harness.type("glue")
        await harness.searches.waitForCalls(1)
        await harness.failNewest()
        #expect(harness.model.cause != nil)
        harness.model.retry()
        #expect(harness.model.cause == nil)
        #expect(harness.model.refreshing)
        await harness.searches.waitForCalls(2)
        await harness.answer(Self.glue)
    }

    @Test("logs search_performed once per settled query, with counts only")
    func telemetryOncePerQuery() async throws {
        let harness = Harness()
        try await harness.type("glue")
        await harness.searches.waitForCalls(1)
        await harness.answer(Self.glue)
        harness.model.retry()
        await harness.searches.waitForCalls(2)
        await harness.answer(Self.glue)
        #expect(harness.telemetry.names == ["search_performed"])
        #expect(harness.telemetry.events.first?.payload == ["termCount": .int(1), "resultCount": .int(1), "queryLength": .int(4)])

        try await harness.type("tape")
        await harness.searches.waitForCalls(3)
        await harness.answer(Self.tape)
        #expect(harness.telemetry.events.last?.payload == ["termCount": .int(1), "resultCount": .int(2), "queryLength": .int(4)])
        #expect(harness.telemetry.names.count == 2)

        // Emptying the field makes the same words a new search again.
        harness.model.setQuery("")
        harness.model.setQuery("tape")
        await harness.searches.waitForCalls(4)
        await harness.answer(Self.tape)
        #expect(harness.telemetry.names.count == 3)
    }

    @Test("queryLength counts UTF-16 code units, as JS .length does")
    func queryLengthUTF16() async throws {
        let harness = Harness()
        try await harness.type("  café 🧰 ")
        await harness.searches.waitForCalls(1)
        #expect(harness.searches.arguments == ["café 🧰"])
        await harness.answer(Self.glue)
        #expect(harness.telemetry.events.first?.payload["queryLength"] == .int(7))
    }

    @Test("searches the trimmed words; spaces around them do not search again")
    func trims() async throws {
        let harness = Harness()
        try await harness.type("  glue ")
        await harness.searches.waitForCalls(1)
        await harness.answer(Self.glue)
        harness.model.setQuery(" glue  ")
        await ShellWait.settle()
        #expect(harness.searches.callCount == 1)
        #expect(harness.model.query == " glue  ")
        #expect(harness.model.trimmed == "glue")
    }

    @Test("an empty field never searches")
    func emptyNeverSearches() async {
        let harness = Harness()
        harness.model.setQuery("   ")
        harness.model.focusChanged(true)
        harness.model.retry()
        await ShellWait.settle()
        #expect(harness.searches.callCount == 0)
        #expect(!harness.model.pending)
        #expect(harness.clock.pendingSleeperCount == 0)
    }

    @Test("feeds the found items' categories to the category memory")
    func remembersCategories() async throws {
        let harness = Harness()
        try await harness.type("glue")
        await harness.searches.waitForCalls(1)
        await harness.answer(Self.glue)
        #expect(harness.categories.events == ["Craft"])
    }

    @Test("the search key speaks the summary when the results are in")
    func submitAnnounces() async throws {
        let harness = Harness()
        harness.model.submit()
        #expect(harness.spoken.events.isEmpty)
        try await harness.type("tape")
        await harness.searches.waitForCalls(1)
        await harness.answer(Self.tape)
        harness.model.submit()
        #expect(harness.spoken.events == [L10n.Search.summary(items: 1, places: 1)])
        #expect(harness.spoken.events == ["1 item and 1 place found"])
    }

    @Test("pressed before the results are in, the summary is spoken when they arrive")
    func submitWhilePending() async throws {
        let harness = Harness()
        harness.model.setQuery("tape")
        harness.model.submit()
        #expect(harness.spoken.events.isEmpty)
        try await harness.clock.waitForSleepers()
        await harness.clock.advance(by: .milliseconds(200))
        await harness.searches.waitForCalls(1)
        await harness.answer(Self.tape)
        #expect(harness.spoken.events == ["1 item and 1 place found"])
    }

    @Test("typing again takes back a summary still waiting; a failure takes it back unspoken")
    func pendingSummaryCancelled() async throws {
        let harness = Harness()
        harness.model.setQuery("tape")
        harness.model.submit()
        harness.model.setQuery("tapes")
        try await harness.clock.waitForSleepers()
        await harness.clock.advance(by: .milliseconds(200))
        await harness.searches.waitForCalls(1)
        await harness.answer(Self.tape)
        #expect(harness.spoken.events.isEmpty)

        harness.model.setQuery("glue")
        harness.model.submit()
        try await harness.clock.waitForSleepers()
        await harness.clock.advance(by: .milliseconds(200))
        await harness.searches.waitForCalls(2)
        await harness.failNewest()
        #expect(harness.spoken.events.isEmpty)
        harness.model.retry()
        await harness.searches.waitForCalls(3)
        await harness.answer(Self.glue)
        #expect(harness.spoken.events.isEmpty)
    }

    @Test("a new search closure is used from the next search and searches nothing by itself")
    func setSearch() async throws {
        let harness = Harness()
        try await harness.type("glue")
        await harness.searches.waitForCalls(1)
        await harness.answer(Self.glue)
        let household = ShellQueuedReads<SearchResults>(Self.tape)
        harness.model.setSearch { try household.call($0) }
        await ShellWait.settle()
        #expect(household.callCount == 0)
        await harness.model.refresh()
        #expect(household.arguments == ["glue"])
        #expect(harness.model.results == Self.tape)
    }
}
