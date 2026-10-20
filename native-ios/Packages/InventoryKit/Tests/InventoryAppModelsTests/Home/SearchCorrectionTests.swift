import InventoryCore
import InventoryStrings
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// Native only: a query that finds nothing is corrected against the inventory's own words and
/// searched again (``SearchModel/correction``).
@Suite("SearchModel corrections")
@MainActor
struct SearchCorrectionTests {
    private typealias Fixtures = ShellFixtures

    private static let drill = Fixtures.results([Fixtures.hit("d", name: "Cordless drill")], terms: ["drill"])
    private static let none = Fixtures.results([], terms: ["x"])

    /// Searches answered at once from `answers` (anything else finds nothing), on a manual clock.
    @MainActor
    private final class Harness {
        let clock = ManualClock()
        let telemetry = RecordingTelemetry()
        let spoken = ShellEventLog()
        let searched = ShellEventLog()
        let vocabularyReads = ShellEventLog()
        let model: SearchModel

        init(answers: [String: SearchResults], words: [String: Int]?, vocabularyFails: Bool = false) {
            let searched = searched
            let reads = vocabularyReads
            let spoken = spoken
            let empty = SearchCorrectionTests.none
            var vocabulary: SearchModel.Vocabulary?
            if let words {
                vocabulary = { @Sendable in
                    reads.record("read")
                    if vocabularyFails { throw ShellTestError("vocabulary") }
                    return SearchVocabulary(counts: words)
                }
            }
            model = SearchModel(
                clock: clock, telemetry: TelemetryReporter(sink: telemetry),
                announce: { spoken.record($0) },
                vocabulary: vocabulary,
                search: { query in
                    searched.record(query)
                    return answers[query] ?? empty
                })
        }

        /// Types `text`, lets the debounce pass and waits for the answer.
        func type(_ text: String) async throws {
            model.setQuery(text)
            try await clock.waitForSleepers()
            await clock.advance(by: .milliseconds(200))
            await model.searchTask?.value
        }
    }

    @Test("a misspelt query that finds nothing shows the corrected query's results, saying so")
    func corrects() async throws {
        let harness = Harness(answers: ["drill": Self.drill], words: ["drill": 1, "cordless": 1])
        try await harness.type("drils")
        #expect(harness.searched.events == ["drils", "drill"])
        #expect(harness.model.results == Self.drill)
        #expect(harness.model.correction == SearchModel.Correction(typed: "drils", shown: "drill"))
        #expect(!harness.model.pending)
        let logged = harness.telemetry.events.filter { $0.name == "search_performed" }
        #expect(logged.map { $0.payload["outcome"] } == [.string("corrected")])
    }

    @Test("the search key says what was searched instead before the summary")
    func announcesCorrection() async throws {
        let harness = Harness(answers: ["drill": Self.drill], words: ["drill": 1])
        try await harness.type("drils")
        harness.model.submit()
        #expect(harness.spoken.events == [
            L10n.Search.Corrected.showing(typed: "drils", shown: "drill") + " " + L10n.Search.summary(items: 1, places: 0),
        ])
    }

    @Test("a query that finds something is never corrected, and reads no words")
    func exactFirst() async throws {
        let harness = Harness(answers: ["drill": Self.drill], words: ["drill": 1])
        try await harness.type("drill")
        #expect(harness.searched.events == ["drill"])
        #expect(harness.model.correction == nil)
        #expect(harness.vocabularyReads.events.count == 0)
        #expect(harness.telemetry.events.first { $0.name == "search_performed" }?.payload["outcome"] == nil)
    }

    @Test("when the corrected query finds nothing either, the answer is the empty one")
    func correctionFindsNothing() async throws {
        let harness = Harness(answers: [:], words: ["drill": 1])
        try await harness.type("drils")
        #expect(harness.searched.events == ["drils", "drill"])
        #expect(harness.model.results == Self.none)
        #expect(harness.model.correction == nil)
    }

    @Test("without a vocabulary, or when it cannot be read, nothing is corrected")
    func noVocabulary() async throws {
        let without = Harness(answers: ["drill": Self.drill], words: nil)
        try await without.type("drils")
        #expect(without.searched.events == ["drils"])
        #expect(without.model.correction == nil)

        let failing = Harness(answers: ["drill": Self.drill], words: ["drill": 1], vocabularyFails: true)
        try await failing.type("drils")
        #expect(failing.searched.events == ["drils"])
        #expect(failing.model.results == Self.none)
        #expect(failing.model.cause == nil)
    }

    @Test("the words are read once per revision")
    func vocabularyCached() async throws {
        let harness = Harness(answers: ["drill": Self.drill], words: ["drill": 1])
        try await harness.type("drils")
        try await harness.type("drilk")
        #expect(harness.vocabularyReads.events.count == 1)
        harness.model.focusChanged(true, revision: 1)
        await harness.model.searchTask?.value
        #expect(harness.vocabularyReads.events.count == 2)
    }

    @Test("Home shows what was searched instead above the results, even with one section")
    func homeListSummary() {
        let correction = SearchModel.Correction(typed: "drils", shown: "drill")
        let entries = HomeList.resultEntries(Self.drill, refreshFailed: false, correction: correction)
        #expect(entries.first == .summary(text: L10n.Search.Corrected.showing(typed: "drils", shown: "drill")))
        #expect(HomeList.resultEntries(Self.drill, refreshFailed: false).contains { $0.kind == .summary } == false)
    }
}
