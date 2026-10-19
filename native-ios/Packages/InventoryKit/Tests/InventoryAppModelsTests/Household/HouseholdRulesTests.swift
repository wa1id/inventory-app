import Foundation
import InventoryCore
import InventoryNetwork
import InventoryStrings
import Testing
@testable import InventoryAppModels

// RN: src/ui/household/__tests__/join.test.ts (validateJoin, suggestedPhoneName; codeProblem,
// joinFailure and serverHost are ported with InventoryCore) and
// src/ui/household/__tests__/status.test.ts (all of it).

private let code = "MMWKY-M2H78-ABCDE-FGHJK-MNPQR-S"

@Suite("validateJoin")
struct ValidateJoinTests {
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
struct SuggestedPhoneNameTests {
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

private let off = HouseholdStatus.BackupState.off
private let unavailable = HouseholdStatus.BackupState.unavailable
private let idle = HouseholdStatus.BackupState.idle(lastBackupAt: Double(now - day))
private let neverRun = HouseholdStatus.BackupState.idle(lastBackupAt: nil)
private let working = HouseholdStatus.BackupState.working
private let failed = HouseholdStatus.BackupState.error

@Suite("backupSummary")
struct BackupSummaryTests {
    @Test("always has a value, including Off")
    func alwaysHasAValueIncludingOff() {
        typealias Copy = L10n.Settings.BackupSummary
        #expect(HouseholdStatus.backupSummary(unavailable) == .init(value: Copy.notConfigured, tone: .ink))
        #expect(HouseholdStatus.backupSummary(off) == .init(value: Copy.off, tone: .ink))
        #expect(HouseholdStatus.backupSummary(working) == .init(value: Copy.working, tone: .ink))
        #expect(HouseholdStatus.backupSummary(neverRun) == .init(value: Copy.notYetRun, tone: .ink))
        #expect(HouseholdStatus.backupSummary(idle) == .init(value: Copy.on, tone: .ink))
    }

    @Test("marks a failed backup in signal")
    func marksAFailedBackupInSignal() {
        #expect(HouseholdStatus.backupSummary(failed) == .init(value: L10n.Settings.BackupSummary.attention, tone: .signal))
    }
}

@Suite("showBackupRow")
struct ShowBackupRowTests {
    @Test("always shows backup on a phone that keeps its own inventory")
    func alwaysShowsBackupOnAPhoneThatKeepsItsOwnInventory() {
        for state in [off, unavailable, idle, failed] {
            #expect(HouseholdStatus.showBackupRow(paired: false, state))
        }
    }

    @Test("hides it on a joined phone that never set it up (#48)")
    func hidesItOnAJoinedPhoneThatNeverSetItUp() {
        #expect(!HouseholdStatus.showBackupRow(paired: true, off))
        #expect(!HouseholdStatus.showBackupRow(paired: true, unavailable))
    }

    @Test("keeps it on a joined phone that has a backup account")
    func keepsItOnAJoinedPhoneThatHasABackupAccount() {
        for state in [idle, neverRun, working, failed] {
            #expect(HouseholdStatus.showBackupRow(paired: true, state))
        }
    }
}

@Suite("backupReason")
struct BackupReasonTests {
    @Test("has plain words for every failure")
    func hasPlainWordsForEveryFailure() {
        typealias Copy = L10n.Backup.Reasons
        #expect(HouseholdStatus.backupReason(.malformed) == Copy.malformed)
        #expect(HouseholdStatus.backupReason(.sync(.notFound)) == Copy.notFound)
        #expect(HouseholdStatus.backupReason(.sync(.quotaExceeded)) == Copy.quotaExceeded)
        #expect(HouseholdStatus.backupReason(.sync(.serverError)) == Copy.other)
        #expect(HouseholdStatus.backupReason(.sync(.malformedResponse)) == Copy.other)
        #expect(HouseholdStatus.backupReason(.sync(.noAccount)) == Copy.other)
    }

    @Test("never shows a raw reason code")
    func neverShowsARawReasonCode() {
        let problems = [HouseholdStatus.BackupProblem.malformed] + SyncFailureReason.allCases.map(HouseholdStatus.BackupProblem.sync)
        #expect(problems.count == 12)
        for problem in problems {
            #expect(!HouseholdStatus.backupReason(problem).contains("_"), "\(problem)")
        }
    }

    // status.ts:51-76, one by one.
    @Test("each reason has its own words", arguments: [
        (SyncFailureReason.offline, L10n.Backup.Reasons.offline),
        (.timeout, L10n.Backup.Reasons.timeout),
        (.unauthorized, L10n.Backup.Reasons.unauthorized),
        (.tooLarge, L10n.Backup.Reasons.tooLarge),
        (.corrupted, L10n.Backup.Reasons.corrupted),
        (.notConfigured, L10n.Backup.Reasons.notConfigured),
    ])
    func reasons(reason: SyncFailureReason, words: String) {
        #expect(HouseholdStatus.backupReason(.sync(reason)) == words)
    }
}

@Suite("devices")
struct DeviceStatusTests {
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
