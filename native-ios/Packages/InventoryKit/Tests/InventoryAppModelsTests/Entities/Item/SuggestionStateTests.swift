import Foundation
import InventoryNetwork
import InventoryStrings
import Testing
@testable import InventoryAppModels

/// `src/ui/components/__tests__/SuggestionBanner.test.tsx` › staleSuggestionName.
@Suite("staleSuggestionName (SuggestionBanner.test.tsx)")
struct EntitiesStaleSuggestionNameTests {
    private let applied = SuggestionState.applied(confidence: 0.9, forName: "Cordless drill")

    @Test("is null while the title still matches what the details describe")
    func matches() {
        #expect(applied.staleName(typed: "Cordless drill") == nil)
        #expect(applied.staleName(typed: "  Cordless drill  ") == nil)
    }

    @Test("reports the corrected title once it diverges from ours")
    func diverges() {
        #expect(applied.staleName(typed: "Angle grinder") == "Angle grinder")
    }

    @Test("goes stale again after a refresh")
    func afterRefresh() {
        let refreshed = SuggestionState.refreshed(forName: "Angle grinder")
        #expect(refreshed.staleName(typed: "Angle grinder") == nil)
        #expect(refreshed.staleName(typed: "Bench grinder") == "Bench grinder")
    }

    @Test("offers nothing to refresh when the title has been cleared")
    func cleared() {
        #expect(applied.staleName(typed: "") == nil)
        #expect(applied.staleName(typed: "   ") == nil)
    }

    @Test("offers nothing to refresh when no suggestion was applied")
    func notApplied() {
        #expect(SuggestionState.idle.staleName(typed: "Angle grinder") == nil)
        #expect(SuggestionState.running.staleName(typed: "Angle grinder") == nil)
        #expect(SuggestionState.refreshing.staleName(typed: "Angle grinder") == nil)
        #expect(SuggestionState.failed(.offline).staleName(typed: "Angle grinder") == nil)
    }
}

@Suite("suggestion banner (SuggestionBanner.tsx)")
struct EntitiesSuggestionBannerTests {
    @Test("the banner shows the typed name as stale, and the stored state otherwise")
    func bannerState() {
        let applied = SuggestionState.applied(confidence: 0.9, forName: "Cordless drill")
        #expect(applied.banner(typed: "Angle grinder") == .stale(forName: "Angle grinder"))
        #expect(applied.banner(typed: "Cordless drill") == applied)
        #expect(SuggestionState.running.banner(typed: "Angle grinder") == .running)
    }

    @Test("copy per state: none when idle, update only when stale, retry unless not configured")
    func copy() {
        #expect(SuggestionState.idle.bannerCopy == nil)
        #expect(SuggestionState.running.bannerCopy?.message == L10n.Suggestions.running)
        #expect(SuggestionState.refreshing.bannerCopy?.message == L10n.Suggestions.refreshing)
        let applied = SuggestionState.applied(confidence: 0.9, forName: "Drill").bannerCopy
        #expect(applied?.title == L10n.Suggestions.applied)
        #expect(applied?.message == L10n.Suggestions.check)
        #expect(SuggestionState.refreshed(forName: "Drill").bannerCopy?.title == L10n.Suggestions.refreshed(name: "Drill"))
        let stale = SuggestionState.stale(forName: "Drill").bannerCopy
        #expect(stale?.title == L10n.Suggestions.stale(name: "Drill"))
        #expect(stale?.message == L10n.Suggestions.staleBody)
        #expect(stale?.action == .update)
        #expect(stale?.action?.hint == L10n.Suggestions.updateHint)
        #expect(stale?.announced == false)
        let failed = SuggestionState.failed(.offline).bannerCopy
        #expect(failed?.title == L10n.Suggestions.failed)
        #expect(failed?.message == L10n.Suggestions.FailedBody.offline)
        #expect(failed?.action == .retry)
        #expect(failed?.isFailure == true)
        #expect(SuggestionState.failed(.notConfigured).bannerCopy?.action == nil)
    }

    @Test("every failure reason has its strings.ts body")
    func failedBodies() {
        for reason in RecognitionFailureReason.allCases {
            #expect(SuggestionState.failedBody(reason) == L10n.Suggestions.FailedBody[reason.rawValue], "\(reason)")
        }
    }
}

@Suite("staleSuggestionName parity (Fixtures/entities)")
struct EntitiesStaleParityTests {
    struct State: Decodable {
        let status: String
        let forName: String?
        let reason: String?
        let confidence: Double?

        var state: SuggestionState {
            switch status {
            case "running": .running
            case "refreshing": .refreshing
            case "applied": .applied(confidence: confidence ?? 0, forName: forName ?? "")
            case "refreshed": .refreshed(forName: forName ?? "")
            case "failed": .failed(RecognitionFailureReason(rawValue: reason ?? "") ?? .offline)
            default: .idle
            }
        }
    }

    struct Case: Decodable {
        let state: State
        let typed: String
        let expected: String?
    }

    struct Fixture: Decodable {
        let staleSuggestionName: [Case]
    }

    @Test("matches JS, telling canonically equivalent names apart as === does")
    func matches() throws {
        let url = try #require(Bundle.module.url(forResource: "entities-vectors", withExtension: "json", subdirectory: "Fixtures/entities"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        for vector in fixture.staleSuggestionName {
            let actual = vector.state.state.staleName(typed: vector.typed)
            #expect(EntitiesUnits.of(actual) == EntitiesUnits.of(vector.expected), "\(vector.state) \(Array(vector.typed.unicodeScalars))")
        }
    }
}
