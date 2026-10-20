import Foundation
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage
import InventoryStrings
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

// RN has no tests for app/backup.tsx; these pin 03 §9.2-9.5 on top of SyncModel (whose own
// tests cover the sync behaviour) and the native B8/B12 states the screen adds.

/// A different valid recovery code (16 bytes of 0x11).
private let accountOtherCode = "248H248H248H248H248H248H24"

/// A real SQLite snapshot holding one item, as a stored backup.
private func accountBackupSnapshot() async throws -> Data {
    let source = try DatabaseStore.temporary()
    let repos = try await LocalRepositories.initialize(source)
    _ = try await repos.items.create(ItemDraft(containerId: DropZone.containerId, name: "Cordless Drill"))
    return try await source.snapshot()
}

/// The screen model over a SyncModel harness, with recorders for its seams.
@MainActor
private struct AccountBackupFixture {
    let harness: SyncModelHarness
    let toasts = SharedSeamsToastRecorder()
    let confirms: SharedSeamsConfirmScript
    let haptics = SharedSeamsHapticRecorder()
    let announcements = AccountAnnouncementRecorder()
    let model: BackupScreenModel

    init(
        endpoint: String? = "https://sync.example",
        keychain: [String: String] = [:],
        preferences: [String: String] = [:],
        empty: Bool = false,
        confirms: [Bool] = [true]
    ) async throws {
        harness = try await SyncModelHarness(endpoint: endpoint, keychain: keychain, preferences: preferences, empty: empty)
        self.confirms = SharedSeamsConfirmScript(answers: confirms)
        let announcements = announcements
        model = BackupScreenModel(
            sync: harness.model,
            toasts: toasts,
            confirm: self.confirms,
            haptics: haptics.player,
            announce: { announcements.record($0) }
        )
    }

    var sync: SyncModel { harness.model }
}

/// What a model announced to VoiceOver.
@MainActor
final class AccountAnnouncementRecorder {
    private(set) var texts: [String] = []

    func record(_ text: String) {
        texts.append(text)
    }
}

@MainActor
@Suite("Backup screen: what shows (app/backup.tsx:46-85)", .timeLimit(.minutes(1)))
struct AccountBackupBodyTests {
    @Test("a build without a backup service shows only the notice")
    func unavailable() async throws {
        let fixture = try await AccountBackupFixture(endpoint: nil)
        await fixture.harness.startReady()
        #expect(fixture.model.body == .unavailable)
    }

    @Test("no account: Turn on and Restore; an account: Backup is on")
    func offThenOn() async throws {
        let off = try await AccountBackupFixture()
        await off.harness.startReady()
        #expect(off.model.body == .off)

        let on = try await AccountBackupFixture(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code])
        await on.harness.startReady()
        #expect(on.model.body == .on)
    }

    @Test("a keychain that refused the read offers Try again instead of Turn on and Restore (03 B8)")
    func unreadable() async throws {
        let fixture = try await AccountBackupFixture(keychain: [KeychainKey.recoveryCode: accountOtherCode])
        fixture.harness.keychain.inner.failNextRead()
        await fixture.harness.startReady()
        #expect(fixture.model.body == .unreadable)

        await fixture.model.retryAccountLoad()
        #expect(fixture.model.body == .on)
        #expect(fixture.announcements.texts.isEmpty)
    }

    @Test("Try again that is refused again says so once more, with the error haptic")
    func unreadableAgain() async throws {
        let fixture = try await AccountBackupFixture(keychain: [KeychainKey.recoveryCode: accountOtherCode])
        fixture.harness.keychain.inner.failNextRead()
        await fixture.harness.startReady()
        fixture.harness.keychain.inner.failNextRead()

        await fixture.model.retryAccountLoad()

        #expect(fixture.model.body == .unreadable)
        #expect(fixture.announcements.texts == [L10n.Backup.Unreadable.title])
        #expect(fixture.haptics.played == [.error])
        #expect(!fixture.model.isRetryingAccountLoad)
    }

    @Test("the revealed code comes before everything but unavailable, and I have saved it puts it away")
    func revealedFirst() async throws {
        let fixture = try await AccountBackupFixture(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code])
        await fixture.harness.startReady()

        fixture.model.showCode()
        #expect(fixture.model.body == .revealed(BackupRevealedCode(code: SyncModelHarness.code)))
        fixture.model.saved()
        #expect(fixture.model.body == .on)
    }

    @Test("the code is shown in groups of five and spelt out for VoiceOver")
    func revealedFormats() {
        let code = BackupRevealedCode(code: SyncModelHarness.code)
        #expect(code.formatted == "89144-GJ289-144GJ-28914-4GJ28-8")
        #expect(code.spoken == "8 9 1 4 4, G J 2 8 9, 1 4 4 G J, 2 8 9 1 4, 4 G J 2 8, 8")
        #expect(!code.keptExistingCode)
    }

    @Test("a box too narrow for one line breaks the code only between groups")
    func revealedLines() {
        let lines = BackupRevealedCode(code: SyncModelHarness.code).formattedLines
        #expect(lines.one == "89144-GJ289-144GJ-28914-4GJ28-8")
        #expect(lines.two == "89144-GJ289-144GJ-\n28914-4GJ28-8")
        #expect(lines.each == "89144-\nGJ289-\n144GJ-\n28914-\n4GJ28-\n8")
        #expect(BackupRevealedCode(code: "ABCDE").formattedLines.two == "ABCDE")
    }
}

@MainActor
@Suite("Backup screen: Turn on (app/backup.tsx:114-142)", .timeLimit(.minutes(1)))
struct AccountBackupTurnOnTests {
    @Test("Turn on shows the new code at once")
    func revealsNewCode() async throws {
        let fixture = try await AccountBackupFixture()
        await fixture.harness.startReady()

        await fixture.model.turnOn()

        let stored = try #require(fixture.harness.keychain.values[KeychainKey.recoveryCode])
        #expect(fixture.model.revealed == BackupRevealedCode(code: stored))
        #expect(fixture.model.busy == nil)
        #expect(fixture.model.enableFailure == nil)
        fixture.model.saved()
        #expect(fixture.model.body == .on)
    }

    @Test("a first backup that failed still shows the code; then the error banner offers Try again")
    func failedFirstBackupStillReveals() async throws {
        let fixture = try await AccountBackupFixture()
        await fixture.harness.startReady()
        fixture.harness.worker.update { $0.offlineBackups = true }

        await fixture.model.turnOn()

        let stored = try #require(fixture.harness.keychain.values[KeychainKey.recoveryCode])
        #expect(fixture.model.revealed?.code == stored)
        fixture.model.saved()
        #expect(fixture.model.body == .on)
        #expect(fixture.model.errorReason == L10n.Backup.Reasons.offline)
        #expect(!fixture.model.showsBackUpNow)
        #expect(fixture.model.lastLine(now: 5_000) == nil)
    }

    @Test("nothing made before the database is open: the reason above the button")
    func notStarted() async throws {
        let fixture = try await AccountBackupFixture()
        await fixture.sync.start()

        await fixture.model.turnOn()

        #expect(fixture.model.revealed == nil)
        #expect(fixture.model.enableFailure == L10n.Backup.Reasons.notConfigured)
        #expect(fixture.model.body == .off)
    }

    @Test("a stored code found on an empty phone is kept and shown with the note, and Restore is offered (03 B8, B12)")
    func keptExistingCode() async throws {
        let fixture = try await AccountBackupFixture(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code], empty: true)
        let snapshot = try await accountBackupSnapshot()
        fixture.harness.worker.update { $0.backups = [.init(bytes: snapshot, schemaVersion: "7", capturedAt: 1000)] }
        fixture.harness.keychain.inner.failNextRead()
        await fixture.harness.startReady()

        await fixture.model.turnOn()

        #expect(fixture.model.revealed == BackupRevealedCode(code: SyncModelHarness.code, keptExistingCode: true))
        fixture.model.saved()
        #expect(fixture.model.showsRestoreOffer(localInventoryHasRows: false))
    }

    @Test("a keychain that cannot be read makes nothing and turns the screen to Try again")
    func unreadableAtTurnOn() async throws {
        let fixture = try await AccountBackupFixture(keychain: [KeychainKey.recoveryCode: accountOtherCode])
        fixture.harness.keychain.inner.failNextRead()
        await fixture.harness.startReady()
        fixture.harness.keychain.inner.failNextRead()

        await fixture.model.turnOn()

        #expect(fixture.model.revealed == nil)
        #expect(fixture.model.body == .unreadable)
        #expect(fixture.harness.keychain.values == [KeychainKey.recoveryCode: accountOtherCode])
    }

    @Test("Turn on spins and Restore takes no press meanwhile; a second Turn on does nothing")
    func busyWhileTurningOn() async throws {
        let fixture = try await AccountBackupFixture()
        await fixture.harness.startReady()
        fixture.model.updateCode(SyncModelHarness.code)
        let hold = fixture.harness.worker.hold("PUT", "/v1/backups")

        let turningOn = Task { await fixture.model.turnOn() }
        await hold.arrived()
        #expect(fixture.model.isTurningOn)
        #expect(fixture.model.restoreDisabled)
        #expect(!fixture.model.turnOnDisabled)
        await fixture.model.turnOn()
        await fixture.model.restore()
        #expect(fixture.confirms.asked.isEmpty)
        hold.release()
        await turningOn.value

        #expect(!fixture.model.isTurningOn)
        #expect(fixture.harness.worker.state.backups.count == 1)
    }
}

@MainActor
@Suite("Backup screen: Restore with a code (app/backup.tsx:144-192)", .timeLimit(.minutes(1)))
struct AccountBackupRestoreTests {
    @Test("characters no code uses are named under the field; a short code is not complete; neither asks", arguments: [
        ("MMWKU-M2H7%", L10n.Backup.badChars(chars: "U %")),
        ("89144-GJ289", L10n.Backup.Reasons.malformed),
    ])
    func mistyped(typed: String, message: String) async throws {
        let fixture = try await AccountBackupFixture()
        await fixture.harness.startReady()
        fixture.model.updateCode(typed)

        await fixture.model.restore()

        #expect(fixture.model.codeError == message)
        #expect(fixture.haptics.played == [.error])
        #expect(fixture.confirms.asked.isEmpty)
        #expect(fixture.harness.worker.server.requests.isEmpty)
    }

    @Test("the field keeps the code normalised; editing clears its error; Restore needs something typed")
    func editing() async throws {
        let fixture = try await AccountBackupFixture()
        await fixture.harness.startReady()
        #expect(fixture.model.restoreDisabled)

        fixture.model.updateCode("89144 gj289-1")
        #expect(fixture.model.code == "89144GJ2891")
        #expect(!fixture.model.restoreDisabled)
        await fixture.model.restore()
        #expect(fixture.model.codeError != nil)
        fixture.model.updateCode("89144GJ28914")
        #expect(fixture.model.codeError == nil)
    }

    @Test("Restore asks before replacing what is on this phone; Cancel changes nothing")
    func asksFirst() async throws {
        let fixture = try await AccountBackupFixture(confirms: [false])
        await fixture.harness.startReady()
        fixture.model.updateCode(SyncModelHarness.code)

        await fixture.model.restore()

        #expect(fixture.confirms.asked == [ConfirmOptions(
            title: L10n.Backup.restoreConfirmTitle,
            body: L10n.Backup.restoreConfirmBody,
            confirmLabel: L10n.Backup.restoreConfirm,
            destructive: true
        )])
        #expect(fixture.model.code == SyncModelHarness.code)
        #expect(fixture.harness.worker.server.requests.isEmpty)
        #expect(fixture.model.busy == nil)
    }

    @Test("a restore that worked clears the code, plays success and says so; backup is then on")
    func restores() async throws {
        let fixture = try await AccountBackupFixture()
        await fixture.harness.startReady()
        let snapshot = try await accountBackupSnapshot()
        fixture.harness.worker.update { $0.backups = [.init(bytes: snapshot, schemaVersion: "7", capturedAt: 1000)] }
        fixture.model.updateCode(RecoveryCode.format(SyncModelHarness.code).lowercased())

        await fixture.model.restore()

        #expect(fixture.model.code == "")
        #expect(fixture.model.codeError == nil)
        #expect(fixture.haptics.played == [.success])
        #expect(fixture.toasts.messages == [L10n.Backup.restored])
        #expect(fixture.model.body == .on)
        #expect(!fixture.model.isRestoring)
        #expect(fixture.model.busy == nil)
    }

    @Test("the form stays up while the restore runs")
    func formStaysUp() async throws {
        let fixture = try await AccountBackupFixture()
        await fixture.harness.startReady()
        let snapshot = try await accountBackupSnapshot()
        fixture.harness.worker.update { $0.backups = [.init(bytes: snapshot, schemaVersion: "7", capturedAt: 1000)] }
        let hold = fixture.harness.worker.hold("GET", "/v1/backups/latest")
        fixture.model.updateCode(SyncModelHarness.code)

        let restoring = Task { await fixture.model.restore() }
        await hold.arrived()
        #expect(fixture.model.body == .off)
        #expect(fixture.model.isRestoringFromCode)
        #expect(fixture.model.turnOnDisabled)
        hold.release()
        await restoring.value
        #expect(fixture.model.body == .on)
    }

    @Test("a restore that failed keeps the code under the reason, with the error haptic")
    func fails() async throws {
        let fixture = try await AccountBackupFixture()
        await fixture.harness.startReady()
        fixture.model.updateCode(SyncModelHarness.code)

        await fixture.model.restore()

        #expect(fixture.model.code == SyncModelHarness.code)
        #expect(fixture.model.codeError == L10n.Backup.Reasons.notFound)
        #expect(fixture.haptics.played == [.error])
        #expect(fixture.toasts.messages.isEmpty)
        #expect(fixture.model.body == .off)
    }

    @Test("a restore whose code the keychain would not keep says the inventory is back and backup is off")
    func codeNotKept() async throws {
        let fixture = try await AccountBackupFixture()
        await fixture.harness.startReady()
        let snapshot = try await accountBackupSnapshot()
        fixture.harness.worker.update { $0.backups = [.init(bytes: snapshot, schemaVersion: "7", capturedAt: 1000)] }
        fixture.harness.keychain.inner.failNextWrite()
        fixture.model.updateCode(SyncModelHarness.code)

        await fixture.model.restore()

        #expect(fixture.toasts.messages == [L10n.Backup.restoredCodeNotKept])
        #expect(fixture.haptics.played == [.success])
        #expect(fixture.model.body == .off)
        #expect(fixture.model.code == "")
    }

    @Test("a restore that found another code on this phone changes nothing and says so on Backup is on (03 B8)")
    func anotherCodeStored() async throws {
        let fixture = try await AccountBackupFixture(keychain: [KeychainKey.recoveryCode: accountOtherCode])
        fixture.harness.keychain.inner.failNextRead()
        await fixture.harness.startReady()
        // The load is retried on the next activation; a restore typed before then finds the code.
        #expect(fixture.model.body == .unreadable)
        fixture.model.updateCode(SyncModelHarness.code)

        await fixture.model.restore()

        #expect(fixture.model.body == .on)
        #expect(fixture.model.notice == L10n.Backup.accountAlreadyOnThisPhone)
        #expect(fixture.haptics.played == [.warning])
        #expect(fixture.harness.keychain.values == [KeychainKey.recoveryCode: accountOtherCode])
        fixture.model.dismissNotice()
        #expect(fixture.model.notice == nil)
    }

    @Test("one guard: while the question is up, neither button starts anything")
    func guardDuringQuestion() async throws {
        let fixture = try await AccountBackupFixture()
        await fixture.harness.startReady()
        fixture.model.updateCode(SyncModelHarness.code)
        let question = AccountHeldConfirm()
        let model = BackupScreenModel(
            sync: fixture.sync, toasts: fixture.toasts, confirm: question, haptics: fixture.haptics.player, announce: { _ in })
        model.updateCode(SyncModelHarness.code)

        let restoring = Task { await model.restore() }
        await question.asked()
        // The buttons only look busy once the question is answered.
        #expect(model.busy == nil)
        await model.turnOn()
        await model.restore()
        #expect(fixture.harness.keychain.values.isEmpty)
        #expect(question.count == 1)
        question.answer(false)
        await restoring.value
        #expect(fixture.harness.worker.server.requests.isEmpty)
    }
}

@MainActor
@Suite("Backup screen: Backup on (app/backup.tsx:280-378)", .timeLimit(.minutes(1)))
struct AccountBackupOnTests {
    @Test("the status line: Backing up…, No backup has finished yet., Last backup …, nothing under an error")
    func lastLine() async throws {
        let fixture = try await AccountBackupFixture(
            keychain: [KeychainKey.recoveryCode: SyncModelHarness.code],
            preferences: [PreferenceKey.lastBackupAt: "1000"]
        )
        await fixture.harness.startReady()
        #expect(fixture.model.lastLine(now: 1000 + 5 * 60_000) == L10n.Backup.lastBackup(ago: Format.ago(1000, now: 1000 + 5 * 60_000)))
        #expect(fixture.model.showsBackUpNow)
        #expect(!fixture.model.isBackingUp)

        let hold = fixture.harness.worker.hold("PUT", "/v1/backups")
        let running = Task { await fixture.model.backUpNow() }
        await hold.arrived()
        #expect(fixture.model.lastLine(now: 0) == L10n.Backup.working)
        #expect(fixture.model.isBackingUp)
        // One press at a time: the second waits for nothing and starts nothing.
        await fixture.model.backUpNow()
        hold.release()
        await running.value
        #expect(fixture.harness.worker.state.backups.count == 1)

        fixture.harness.worker.update { $0.offlineBackups = true }
        await fixture.model.backUpNow()
        #expect(fixture.model.lastLine(now: 0) == nil)
        #expect(fixture.model.errorReason == L10n.Backup.Reasons.offline)
    }

    @Test("a finished backup is said once, with its line; a failure is left to its banner")
    func announcesCompletion() async throws {
        let fixture = try await AccountBackupFixture(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code])
        await fixture.harness.startReady()
        let account = SyncModelHarness.account

        #expect(fixture.model.statusAnnouncement(
            from: .working(account: account), to: .idle(account: account, lastBackupAt: 1000), now: 1000) == L10n.Backup.lastBackup(ago: Format.ago(1000, now: 1000)))
        #expect(fixture.model.statusAnnouncement(
            from: .working(account: account), to: .idle(account: account, lastBackupAt: nil), now: 1000) == L10n.Backup.noBackupYet)
        #expect(fixture.model.statusAnnouncement(
            from: .working(account: account), to: .error(account: account, reason: .offline), now: 1000) == nil)
        #expect(fixture.model.statusAnnouncement(
            from: .idle(account: account, lastBackupAt: 1), to: .idle(account: account, lastBackupAt: 2), now: 1000) == nil)
    }

    @Test("Show recovery code shows this account's code")
    func showsCode() async throws {
        let fixture = try await AccountBackupFixture(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code])
        await fixture.harness.startReady()
        fixture.model.showCode()
        #expect(fixture.model.revealed == BackupRevealedCode(code: SyncModelHarness.code))
    }
}

@MainActor
@Suite("Backup screen: the Restore offer (03 B12)", .timeLimit(.minutes(1)))
struct AccountBackupRestoreOfferTests {
    private func offered() async throws -> AccountBackupFixture {
        let fixture = try await AccountBackupFixture(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code], empty: true)
        let snapshot = try await accountBackupSnapshot()
        fixture.harness.worker.update { $0.backups = [.init(bytes: snapshot, schemaVersion: "7", capturedAt: 1000)] }
        await fixture.harness.startReady()
        #expect(fixture.sync.suggestsRestore)
        return fixture
    }

    @Test("offered while this phone's inventory is empty, and gone once something is added")
    func visibility() async throws {
        let fixture = try await offered()
        #expect(fixture.model.body == .on)
        #expect(fixture.model.showsRestoreOffer(localInventoryHasRows: nil))
        #expect(fixture.model.showsRestoreOffer(localInventoryHasRows: false))
        #expect(!fixture.model.showsRestoreOffer(localInventoryHasRows: true))

        let plain = try await AccountBackupFixture(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code])
        await plain.harness.startReady()
        #expect(!plain.model.showsRestoreOffer(localInventoryHasRows: false))
    }

    @Test("restoring the saved copy asks first, says Restoring… meanwhile, then restores and says so")
    func restoresSavedCopy() async throws {
        let fixture = try await offered()
        let hold = fixture.harness.worker.hold("GET", "/v1/backups/latest")

        let restoring = Task { await fixture.model.restoreSavedCopy() }
        await hold.arrived()
        #expect(fixture.confirms.asked.map(\.title) == [L10n.Backup.restoreConfirmTitle])
        #expect(fixture.confirms.asked.first?.destructive == true)
        #expect(fixture.model.busy == .restoreOffer)
        #expect(fixture.model.lastLine(now: 0) == L10n.Backup.RestoreOffer.working)
        // Rows land mid-restore; the offer stays while its restore runs.
        #expect(fixture.model.showsRestoreOffer(localInventoryHasRows: true))
        // Its completion is the toast's, not the status line's.
        #expect(fixture.model.statusAnnouncement(
            from: .working(account: SyncModelHarness.account),
            to: .idle(account: SyncModelHarness.account, lastBackupAt: nil), now: 0) == nil)
        hold.release()
        await restoring.value

        #expect(try await fixture.harness.itemCount() == 1)
        #expect(fixture.toasts.messages == [L10n.Backup.restored])
        #expect(fixture.haptics.played == [.success])
        #expect(!fixture.sync.suggestsRestore)
        #expect(!fixture.model.showsRestoreOffer(localInventoryHasRows: true))
        #expect(fixture.model.busy == nil)
    }

    @Test("Cancel restores nothing")
    func cancelled() async throws {
        let fixture = try await AccountBackupFixture(
            keychain: [KeychainKey.recoveryCode: SyncModelHarness.code], empty: true, confirms: [false])
        let snapshot = try await accountBackupSnapshot()
        fixture.harness.worker.update { $0.backups = [.init(bytes: snapshot, schemaVersion: "7", capturedAt: 1000)] }
        await fixture.harness.startReady()

        await fixture.model.restoreSavedCopy()

        #expect(try await fixture.harness.itemCount() == 0)
        #expect(!fixture.harness.worker.requestLines.contains("GET /v1/backups/latest"))
        #expect(fixture.sync.suggestsRestore)
    }

    @Test("a failed restore of the saved copy is said under the offer, which stays")
    func fails() async throws {
        let fixture = try await offered()
        fixture.harness.worker.update { $0.offlineBackups = true }

        await fixture.model.restoreSavedCopy()

        #expect(fixture.model.restoreOfferFailure == L10n.Backup.Reasons.offline)
        #expect(fixture.haptics.played == [.error])
        #expect(fixture.model.showsRestoreOffer(localInventoryHasRows: false))
        #expect(fixture.toasts.messages.isEmpty)
    }
}

/// A confirmation that waits until the test answers it.
@MainActor
final class AccountHeldConfirm: ConfirmPresenting {
    private var pending: CheckedContinuation<Bool, Never>?
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private(set) var count = 0

    func confirm(_ options: ConfirmOptions) async -> Bool {
        count += 1
        let waiting = arrivals
        arrivals = []
        for waiter in waiting { waiter.resume() }
        return await withCheckedContinuation { pending = $0 }
    }

    /// Returns once a question is up.
    func asked() async {
        if pending != nil { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func answer(_ value: Bool) {
        pending?.resume(returning: value)
        pending = nil
    }
}
