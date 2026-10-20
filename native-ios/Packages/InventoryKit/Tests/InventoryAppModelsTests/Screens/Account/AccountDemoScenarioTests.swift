import Foundation
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage
import InventoryStrings
import Testing
@testable import InventoryAppModels

// The account demo states (`-demoArea account -demoState …`) start where they say, and the
// screens' models work end to end against AccountDemoServer: the household screen's join, phone
// list, removal and copy-in (04 §12), and the backup states including B8 and B12 (03 §9).

@MainActor
private func accountDemoApp(_ scenario: AccountDemoScenario, confirm: SharedSeamsConfirmScript = SharedSeamsConfirmScript()) async -> AppContainer {
    let app = AppContainer.accountDemo(scenario, platform: .silent(confirm: confirm))
    await app.boot.run()
    await app.boot.syncAccountTask?.value
    return app
}

@MainActor
@Suite("Account demo: the household (app/household.tsx against the demo server)", .serialized, .timeLimit(.minutes(1)))
struct AccountDemoHouseholdTests {
    @Test("a joined phone lists the household's phones, this one first, with when each was last used")
    func phoneList() async throws {
        let app = await accountDemoApp(.paired)
        let session = try #require(app.household.session)
        let model = app.makeHouseholdPairedModel(session: session)
        #expect(model.heading == L10n.Household.thisPhoneIs(name: "Kitchen iPhone"))
        #expect(model.devicesQueryKey == "devices:\(AccountDemoServer.thisPhoneId)")

        let devices = try await model.listDevices()
        let now = app.now()
        guard case .rows(let rows, let refreshFailed) = HouseholdPairedModel.phoneList(
            devices: devices, loading: false, cause: nil, refreshFailed: false,
            connection: app.connection.state, thisDeviceId: session.deviceId, now: now
        ) else {
            Issue.record("expected rows")
            return
        }
        #expect(!refreshFailed)
        #expect(rows.map(\.device.name) == ["Kitchen iPhone", "Anna’s iPhone", "Hall iPad"])
        #expect(rows.map(\.meta) == [
            L10n.Household.thisPhone,
            L10n.Household.lastUsed(ago: Format.ago(now - 3 * 86_400_000, now: now)),
            L10n.Household.lastUsed(ago: Format.ago(now - 2 * 3_600_000, now: now)),
        ])
        #expect(rows.map(\.removeAccessibilityLabel) == [nil, L10n.Household.removeA11y(name: "Anna’s iPhone"), L10n.Household.removeA11y(name: "Hall iPad")])
        #expect(app.connection.state == .online)
        #expect(HouseholdPairedModel.connectionSummary(app.connection.state).value == L10n.Connection.connected)
    }

    @Test("removing another phone asks, removes it from the household and says so")
    func removesPhone() async throws {
        let confirm = SharedSeamsConfirmScript(answers: [true])
        let app = await accountDemoApp(.paired, confirm: confirm)
        let session = try #require(app.household.session)
        let model = app.makeHouseholdPairedModel(session: session)
        let anna = try #require(try await model.listDevices().first { $0.name == "Anna’s iPhone" })
        var reloads = 0

        await model.remove(anna) { reloads += 1 }

        #expect(confirm.asked.map(\.title) == [L10n.Household.removeTitle(name: "Anna’s iPhone")])
        #expect(reloads == 1)
        #expect(app.toasts.current?.options.message == L10n.Household.removed(name: "Anna’s iPhone"))
        #expect(try await model.listDevices().map(\.name) == ["Kitchen iPhone", "Hall iPad"])
    }

    @Test("a phone list that fails says so with Try again; one that never answers shows the skeleton")
    func phoneListFailures() async throws {
        let failed = await accountDemoApp(.devicesFailed)
        let session = try #require(failed.household.session)
        let model = failed.makeHouseholdPairedModel(session: session)
        var cause: (any Error)?
        do { _ = try await model.listDevices() } catch { cause = error }
        let list = HouseholdPairedModel.phoneList(
            devices: nil, loading: false, cause: cause, refreshFailed: false,
            connection: failed.connection.state, thisDeviceId: session.deviceId, now: 0)
        guard case .failure(let copy) = list else {
            Issue.record("expected the failure banner, got \(list)")
            return
        }
        #expect(copy.kind == .server)

        #expect(HouseholdPairedModel.phoneList(
            devices: nil, loading: true, cause: nil, refreshFailed: false,
            connection: .online, thisDeviceId: session.deviceId, now: 0) == .loading)
    }

    @Test("an unreachable home server leaves the phone list to the connection banner")
    func offline() async throws {
        let app = await accountDemoApp(.householdOffline)
        let session = try #require(app.household.session)
        let model = app.makeHouseholdPairedModel(session: session)
        var cause: (any Error)?
        do { _ = try await model.listDevices() } catch { cause = error }
        #expect(describeError(cause, context: .read).kind == .offline)
        #expect(HouseholdPairedModel.phoneList(
            devices: nil, loading: false, cause: cause, refreshFailed: false,
            connection: .offline, thisDeviceId: session.deviceId, now: 0) == .offlineNote)
    }

    @Test("joining with the demo code pairs, offers this phone's inventory, and copying it in clears the offer")
    func joinThenCopyIn() async throws {
        let confirm = SharedSeamsConfirmScript(answers: [true])
        let app = await accountDemoApp(.unpaired, confirm: confirm)
        #expect(app.household.session == nil)
        let form = app.makeJoinForm()
        #expect(form.serverCaption == L10n.Household.server(host: "home.demo.invalid"))
        form.updateCode(AccountDemoServer.householdCode.lowercased())
        form.updateName("  Anna’s iPhone ")

        let joined = try #require(await form.join())

        #expect(joined == HouseholdJoined(householdName: "Home", hasImportOffer: true))
        let session = try #require(app.household.session)
        #expect(session.deviceName == "Anna’s iPhone")
        let model = app.makeHouseholdPairedModel(session: session)
        model.readImportOffer()
        #expect(model.offer == ImportOffer(spaces: 3, items: 12))

        await model.copyIn()

        #expect(confirm.asked.map(\.title) == [L10n.Household.importConfirmTitle])
        #expect(model.importFailure == nil)
        #expect(model.offer == nil)
        #expect(app.joinPreferences.importOffer == nil)
        #expect(app.toasts.current?.options.message == L10n.Household.copied(items: 12, photos: 4))
    }

    @Test("a wrong code is refused under the code field and pairs nothing")
    func wrongCode() async throws {
        let app = await accountDemoApp(.unpaired)
        let form = app.makeJoinForm()
        form.updateCode("ZZZZZZZZZZZZZZZZZZZZZZZZZW")
        form.updateName("Anna’s iPhone")

        #expect(await form.join() == nil)
        #expect(form.errors.code == L10n.Join.refused)
        #expect(app.household.session == nil)
    }

    @Test("leaving forgets the session and tells the home server in passing")
    func leaves() async throws {
        let confirm = SharedSeamsConfirmScript(answers: [true])
        let app = await accountDemoApp(.paired, confirm: confirm)
        let session = try #require(app.household.session)
        let model = app.makeHouseholdPairedModel(session: session)
        var left = false

        await model.leave { left = true }

        #expect(left)
        #expect(app.household.session == nil)
        #expect(app.toasts.current?.options.message == L10n.Household.left)
    }
}

@MainActor
@Suite("Account demo: backup states (app/backup.tsx against the demo server)", .serialized, .timeLimit(.minutes(1)))
struct AccountDemoBackupTests {
    @Test("a build without a backup service is unavailable and offers no suggestions")
    func unavailable() async {
        let app = await accountDemoApp(.backupUnavailable)
        #expect(app.sync.status == .unavailable)
        #expect(app.config.recognitionEndpoint == nil)
        #expect(app.accountSettings.backupRow?.opensScreen == false)
    }

    @Test("off, on five minutes ago, and on with the first backup still uploading")
    func offAndOn() async throws {
        let off = await accountDemoApp(.backupOff)
        #expect(off.sync.status == .off)
        #expect(off.makeBackupScreenModel().body == .off)

        let on = await accountDemoApp(.backupOn)
        guard case .idle(let account, let lastBackupAt?) = on.sync.status else {
            Issue.record("expected idle with a backup, got \(on.sync.status)")
            return
        }
        #expect(account.recoveryCode == AccountDemoServer.recoveryCode)
        #expect(on.makeBackupScreenModel().lastLine(now: lastBackupAt + 5 * 60_000) == L10n.Backup.lastBackup(ago: Format.ago(lastBackupAt, now: lastBackupAt + 5 * 60_000)))

        let pending = await accountDemoApp(.backupNotYetRun)
        #expect(pending.sync.status.lastBackupLine(now: 0) == L10n.Backup.noBackupYet)
        #expect(pending.accountSettings.backupRow?.value == L10n.Settings.BackupSummary.notYetRun)
    }

    @Test("a failing service: Back up now shows the error and Settings says it needs attention")
    func failing() async {
        let app = await accountDemoApp(.backupFailing)
        await app.sync.backupNow()
        #expect(app.makeBackupScreenModel().errorReason == L10n.Backup.Reasons.offline)
        #expect(app.accountSettings.backupRow?.tone == .signal)
    }

    @Test("a keychain that will not read the code: the cannot-be-checked state, and Try again stays there (03 B8)")
    func unreadable() async {
        let app = await accountDemoApp(.backupUnreadable)
        #expect(app.sync.isAccountUnreadable)
        let model = app.makeBackupScreenModel()
        #expect(model.body == .unreadable)
        await model.retryAccountLoad()
        #expect(model.body == .unreadable)
    }

    @Test("an empty phone whose account has backups offers Restore, which brings the sample inventory back (03 B12)")
    func restoreOffer() async throws {
        let app = await accountDemoApp(.backupRestoreOffer, confirm: SharedSeamsConfirmScript(answers: [true]))
        await app.sync.waitForBackgroundWork()
        #expect(app.sync.suggestsRestore)
        #expect(try await app.localInventoryHasUserRows() == false)
        let model = app.makeBackupScreenModel()
        #expect(model.showsRestoreOffer(localInventoryHasRows: false))

        await model.restoreSavedCopy()

        #expect(model.restoreOfferFailure == nil)
        #expect(app.toasts.current?.options.message == L10n.Backup.restored)
        #expect(try await app.repositories.items.countAll() == 12)
        #expect(try await app.localInventoryHasUserRows())
        #expect(!app.sync.suggestsRestore)
    }

    @Test("Turn on with a code already stored, read late, carries on with it and says so (03 B8, B12)")
    func keptCode() async throws {
        let app = AppContainer.accountDemo(.backupKeptCode, platform: .silent())
        await app.boot.run()
        let model = app.makeBackupScreenModel()

        await model.turnOn()

        #expect(model.revealed == BackupRevealedCode(code: AccountDemoServer.recoveryCode, keptExistingCode: true))
        #expect(app.sync.suggestsRestore)
    }

    @Test("a joined phone with backup on lists the row and keeps its household session")
    func paired() async {
        let app = await accountDemoApp(.backupPaired)
        #expect(app.household.session != nil)
        #expect(app.sync.status.account != nil)
        #expect(app.accountSettings.backupRow?.value == L10n.Settings.BackupSummary.on)
    }
}
