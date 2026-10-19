import Foundation
import InventoryCore
import InventoryNetwork
import InventoryStrings
import Testing
@testable import InventoryAppModels

// RN: src/ui/household/__tests__/join.test.ts (validateJoin, suggestedPhoneName; codeProblem,
// joinFailure and serverHost are ported with InventoryCore) and
// src/ui/household/__tests__/status.test.ts (the device half; the backup half is in
// Sync/SyncModelTests.swift).

private let code = "MMWKY-M2H78-ABCDE-FGHJK-MNPQR-S"

@Suite("validateJoin")
struct HouseholdValidateJoinTests {
    @Test("passes a full code and a name")
    func passesAFullCodeAndAName() {
        #expect(validateJoin(normaliseCode(code), name: "Kitchen iPhone") == JoinErrors())
        #expect(validateJoin(normaliseCode(code), name: "Kitchen iPhone").isEmpty)
    }

    @Test("puts each problem under its own field")
    func putsEachProblemUnderItsOwnField() {
        #expect(validateJoin("ABC", name: "   ") == JoinErrors(code: L10n.Join.wrongLength(count: 3), name: L10n.Join.nameRequired))
        #expect(validateJoin(normaliseCode("MMWKU"), name: "Anna").code == L10n.Join.badChars(chars: "U"))
    }

    @Test("asks for an empty code, saying where it comes from, rather than counting it")
    func asksForAnEmptyCode() {
        #expect(validateJoin("", name: "Anna").code == L10n.Join.codeRequired)
    }

    // join.ts:40-50: a name of JS white space only is missing; characters come before length.
    @Test("a name of any JS white space is missing; characters no code uses come before a wrong length")
    func edges() {
        #expect(validateJoin(normaliseCode(code), name: "\u{3000}\u{FEFF}\n").name == L10n.Join.nameRequired)
        #expect(validateJoin("MMWKY%", name: "A").code == L10n.Join.badChars(chars: "%"))
    }
}

@Suite("suggestedPhoneName")
struct HouseholdSuggestedPhoneNameTests {
    @Test("keeps a real phone name")
    func keepsARealPhoneName() {
        #expect(suggestedPhoneName("Anna’s iPhone") == "Anna’s iPhone")
        #expect(suggestedPhoneName("  Pixel 8 ") == "Pixel 8")
    }

    @Test("skips generic and missing names")
    func skipsGenericAndMissingNames() {
        #expect(suggestedPhoneName("iPhone") == "")
        #expect(suggestedPhoneName("IPAD") == "")
        #expect(suggestedPhoneName("android") == "")
        #expect(suggestedPhoneName(nil) == "")
        #expect(suggestedPhoneName(" iPhone ") == "")
    }
}

// status.test.ts

private let now: Int64 = 1_790_942_400_000  // Date.UTC(2026, 9, 2, 12)
private let day: Int64 = 24 * 60 * 60 * 1000

// The backup half of status.test.ts (backupSummary, showBackupRow, backupReason) is ported
// with SyncStatus in Sync/SyncModelTests.swift.

@Suite("devices")
struct HouseholdDeviceStatusTests {
    private let mine = HouseholdDevice(id: "b", name: "Anna’s iPhone", createdAt: 2, lastSeenAt: now)
    private let owner = HouseholdDevice(id: "a", name: "Kitchen iPhone", createdAt: 1, lastSeenAt: now - 3 * day)
    private let spare = HouseholdDevice(id: "c", name: "Old iPad", createdAt: 3, lastSeenAt: nil)

    @Test("describes each phone")
    func describesEachPhone() {
        #expect(HouseholdStatus.deviceMeta(mine, thisDeviceId: "b", now: now) == L10n.Household.thisPhone)
        #expect(HouseholdStatus.deviceMeta(owner, thisDeviceId: "b", now: now) == L10n.Household.lastUsed(ago: "3 days ago"))
        #expect(HouseholdStatus.deviceMeta(spare, thisDeviceId: "b", now: now) == L10n.Household.neverUsed)
    }

    @Test("lists this phone first, then the rest in the order they joined")
    func listsThisPhoneFirst() {
        #expect(HouseholdStatus.sortDevices([owner, mine, spare], thisDeviceId: "b").map(\.id) == ["b", "a", "c"])
        #expect(HouseholdStatus.sortDevices([owner, spare], thisDeviceId: "b").map(\.id) == ["a", "c"])
    }
}
