import Foundation
import GRDB
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage
import InventoryStrings
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

// SyncModel (09 §4.4, §14.2 SyncModelLifecycleTests; 03 §8) over a real coordinator, a
// temporary database and a fake Worker, with the U6 rules: the automatic-pass status rule,
// exclusivity as the model sees it, 03 B8 and 03 B12. Suites that park requests in the fake
// Worker carry a time limit, so a regression that never lets one arrive fails instead of hanging.

private let otherCode = CrockfordBase32.encode([UInt8](repeating: 0x11, count: 16))

private func seededSnapshot() async throws -> Data {
    let source = try DatabaseStore.temporary()
    let repos = try await LocalRepositories.initialize(source)
    _ = try await repos.items.create(ItemDraft(containerId: DropZone.containerId, name: "Cordless Drill"))
    return try await source.snapshot()
}

@MainActor
@Suite("SyncModel lifecycle", .timeLimit(.minutes(1)))
struct SyncModelLifecycleTests {
    @Test("initial status from config")
    func initialStatus() async throws {
        #expect(try await SyncModelHarness(endpoint: nil).model.status == .unavailable)
        #expect(try await SyncModelHarness().model.status == .off)
    }

    @Test("no keychain read when syncEndpoint == nil")
    func noKeychainReadWithoutEndpoint() async throws {
        let harness = try await SyncModelHarness(endpoint: nil, keychain: [KeychainKey.recoveryCode: SyncModelHarness.code])
        await harness.startReady()
        harness.model.activityChanged(.active)
        await harness.model.waitForBackgroundWork()

        #expect(harness.keychain.reads == 0)
        #expect(harness.gate.waits == 0)
        #expect(harness.model.status == .unavailable)
        #expect(await harness.model.enable() == .notStarted(.notConfigured))
        #expect(await harness.model.restoreFromCode(SyncModelHarness.code) == .failed(.sync(.notConfigured)))
        #expect(harness.keychain.values == [KeychainKey.recoveryCode: SyncModelHarness.code])
        #expect(harness.worker.server.requests.isEmpty)
    }

    @Test("the account loads only once protected data is available")
    func waitsForProtectedData() async throws {
        let harness = try await SyncModelHarness(
            keychain: [KeychainKey.recoveryCode: SyncModelHarness.code], protectedDataAvailable: false)
        let starting = Task { await harness.model.start() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.keychain.reads == 0)
        #expect(harness.model.status == .off)

        harness.gate.open()
        await starting.value
        #expect(harness.model.status == .idle(account: SyncModelHarness.account, lastBackupAt: nil))
    }

    @Test("a stored account loads as idle with the stored marker")
    func loadsStoredAccount() async throws {
        let harness = try await SyncModelHarness(
            keychain: [KeychainKey.recoveryCode: SyncModelHarness.code],
            preferences: [PreferenceKey.lastBackupAt: "1760870400000"])
        await harness.model.start()
        #expect(harness.model.status == .idle(account: SyncModelHarness.account, lastBackupAt: 1_760_870_400_000))
        #expect(harness.model.account == SyncModelHarness.account)
    }

    @Test("a stored code that does not decode to 16 bytes means no account")
    func undecodableCodeIsNoAccount() async throws {
        let harness = try await SyncModelHarness(keychain: [KeychainKey.recoveryCode: "89144"])
        await harness.startReady()
        #expect(harness.model.status == .off)
        #expect(harness.model.account == nil)
        #expect(!harness.model.isAccountUnreadable)
        #expect(harness.worker.server.requests.isEmpty)
    }

    @Test("a pass needs the database and an account")
    func passNeedsDatabaseAndAccount() async throws {
        let harness = try await SyncModelHarness(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code])
        await harness.model.start()
        harness.model.activityChanged(.active)
        await harness.model.waitForBackgroundWork()
        #expect(harness.worker.server.requests.isEmpty)

        harness.model.databaseReady(harness.store)
        await harness.model.waitForBackgroundWork()
        #expect(harness.worker.requestLines == ["PUT /v1/backups"])
        #expect(harness.model.status == .idle(account: SyncModelHarness.account, lastBackupAt: 1000))
    }

    @Test("whichever of the database and the account comes last starts the first pass")
    func lastInputStartsPass() async throws {
        let harness = try await SyncModelHarness(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code])
        harness.model.databaseReady(harness.store)
        await harness.model.waitForBackgroundWork()
        #expect(harness.worker.server.requests.isEmpty)

        await harness.model.start()
        await harness.model.waitForBackgroundWork()
        #expect(harness.worker.requestLines == ["PUT /v1/backups"])
    }

    @Test("a pass runs on every return to active, not on inactive or background")
    func passOnActive() async throws {
        let harness = try await SyncModelHarness(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code])
        await harness.startReady()
        let photo = syncModelPhotoId(1)
        try await harness.addPendingPhoto(photo)

        harness.model.activityChanged(.inactive)
        harness.model.activityChanged(.background)
        await harness.model.waitForBackgroundWork()
        #expect(harness.worker.requestLines == ["PUT /v1/backups"])

        harness.model.activityChanged(.active)
        await harness.model.waitForBackgroundWork()
        // The backup is not due again (15-minute gate); the photo goes up.
        #expect(harness.worker.requestLines == ["PUT /v1/backups", "PUT /v1/photos/\(photo)"])
    }

    @Test("a pass started while one runs is skipped")
    func overlappingPassSkipped() async throws {
        let harness = try await SyncModelHarness(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code])
        await harness.startReady()
        try await harness.addPendingPhoto(syncModelPhotoId(1))
        let hold = harness.worker.hold("PUT", "/v1/photos/")

        harness.model.activityChanged(.active)
        await hold.arrived()
        harness.model.activityChanged(.active)
        // Lets the second pass reach the coordinator, which turns it away, before the first ends.
        try await Task.sleep(for: .milliseconds(150))
        hold.release()
        await harness.model.waitForBackgroundWork()

        #expect(harness.telemetry.events.filter { $0.name == "photo_sync_pass" }.count == 2)
    }

    @Test("an unreadable keychain is retried on the next return to active (03 B8)")
    func unreadableRetriedOnActive() async throws {
        let harness = try await SyncModelHarness(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code])
        harness.keychain.inner.failNextRead()
        await harness.startReady()
        #expect(harness.model.isAccountUnreadable)
        #expect(harness.model.status == .off)

        harness.model.activityChanged(.active)
        await harness.model.waitForBackgroundWork()
        #expect(!harness.model.isAccountUnreadable)
        #expect(harness.model.status == .idle(account: SyncModelHarness.account, lastBackupAt: 1000))
    }

    @Test("while the database is unavailable nothing runs; ready again, passes resume")
    func databaseUnavailableStopsWork() async throws {
        let harness = try await SyncModelHarness(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code])
        await harness.startReady()
        let passes = { harness.telemetry.events.filter { $0.name == "photo_sync_pass" }.count }
        #expect(passes() == 1)

        harness.model.databaseUnavailable()
        harness.model.activityChanged(.active)
        await harness.model.waitForBackgroundWork()
        #expect(passes() == 1)
        #expect(await harness.model.backupNow() == .notStarted)
        #expect(await harness.model.restoreFromCode(otherCode) == .failed(.sync(.notConfigured)))

        // A retry hands the database back (RN: `repos` changing identity re-ran the pass).
        harness.model.databaseReady(harness.store)
        await harness.model.waitForBackgroundWork()
        #expect(passes() == 2)
        #expect(harness.worker.requestLines == ["PUT /v1/backups"])
    }

    @Test("retryAccountLoad reads the keychain again")
    func retryAccountLoad() async throws {
        let harness = try await SyncModelHarness(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code])
        harness.keychain.inner.failNextRead()
        await harness.model.start()
        #expect(harness.model.isAccountUnreadable)

        await harness.model.retryAccountLoad()
        #expect(harness.model.account == SyncModelHarness.account)
    }
}

@MainActor
@Suite("SyncModel automatic passes and a failed backup's error (DECISIONS U6)", .timeLimit(.minutes(1)))
struct SyncModelErrorRuleTests {
    @Test("a completed automatic pass shows idle with the stored marker")
    func passShowsIdle() async throws {
        let harness = try await SyncModelHarness(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code])
        await harness.startReady()
        #expect(harness.model.status == .idle(account: SyncModelHarness.account, lastBackupAt: 1000))
    }

    @Test("a pass that skips its backup leaves a failed backup's error in place")
    func gatedPassKeepsError() async throws {
        let harness = try await SyncModelHarness(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code])
        await harness.startReady()
        harness.worker.update { $0.offlineBackups = true }
        #expect(await harness.model.backupNow() == .failed(.offline))
        harness.worker.update { $0.offlineBackups = false }

        harness.model.activityChanged(.active)
        await harness.model.waitForBackgroundWork()

        // RN set idle here, so the banner vanished on the next foreground.
        #expect(harness.model.status == .error(account: SyncModelHarness.account, reason: .offline))
    }

    @Test("a pass whose own backup fails leaves the error in place")
    func failingPassKeepsError() async throws {
        let harness = try await SyncModelHarness(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code], now: 10_000_000)
        await harness.startReady()
        harness.worker.update { $0.offlineBackups = true }
        _ = await harness.model.backupNow()

        harness.model.activityChanged(.active)
        await harness.model.waitForBackgroundWork()

        #expect(harness.model.status == .error(account: SyncModelHarness.account, reason: .offline))
        #expect(harness.worker.state.backups.count == 1)
    }

    @Test("a pass whose own backup is stored clears the error")
    func succeedingPassClearsError() async throws {
        let harness = try await SyncModelHarness(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code], now: 10_000_000)
        await harness.startReady()
        harness.worker.update { $0.offlineBackups = true }
        _ = await harness.model.backupNow()
        harness.worker.update { $0.offlineBackups = false }

        harness.model.activityChanged(.active)
        await harness.model.waitForBackgroundWork()

        #expect(harness.model.status == .idle(account: SyncModelHarness.account, lastBackupAt: 2000))
    }

    @Test("a pass finishing while Back up now waits leaves the status to Back up now")
    func passDuringBackupNow() async throws {
        let harness = try await SyncModelHarness(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code])
        await harness.startReady()
        try await harness.addPendingPhoto(syncModelPhotoId(1))
        let photoHold = harness.worker.hold("PUT", "/v1/photos/")
        harness.model.activityChanged(.active)
        await photoHold.arrived()
        let backupHold = harness.worker.hold("PUT", "/v1/backups")

        let manual = Task { await harness.model.backupNow() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.model.status == .working(account: SyncModelHarness.account))
        photoHold.release()
        await backupHold.arrived()
        // The pass has finished; RN would have set idle under the running backup.
        await harness.model.waitForBackgroundWork()
        #expect(harness.model.status == .working(account: SyncModelHarness.account))
        backupHold.release()

        #expect(await manual.value == .backedUp(lastBackupAt: 2000))
        #expect(harness.model.status == .idle(account: SyncModelHarness.account, lastBackupAt: 2000))
    }

    @Test("refresh is explicit and does clear an error")
    func refreshClearsError() async throws {
        let harness = try await SyncModelHarness(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code])
        await harness.startReady()
        harness.worker.update { $0.offlineBackups = true }
        _ = await harness.model.backupNow()

        harness.model.refresh()
        #expect(harness.model.status == .idle(account: SyncModelHarness.account, lastBackupAt: 1000))
    }
}

@MainActor
@Suite("SyncModel Turn on and Back up now", .timeLimit(.minutes(1)))
struct SyncModelEnableTests {
    @Test("Turn on shows the new account working, then idle, then syncs the photos")
    func enableSucceeds() async throws {
        let harness = try await SyncModelHarness()
        await harness.startReady()
        let photo = syncModelPhotoId(1)
        try await harness.addPendingPhoto(photo)
        let hold = harness.worker.hold("PUT", "/v1/backups")

        let enabling = Task { await harness.model.enable() }
        await hold.arrived()
        let stored = try #require(harness.keychain.values[KeychainKey.recoveryCode])
        let created = try #require(SyncAccount(storedCode: stored))
        #expect(harness.model.status == .working(account: created))
        hold.release()

        #expect(await enabling.value == .enabled(created))
        #expect(harness.model.status == .idle(account: created, lastBackupAt: 1000))
        await harness.model.waitForBackgroundWork()
        // The follow-up pass uploaded the photo and, the marker being fresh, no second snapshot (03 B6).
        #expect(harness.worker.state.photos[photo] != nil)
        #expect(harness.worker.state.backups.count == 1)
    }

    @Test("a failed first backup keeps the account, shows the error, and the photos still go up")
    func enableBackupFails() async throws {
        let harness = try await SyncModelHarness()
        await harness.startReady()
        let photo = syncModelPhotoId(1)
        try await harness.addPendingPhoto(photo)
        harness.worker.update { $0.offlineBackups = true }

        let outcome = await harness.model.enable()

        let created = try #require(outcome.account)
        #expect(outcome == .backupFailed(created, .offline))
        #expect(harness.model.status == .error(account: created, reason: .offline))
        #expect(harness.keychain.values[KeychainKey.recoveryCode] == created.recoveryCode)
        // RN's pass on publishing the account ran whatever the first backup came to (03 B6).
        await harness.model.waitForBackgroundWork()
        #expect(harness.worker.state.photos[photo] != nil)
        // Its own backup failed too, so the error and its copy stay.
        #expect(harness.model.status == .error(account: created, reason: .offline))
        #expect(harness.worker.state.backups.isEmpty)
    }

    @Test("the pass after a failed Turn on retries the backup, and clears the error once it is stored")
    func enableRetriedByFollowUpPass() async throws {
        let harness = try await SyncModelHarness()
        await harness.startReady()
        let first = harness.worker.hold("PUT", "/v1/backups")

        let enabling = Task { await harness.model.enable() }
        await first.arrived()
        harness.worker.update { $0.offlineBackups = true }
        let second = harness.worker.hold("PUT", "/v1/backups")
        first.release()
        let outcome = await enabling.value
        let created = try #require(outcome.account)
        #expect(outcome == .backupFailed(created, .offline))

        await second.arrived()
        #expect(harness.model.status == .error(account: created, reason: .offline))
        harness.worker.update { $0.offlineBackups = false }
        second.release()
        await harness.model.waitForBackgroundWork()

        #expect(harness.model.status == .idle(account: created, lastBackupAt: 1000))
        #expect(harness.worker.state.backups.count == 1)
    }

    @Test("Turn on finding a stored account on an empty phone holds the backup back and offers Restore (03 B8, B12)")
    func enableHeldBack() async throws {
        let harness = try await SyncModelHarness(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code], empty: true)
        let snapshot = try await seededSnapshot()
        harness.worker.update { $0.backups = [.init(bytes: snapshot, schemaVersion: "7", capturedAt: 1000)] }
        harness.keychain.inner.failNextRead()
        await harness.startReady()
        #expect(harness.model.isAccountUnreadable)

        let outcome = await harness.model.enable()

        #expect(outcome == .backupHeldBack(SyncModelHarness.account))
        #expect(harness.model.suggestsRestore)
        #expect(harness.model.status == .idle(account: SyncModelHarness.account, lastBackupAt: nil))
        await harness.model.waitForBackgroundWork()
        // The follow-up pass held its backup back too: the real one is still the newest.
        #expect(harness.worker.state.backups.count == 1)
        #expect(harness.keychain.values == [KeychainKey.recoveryCode: SyncModelHarness.code])
    }

    @Test("Turn on before the database is open creates nothing")
    func enableWithoutDatabase() async throws {
        let harness = try await SyncModelHarness()
        await harness.model.start()

        #expect(await harness.model.enable() == .notStarted(.notConfigured))
        #expect(harness.keychain.values.isEmpty)
        #expect(harness.model.status == .off)
    }

    @Test("Turn on with a keychain that still cannot be read creates nothing (03 B8)")
    func enableWithUnreadableKeychain() async throws {
        let harness = try await SyncModelHarness(keychain: [KeychainKey.recoveryCode: otherCode])
        harness.keychain.inner.failNextRead()
        await harness.startReady()
        harness.keychain.inner.failNextRead()

        #expect(await harness.model.enable() == .notStarted(.serverError))
        #expect(harness.keychain.values == [KeychainKey.recoveryCode: otherCode])
        #expect(harness.model.status == .off)
        #expect(harness.model.isAccountUnreadable)
        #expect(harness.telemetry.errors.map(\.name) == ["backup_enable_failed"])
        #expect(harness.worker.server.requests.isEmpty)
    }

    @Test("Turn on after an unreadable read uses the stored code instead of replacing it (03 B8)")
    func enableAdoptsStoredCode() async throws {
        let harness = try await SyncModelHarness(keychain: [KeychainKey.recoveryCode: otherCode])
        harness.keychain.inner.failNextRead()
        await harness.startReady()

        let outcome = await harness.model.enable()

        let existing = try #require(SyncAccount(storedCode: otherCode))
        #expect(outcome == .enabled(existing))
        #expect(harness.keychain.values == [KeychainKey.recoveryCode: otherCode])
        #expect(!harness.model.isAccountUnreadable)
    }

    @Test("Back up now shows working, then idle with the server's time")
    func backupNowSucceeds() async throws {
        let harness = try await SyncModelHarness(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code])
        await harness.startReady()

        #expect(await harness.model.backupNow() == .backedUp(lastBackupAt: 2000))
        #expect(harness.model.status == .idle(account: SyncModelHarness.account, lastBackupAt: 2000))
    }

    @Test("Back up now shows a failure as an error")
    func backupNowFails() async throws {
        let harness = try await SyncModelHarness(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code])
        await harness.startReady()
        harness.worker.update { $0.offlineBackups = true }

        #expect(await harness.model.backupNow() == .failed(.offline))
        #expect(harness.model.status == .error(account: SyncModelHarness.account, reason: .offline))
    }

    @Test("Back up now without an account does nothing")
    func backupNowWithoutAccount() async throws {
        let harness = try await SyncModelHarness()
        await harness.startReady()
        #expect(await harness.model.backupNow() == .notStarted)
        #expect(harness.model.status == .off)
    }
}

@MainActor
@Suite("SyncModel restore", .timeLimit(.minutes(1)))
struct SyncModelRestoreTests {
    @Test("a restore re-reads every screen twice, adopts the account and starts no pass")
    func restoreSucceeds() async throws {
        let harness = try await SyncModelHarness()
        await harness.startReady()
        let snapshot = try await seededSnapshot()
        harness.worker.update { $0.backups = [.init(bytes: snapshot, schemaVersion: "7", capturedAt: 1000)] }
        try await harness.store.queue.write { db in try db.execute(sql: "DELETE FROM items") }

        let typed = RecoveryCode.format(SyncModelHarness.code).lowercased()
        #expect(await harness.model.restoreFromCode(typed) == .restored)

        #expect(try await harness.itemCount() == 1)
        #expect(harness.invalidations.count == 2)
        #expect(harness.model.account == SyncModelHarness.account)
        // A restore records no marker, so a fresh phone shows "No backup has finished yet."
        #expect(harness.model.status == .idle(account: SyncModelHarness.account, lastBackupAt: nil))
        #expect(harness.keychain.values == [KeychainKey.recoveryCode: SyncModelHarness.code])
        await harness.model.waitForBackgroundWork()
        #expect(harness.worker.requestLines == ["GET /v1/backups/latest"])
    }

    @Test("a keychain that refuses the code after the restore leaves the inventory back and backup off")
    func restoreCodeNotStored() async throws {
        let harness = try await SyncModelHarness()
        await harness.startReady()
        let snapshot = try await seededSnapshot()
        harness.worker.update { $0.backups = [.init(bytes: snapshot, schemaVersion: "7", capturedAt: 1000)] }
        try await harness.store.queue.write { db in try db.execute(sql: "DELETE FROM items") }
        harness.keychain.inner.failNextWrite()

        #expect(await harness.model.restoreFromCode(SyncModelHarness.code) == .restored)

        #expect(try await harness.itemCount() == 1)
        #expect(harness.invalidations.count == 2)
        #expect(harness.model.status == .off)
        #expect(harness.model.account == nil)
        #expect(harness.keychain.values.isEmpty)
    }

    @Test("a failed restore stores no code and leaves backup off")
    func restoreFails() async throws {
        let harness = try await SyncModelHarness()
        await harness.startReady()

        #expect(await harness.model.restoreFromCode(SyncModelHarness.code) == .failed(.sync(.notFound)))
        #expect(harness.model.status == .off)
        #expect(harness.model.account == nil)
        #expect(harness.keychain.values.isEmpty)
        #expect(harness.invalidations.count == 0)
    }

    @Test("the adopted account is not published while the restore runs, and no pass starts")
    func restoreBlocksPasses() async throws {
        let harness = try await SyncModelHarness()
        await harness.startReady()
        harness.worker.update { $0.backups = [.init(bytes: Data("x".utf8), schemaVersion: "7", capturedAt: 1000)] }
        let hold = harness.worker.hold("GET", "/v1/backups/latest")

        let restoring = Task { await harness.model.restoreFromCode(SyncModelHarness.code) }
        await hold.arrived()
        #expect(harness.model.status == .off)
        #expect(harness.model.account == nil)
        harness.model.activityChanged(.active)
        await harness.model.waitForBackgroundWork()
        hold.release()

        // Not an SQLite file: refused without touching anything.
        #expect(await restoring.value == .failed(.sync(.corrupted)))
        #expect(harness.worker.requestLines == ["GET /v1/backups/latest"])
        #expect(try await harness.itemCount() == 1)
    }

    @Test("a mistyped code never reaches the Worker")
    func restoreMalformed() async throws {
        let harness = try await SyncModelHarness()
        await harness.startReady()
        #expect(await harness.model.restoreFromCode("89144") == .failed(.malformed))
        #expect(harness.worker.server.requests.isEmpty)
    }

    @Test("an unreadable keychain: restore writes, deletes and downloads nothing (03 B8)")
    func restoreWithUnreadableKeychain() async throws {
        let harness = try await SyncModelHarness(keychain: [KeychainKey.recoveryCode: otherCode])
        harness.keychain.inner.failNextRead()
        await harness.startReady()
        harness.keychain.inner.failNextRead()

        #expect(await harness.model.restoreFromCode(SyncModelHarness.code) == .failed(.sync(.notConfigured)))
        #expect(harness.keychain.values == [KeychainKey.recoveryCode: otherCode])
        #expect(harness.model.isAccountUnreadable)
        #expect(harness.worker.server.requests.isEmpty)
    }

    @Test("an account found stored at restore time is shown instead of being replaced (03 B8)")
    func restoreFindsStoredAccount() async throws {
        let harness = try await SyncModelHarness(keychain: [KeychainKey.recoveryCode: otherCode])
        harness.keychain.inner.failNextRead()
        await harness.startReady()

        #expect(await harness.model.restoreFromCode(SyncModelHarness.code) == .accountAlreadyOnThisPhone)
        let existing = try #require(SyncAccount(storedCode: otherCode))
        #expect(harness.model.account == existing)
        #expect(harness.keychain.values == [KeychainKey.recoveryCode: otherCode])
        await harness.model.waitForBackgroundWork()
        #expect(!harness.worker.requestLines.contains("GET /v1/backups/latest"))
    }
}

@MainActor
@Suite("SyncModel: an empty inventory never replaces existing backups (03 B12)", .timeLimit(.minutes(1)))
struct SyncModelEmptyInventoryTests {
    @Test("a reinstall with a surviving code holds the backup back and offers Restore")
    func reinstallOffersRestore() async throws {
        let harness = try await SyncModelHarness(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code], empty: true)
        let snapshot = try await seededSnapshot()
        harness.worker.update { $0.backups = [.init(bytes: snapshot, schemaVersion: "7", capturedAt: 1000)] }

        await harness.startReady()

        #expect(harness.model.suggestsRestore)
        #expect(harness.model.status == .idle(account: SyncModelHarness.account, lastBackupAt: nil))
        #expect(harness.worker.state.backups.count == 1)
        #expect(await harness.model.backupNow() == .heldBack)
        #expect(harness.worker.state.backups.count == 1)

        #expect(await harness.model.restoreFromAccount() == .restored)
        #expect(try await harness.itemCount() == 1)
        #expect(harness.invalidations.count == 2)
        #expect(!harness.model.suggestsRestore)
        #expect(harness.keychain.values == [KeychainKey.recoveryCode: SyncModelHarness.code])
    }

    @Test("a failed restore of the stored account puts the previous status back")
    func restoreFromAccountFails() async throws {
        let harness = try await SyncModelHarness(keychain: [KeychainKey.recoveryCode: SyncModelHarness.code], empty: true)
        await harness.startReady()
        let before = harness.model.status
        harness.worker.update { $0.offlineBackups = true }

        #expect(await harness.model.restoreFromAccount() == .failed(.sync(.offline)))
        #expect(harness.model.status == before)
    }
}

// MARK: - status.ts (backup half)

private let statusAccount = SyncAccount(id: "acc", recoveryCode: "CODE")
private let now: Int64 = 1_790_942_400_000  // Date.UTC(2026, 9, 2, 12)
private let day: Int64 = 24 * 60 * 60 * 1000
private let offStatus = SyncStatus.off
private let unavailableStatus = SyncStatus.unavailable
private let idleStatus = SyncStatus.idle(account: statusAccount, lastBackupAt: now - day)
private let neverRunStatus = SyncStatus.idle(account: statusAccount, lastBackupAt: nil)
private let workingStatus = SyncStatus.working(account: statusAccount)
private let failedStatus = SyncStatus.error(account: statusAccount, reason: .offline)

@Suite("status backupSummary")
struct SyncStatusSummaryTests {
    @Test("always has a value, including Off")
    func alwaysHasValue() {
        typealias Copy = L10n.Settings.BackupSummary
        #expect(unavailableStatus.settingsSummary == BackupSettingsSummary(value: Copy.notConfigured, tone: .ink))
        #expect(offStatus.settingsSummary == BackupSettingsSummary(value: Copy.off, tone: .ink))
        #expect(workingStatus.settingsSummary == BackupSettingsSummary(value: Copy.working, tone: .ink))
        #expect(neverRunStatus.settingsSummary == BackupSettingsSummary(value: Copy.notYetRun, tone: .ink))
        #expect(idleStatus.settingsSummary == BackupSettingsSummary(value: Copy.on, tone: .ink))
    }

    @Test("marks a failed backup in signal")
    func failedInSignal() {
        #expect(failedStatus.settingsSummary == BackupSettingsSummary(value: L10n.Settings.BackupSummary.attention, tone: .signal))
    }
}

@Suite("status showBackupRow")
struct SyncStatusRowTests {
    @Test("always shows backup on a phone that keeps its own inventory")
    func unpairedAlwaysShows() {
        for status in [offStatus, unavailableStatus, idleStatus, failedStatus, workingStatus, neverRunStatus] {
            #expect(status.showsSettingsRow(paired: false))
        }
    }

    @Test("hides it on a joined phone that never set it up (#48)")
    func pairedHidesOff() {
        #expect(!offStatus.showsSettingsRow(paired: true))
        #expect(!unavailableStatus.showsSettingsRow(paired: true))
    }

    @Test("keeps it on a joined phone that has a backup account")
    func pairedKeepsAccount() {
        for status in [idleStatus, neverRunStatus, workingStatus, failedStatus] {
            #expect(status.showsSettingsRow(paired: true))
        }
    }

    @Test("the row opens the Backup screen except when backup is unavailable")
    func rowTappable() {
        #expect(!unavailableStatus.opensBackupScreen)
        for status in [offStatus, idleStatus, neverRunStatus, workingStatus, failedStatus] {
            #expect(status.opensBackupScreen)
        }
    }
}

@Suite("status backupReason")
struct SyncStatusReasonTests {
    @Test("has plain words for every failure")
    func plainWords() {
        typealias Copy = L10n.Backup.Reasons
        #expect(BackupFailureReason.malformed.message == Copy.malformed)
        #expect(BackupFailureReason.sync(.notFound).message == Copy.notFound)
        #expect(BackupFailureReason.sync(.quotaExceeded).message == Copy.quotaExceeded)
        #expect(BackupFailureReason.sync(.serverError).message == Copy.other)
        #expect(BackupFailureReason.sync(.malformedResponse).message == Copy.other)
        #expect(BackupFailureReason.sync(.noAccount).message == Copy.other)
        #expect(SyncFailureReason.offline.backupMessage == Copy.offline)
    }

    @Test("never shows a raw reason code")
    func neverRaw() {
        let reasons = [BackupFailureReason.malformed] + SyncFailureReason.allCases.map(BackupFailureReason.sync)
        for reason in reasons {
            #expect(!reason.message.contains("_"))
        }
    }
}

@Suite("Backup screen status line (03 §9.4)")
struct SyncStatusLineTests {
    @Test("working, never run, idle and error lines")
    func lines() {
        #expect(workingStatus.lastBackupLine(now: now) == L10n.Backup.working)
        #expect(neverRunStatus.lastBackupLine(now: now) == L10n.Backup.noBackupYet)
        #expect(idleStatus.lastBackupLine(now: now) == L10n.Backup.lastBackup(ago: "yesterday"))
        #expect(failedStatus.lastBackupLine(now: now) == nil)
        #expect(offStatus.lastBackupLine(now: now) == nil)
    }

    @Test("the account is the one idle, working and error carry")
    func accountOfStatus() {
        #expect(idleStatus.account == statusAccount)
        #expect(workingStatus.account == statusAccount)
        #expect(failedStatus.account == statusAccount)
        #expect(SyncStatus.error(account: nil, reason: .offline).account == nil)
        #expect(offStatus.account == nil)
    }
}
