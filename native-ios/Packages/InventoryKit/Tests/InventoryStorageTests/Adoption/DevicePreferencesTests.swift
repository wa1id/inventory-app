import Foundation
import Testing
@testable import InventoryStorage

struct StringVector<Expected: Decodable & Sendable>: Decodable, Sendable, CustomTestStringConvertible {
    let input: String
    let expected: Expected
    var stored: String? { input == "<absent>" ? nil : input }
    var testDescription: String { input.debugDescription }
}

@Suite("OnboardingPreference (onboarding.ts)")
struct OnboardingPreferenceTests {
    @Test("completed only for exactly \"true\" (TS vectors)")
    func vectors() throws {
        for vector in try AdoptionFixtures.decode([StringVector<Bool>].self, from: "onboarding-vectors.json") {
            let preferences = InMemoryPreferences(vector.stored.map { [PreferenceKey.onboardingCompleted: $0] } ?? [:])
            #expect(OnboardingPreference(preferences: preferences).isCompleted == vector.expected, "\(vector.input)")
        }
    }

    @Test("complete writes \"true\"; replay removes the key")
    func writes() {
        let preferences = InMemoryPreferences()
        let onboarding = OnboardingPreference(preferences: preferences)
        onboarding.setCompleted(true)
        #expect(preferences.values == [PreferenceKey.onboardingCompleted: "true"])
        #expect(onboarding.isCompleted)
        onboarding.setCompleted(false)
        #expect(preferences.values.isEmpty)
        #expect(!onboarding.isCompleted)
    }
}

@Suite("UnpairedNoticePreference (unpairedNotice.ts)")
struct UnpairedNoticePreferenceTests {
    @Test("dismissed only for exactly \"1\"", arguments: [
        ("1", true), ("true", false), ("01", false), (" 1", false), ("", false),
    ])
    func dismissedValues(stored: String, dismissed: Bool) {
        let preferences = InMemoryPreferences([PreferenceKey.unpairedNoticeDismissed: stored])
        #expect(UnpairedNoticePreference(preferences: preferences).isDismissed == dismissed)
    }

    @Test("absent is not dismissed; dismiss persists \"1\"")
    func dismiss() {
        let preferences = InMemoryPreferences()
        let notice = UnpairedNoticePreference(preferences: preferences)
        #expect(!notice.isDismissed)
        notice.dismiss()
        #expect(preferences.values == [PreferenceKey.unpairedNoticeDismissed: "1"])
        #expect(notice.isDismissed)
    }
}

@Suite("LastBackupPreference (backup.ts)")
struct LastBackupPreferenceTests {
    @Test("reads like lastBackupAt(): stored ? Number(stored) : NaN, finite only (TS vectors)")
    func vectors() throws {
        for vector in try AdoptionFixtures.decode([StringVector<Double?>].self, from: "last-backup-vectors.json") {
            let preferences = InMemoryPreferences(vector.stored.map { [PreferenceKey.lastBackupAt: $0] } ?? [:])
            #expect(LastBackupPreference(preferences: preferences).lastBackupAt == vector.expected, "\(vector.input.debugDescription)")
        }
    }

    @Test("02 §11.2 #4 cases", arguments: [
        ("", nil), ("abc", nil), (" 1754236800000 ", 1_754_236_800_000),
    ] as [(String, Double?)])
    func specCases(stored: String, expected: Double?) {
        let preferences = InMemoryPreferences([PreferenceKey.lastBackupAt: stored])
        #expect(LastBackupPreference(preferences: preferences).lastBackupAt == expected)
    }

    @Test("records the integer form, never with a .0 suffix")
    func records() {
        let preferences = InMemoryPreferences()
        let marker = LastBackupPreference(preferences: preferences)
        marker.recordBackup(at: 1_754_236_800_000)
        #expect(preferences.values == [PreferenceKey.lastBackupAt: "1754236800000"])
        #expect(marker.lastBackupAt == 1_754_236_800_000)
    }

    // The preference halves of backup.test.ts › maybeBackup; the 15-minute gate itself is the
    // sync area's (03 §5.4).
    @Test("backs up when nothing has been backed up yet: no marker reads as nil")
    func nothingBackedUp() {
        #expect(LastBackupPreference(preferences: InMemoryPreferences()).lastBackupAt == nil)
    }

    @Test("skips a backup taken too recently: the recorded capturedAt reads back")
    func recordedReadsBack() {
        let marker = LastBackupPreference(preferences: InMemoryPreferences())
        marker.recordBackup(at: 1_000)
        #expect(marker.lastBackupAt == 1_000)
        marker.recordBackup(at: 2_000)
        #expect(marker.lastBackupAt == 2_000)
    }
}

@Suite("HouseholdJoinPreferences (importOffer.ts)")
struct HouseholdJoinPreferencesTests {
    struct Offer: Decodable, Sendable { let spaces: Double; let items: Double }

    @Test("reads like readImportOffer() (TS vectors)")
    func vectors() throws {
        for vector in try AdoptionFixtures.decode([StringVector<Offer?>].self, from: "import-offer-vectors.json") {
            let preferences = InMemoryPreferences([PreferenceKey.householdImportOffer: vector.input])
            let expected = vector.expected.map { ImportOffer(spaces: Int($0.spaces), items: Int($0.items)) }
            #expect(HouseholdJoinPreferences(preferences: preferences).importOffer == expected, "\(vector.input)")
        }
    }

    @Test("02 §11.2 #4: a string count is no offer")
    func stringCount() {
        let preferences = InMemoryPreferences([PreferenceKey.householdImportOffer: #"{"spaces":1,"items":"2"}"#])
        #expect(HouseholdJoinPreferences(preferences: preferences).importOffer == nil)
    }

    @Test("a non-integral count is no offer (documented narrowing of RN's number check)")
    func nonIntegral() {
        let preferences = InMemoryPreferences([PreferenceKey.householdImportOffer: #"{"spaces":1.5,"items":2}"#])
        #expect(HouseholdJoinPreferences(preferences: preferences).importOffer == nil)
    }

    @Test("snapshotBeforeJoin stores the counts as JSON.stringify writes them")
    func storesCounts() async {
        let preferences = InMemoryPreferences()
        await HouseholdJoinPreferences(preferences: preferences).snapshotBeforeJoin { (3, 41) }
        #expect(preferences.values == [PreferenceKey.householdImportOffer: #"{"spaces":3,"items":41}"#])
        #expect(HouseholdJoinPreferences(preferences: preferences).importOffer == ImportOffer(spaces: 3, items: 41))
    }

    @Test("snapshotBeforeJoin clears the offer when there is nothing to copy")
    func zeroClears() async {
        let preferences = InMemoryPreferences([PreferenceKey.householdImportOffer: #"{"spaces":1,"items":1}"#])
        await HouseholdJoinPreferences(preferences: preferences).snapshotBeforeJoin { (0, 0) }
        #expect(preferences.values.isEmpty)
    }

    @Test("snapshotBeforeJoin never offers again on a phone that has joined before")
    func joinedBeforeShortCircuits() async {
        let preferences = InMemoryPreferences([PreferenceKey.householdJoinedBefore: "true"])
        let join = HouseholdJoinPreferences(preferences: preferences)
        await join.snapshotBeforeJoin {
            Issue.record("counted although the phone joined before")
            return (5, 5)
        }
        #expect(preferences.values == [PreferenceKey.householdJoinedBefore: "true"])
    }

    @Test("a failed count writes nothing and keeps an existing offer")
    func failedCount() async {
        struct CountFailed: Error {}
        let existing = #"{"spaces":2,"items":3}"#
        let preferences = InMemoryPreferences([PreferenceKey.householdImportOffer: existing])
        await HouseholdJoinPreferences(preferences: preferences).snapshotBeforeJoin { throw CountFailed() }
        #expect(preferences.values == [PreferenceKey.householdImportOffer: existing])
    }

    @Test("joined-before is exactly \"true\"; mark sets it; clear removes the offer")
    func markers() {
        let preferences = InMemoryPreferences([
            PreferenceKey.householdJoinedBefore: "1",
            PreferenceKey.householdImportOffer: #"{"spaces":1,"items":1}"#,
        ])
        let join = HouseholdJoinPreferences(preferences: preferences)
        #expect(!join.hasJoinedBefore)
        join.markJoinedBefore()
        #expect(join.hasJoinedBefore)
        join.clearImportOffer()
        #expect(join.importOffer == nil)
        #expect(preferences.values == [PreferenceKey.householdJoinedBefore: "true"])
    }
}
