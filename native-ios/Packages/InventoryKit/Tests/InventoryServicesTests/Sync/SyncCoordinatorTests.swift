import Foundation
import GRDB
import InventoryCore
import InventoryNetwork
import InventoryStorage
import InventoryTestSupport
import Synchronization
import Testing
@testable import InventoryServices

// SyncCoordinator: the exclusivity RN raced on (03 §8.7, 09 §13.4, DECISIONS U6), and the
// restore orchestration of SyncProvider.restoreFromCode with the 03 B8 fix. Races are staged by
// parking a request inside the fake Worker until the test releases it; the suites carry a time
// limit so a regression that never lets a parked request arrive fails instead of hanging.

private struct SyncCoordinatorHarness {
    let inventory: SyncTestInventory
    let worker = SyncFakeWorker()
    let keychain: InMemoryKeychain
    let preferences = InMemoryPreferences()
    let files = SyncFakePhotoStore()
    let telemetry = RecordingTelemetry()
    let coordinator: SyncCoordinator

    init(keychain: InMemoryKeychain = InMemoryKeychain()) async throws {
        inventory = try await SyncTestInventory.seeded()
        self.keychain = keychain
        coordinator = SyncCoordinator(
            accounts: SyncAccountStore(keychain: keychain),
            lastBackup: LastBackupPreference(preferences: preferences),
            photos: files,
            resolver: nil,
            makeClient: worker.clientFactory,
            telemetry: telemetry.syncReporter,
            now: { 5_000_000 }
        )
    }

    var store: DatabaseStore { inventory.store }

    /// The account behind ``SyncFakeWorker/defaultCode``.
    var account: SyncAccount {
        get throws { try #require(SyncAccount(storedCode: SyncFakeWorker.defaultCode)) }
    }
}

/// Counts calls from a `@Sendable` callback.
private final class SyncCallCounter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func increment() { value.withLock { $0 += 1 } }
}

/// Collects lines from a `@Sendable` callback.
private final class SyncLineLog: Sendable {
    private let value = Mutex<[String]>([])
    var lines: [String] { value.withLock { $0 } }
    func append(_ line: String) { value.withLock { $0.append(line) } }
}

private func pause() async throws {
    // Long enough for a queued operation to have started had it not been waiting.
    try await Task.sleep(for: .milliseconds(150))
}

@Suite("SyncCoordinator exclusivity", .timeLimit(.minutes(1)))
struct SyncCoordinatorExclusivityTests {
    @Test("an automatic pass is skipped while another pass runs")
    func passSkipsWhilePassRuns() async throws {
        let harness = try await SyncCoordinatorHarness()
        let account = try harness.account
        try await harness.inventory.addPhoto(syncPhotoId(1), files: harness.files)
        let hold = harness.worker.hold("PUT", "/v1/photos/")

        let first = Task { await harness.coordinator.automaticPass(store: harness.store, account: account) }
        await hold.arrived()
        #expect(await harness.coordinator.automaticPass(store: harness.store, account: account) == nil)
        hold.release()

        let result = try #require(await first.value)
        #expect(result.photos.uploaded == 1)
        guard case .uploaded? = result.backup else {
            Issue.record("expected the pass to back up, got \(String(describing: result.backup))")
            return
        }
        #expect(await harness.coordinator.isBusy == false)
    }

    @Test("Turn on holds the flag: a pass during the first backup is skipped, so one snapshot is uploaded (03 B6)")
    func enableHoldsTheFlag() async throws {
        let harness = try await SyncCoordinatorHarness()
        let hold = harness.worker.hold("PUT", "/v1/backups")

        let enabling = Task { await harness.coordinator.enable(store: harness.store) }
        await hold.arrived()
        let created = try #require(SyncAccountStore(keychain: harness.keychain).load())
        #expect(await harness.coordinator.automaticPass(store: harness.store, account: created) == nil)
        hold.release()

        guard case .account(let account, .uploaded) = await enabling.value else {
            Issue.record("expected an account with its first backup")
            return
        }
        #expect(account == created)
        #expect(harness.worker.state.backups.count == 1)
    }

    @Test("Back up now waits for a running pass instead of overlapping it")
    func backupNowWaitsForPass() async throws {
        let harness = try await SyncCoordinatorHarness()
        let account = try harness.account
        let photo = syncPhotoId(1)
        try await harness.inventory.addPhoto(photo, files: harness.files)
        let hold = harness.worker.hold("PUT", "/v1/photos/")

        let pass = Task { await harness.coordinator.automaticPass(store: harness.store, account: account) }
        await hold.arrived()
        let manual = Task { await harness.coordinator.backupNow(store: harness.store, account: account) }
        try await pause()
        #expect(harness.worker.requestLines == ["PUT /v1/photos/\(photo)"])
        hold.release()

        _ = await pass.value
        guard case .uploaded(let summary) = await manual.value else {
            Issue.record("expected Back up now to upload")
            return
        }
        // The pass's own backup first, then the forced one: never side by side.
        #expect(harness.worker.requestLines == ["PUT /v1/photos/\(photo)", "PUT /v1/backups", "PUT /v1/backups"])
        #expect(summary.capturedAt == 2000)
    }

    @Test("restore waits for an in-flight pass, then holds the flag until it is done")
    func restoreWaitsThenHolds() async throws {
        let harness = try await SyncCoordinatorHarness()
        let account = try harness.account
        try await harness.inventory.addPhoto(syncPhotoId(1), files: harness.files)
        let passHold = harness.worker.hold("PUT", "/v1/photos/")
        let downloadHold = harness.worker.hold("GET", "/v1/backups/latest")

        let pass = Task { await harness.coordinator.automaticPass(store: harness.store, account: account) }
        await passHold.arrived()
        let restoring = Task {
            await harness.coordinator.restore(code: SyncFakeWorker.defaultCode, store: harness.store, afterRestore: {})
        }
        try await pause()
        // Still waiting: RN started the download beside the pass.
        #expect(!harness.worker.requestLines.contains("GET /v1/backups/latest"))
        #expect(harness.keychain.values.isEmpty)

        passHold.release()
        #expect(await pass.value != nil)
        await downloadHold.arrived()
        // The pass's end handed the flag to the restore; a new pass cannot slip in.
        #expect(await harness.coordinator.automaticPass(store: harness.store, account: account) == nil)
        downloadHold.release()

        guard case .restored(let adopted, _) = await restoring.value else {
            Issue.record("expected the restore to succeed")
            return
        }
        #expect(adopted == account)
        #expect(await harness.coordinator.isBusy == false)
        #expect(await harness.coordinator.automaticPass(store: harness.store, account: account) != nil)
    }

    @Test("queued operations run one after another and leave the flag clear")
    func queuedOperationsDrain() async throws {
        let harness = try await SyncCoordinatorHarness()
        let account = try harness.account
        let hold = harness.worker.hold("PUT", "/v1/backups")

        let first = Task { await harness.coordinator.backupNow(store: harness.store, account: account) }
        await hold.arrived()
        let second = Task { await harness.coordinator.backupNow(store: harness.store, account: account) }
        try await pause()
        #expect(harness.worker.server.requests.count == 1)
        hold.release()

        guard case .uploaded(let earlier) = await first.value else {
            Issue.record("expected the first backup to upload")
            return
        }
        #expect(earlier.capturedAt == 1000)
        guard case .uploaded(let later) = await second.value else {
            Issue.record("expected the second backup to upload")
            return
        }
        #expect(later.capturedAt == 2000)
        #expect(await harness.coordinator.isBusy == false)
    }

    @Test("the backup runs even when the photo pass could not write a photo back (03 B3)")
    func backupRunsAfterPhotoFailure() async throws {
        let harness = try await SyncCoordinatorHarness()
        let account = try harness.account
        let photo = syncPhotoId(1)
        try await harness.inventory.addPhoto(photo, synced: true)
        harness.worker.update { $0.photos[photo] = Data([0xFF, 0xD8, 0xFF, 0x00]) }
        harness.files.failWrites(for: photo)

        let result = try #require(await harness.coordinator.automaticPass(store: harness.store, account: account))

        #expect(result.photos == PhotoSyncOutcome(uploaded: 0, deleted: 0, restored: 0, interrupted: false))
        guard case .uploaded? = result.backup else {
            Issue.record("expected the backup to run, got \(String(describing: result.backup))")
            return
        }
    }
}

@Suite("SyncCoordinator restore and Turn on", .timeLimit(.minutes(1)))
struct SyncCoordinatorRestoreTests {
    @Test("a malformed code is refused before anything else")
    func malformed() async throws {
        let harness = try await SyncCoordinatorHarness()
        #expect(await harness.coordinator.restore(code: "89144", store: harness.store, afterRestore: {}) == .malformed)
        #expect(harness.worker.server.requests.isEmpty)
        #expect(harness.keychain.values.isEmpty)
    }

    @Test("a restore re-reads every screen, rehydrates photos, and stores the canonical code")
    func restoreSucceeds() async throws {
        let harness = try await SyncCoordinatorHarness()
        let account = try harness.account
        let photo = syncPhotoId(1)
        try await harness.inventory.addPhoto(photo, synced: true, files: harness.files)
        harness.worker.update { $0.photos[photo] = Data([0xFF, 0xD8, 0xFF, 0x01]) }
        _ = await harness.coordinator.backupNow(store: harness.store, account: account)
        // A fresh install: the files are gone.
        harness.files.removeAll()
        let invalidations = SyncCallCounter()

        let typed = RecoveryCode.format(SyncFakeWorker.defaultCode).lowercased()
        let result = await harness.coordinator.restore(code: typed, store: harness.store) { invalidations.increment() }

        #expect(result == .restored(account, schemaVersion: 7))
        #expect(invalidations.count == 2)
        #expect(harness.keychain.values == [KeychainKey.recoveryCode: SyncFakeWorker.defaultCode])
        #expect(harness.files.files[SyncFakePhotoStore.uri(photo)] != nil)
    }

    @Test("a failed restore stores no code and changes nothing")
    func failedRestoreStoresNoCode() async throws {
        let harness = try await SyncCoordinatorHarness()

        let result = await harness.coordinator.restore(code: SyncFakeWorker.defaultCode, store: harness.store, afterRestore: {})

        #expect(result == .failed(.notFound, localDataReplaced: false))
        #expect(harness.keychain.values.isEmpty)
        #expect(try await harness.inventory.count("items") == 1)
    }

    @Test("a failed restore keeps the same account when it was already stored")
    func failedRestoreKeepsStoredAccount() async throws {
        let harness = try await SyncCoordinatorHarness(keychain: InMemoryKeychain([KeychainKey.recoveryCode: SyncFakeWorker.defaultCode]))

        let result = await harness.coordinator.restore(code: SyncFakeWorker.defaultCode, store: harness.store, afterRestore: {})

        #expect(result == .failed(.notFound, localDataReplaced: false))
        #expect(harness.keychain.values == [KeychainKey.recoveryCode: SyncFakeWorker.defaultCode])
    }

    @Test("an unreadable keychain: restore writes, deletes and downloads nothing (03 B8)")
    func restoreWithUnreadableKeychain() async throws {
        let real = CrockfordBase32.encode([UInt8](repeating: 0x11, count: 16))
        let keychain = InMemoryKeychain([KeychainKey.recoveryCode: real])
        let harness = try await SyncCoordinatorHarness(keychain: keychain)
        keychain.failNextRead()

        let result = await harness.coordinator.restore(code: SyncFakeWorker.defaultCode, store: harness.store, afterRestore: {})

        #expect(result == .keychainUnreadable)
        #expect(keychain.values == [KeychainKey.recoveryCode: real])
        #expect(harness.worker.server.requests.isEmpty)
    }

    @Test("a different account already stored is never overwritten by a restore (03 B8)")
    func restoreWithDifferentStoredAccount() async throws {
        let real = CrockfordBase32.encode([UInt8](repeating: 0x11, count: 16))
        let keychain = InMemoryKeychain([KeychainKey.recoveryCode: real])
        let harness = try await SyncCoordinatorHarness(keychain: keychain)

        let result = await harness.coordinator.restore(code: SyncFakeWorker.defaultCode, store: harness.store, afterRestore: {})

        #expect(result == .accountAlreadyStored(try #require(SyncAccount(storedCode: real))))
        #expect(keychain.values == [KeychainKey.recoveryCode: real])
        #expect(harness.worker.server.requests.isEmpty)
    }

    @Test("the code is stored only once the snapshot is in place, never during the download")
    func codeStoredAfterRestore() async throws {
        let harness = try await SyncCoordinatorHarness()
        let account = try harness.account
        _ = await harness.coordinator.backupNow(store: harness.store, account: account)
        let hold = harness.worker.hold("GET", "/v1/backups/latest")

        let restoring = Task {
            await harness.coordinator.restore(code: SyncFakeWorker.defaultCode, store: harness.store, afterRestore: {})
        }
        await hold.arrived()
        // RN had written it already: an app terminated here came back with this account adopted
        // over the old inventory, and its next pass backed that inventory up under the account.
        #expect(harness.keychain.values.isEmpty)
        hold.release()

        #expect(await restoring.value == .restored(account, schemaVersion: 7))
        #expect(harness.keychain.values == [KeychainKey.recoveryCode: SyncFakeWorker.defaultCode])
    }

    @Test("a code the keychain refuses to store after the restore leaves the inventory restored and no account")
    func restoreWithUnwritableKeychain() async throws {
        let keychain = InMemoryKeychain()
        let harness = try await SyncCoordinatorHarness(keychain: keychain)
        _ = await harness.coordinator.backupNow(store: harness.store, account: try harness.account)
        try await harness.store.queue.write { db in try db.execute(sql: "DELETE FROM items") }
        let invalidations = SyncCallCounter()
        keychain.failNextWrite()

        let result = await harness.coordinator.restore(code: SyncFakeWorker.defaultCode, store: harness.store) {
            invalidations.increment()
        }

        #expect(result == .restoredCodeNotStored(schemaVersion: 7))
        #expect(keychain.values.isEmpty)
        #expect(try await harness.inventory.count("items") == 1)
        #expect(invalidations.count == 2)
    }

    @Test("an unreadable keychain: Turn on creates and uploads nothing (03 B8)")
    func enableWithUnreadableKeychain() async throws {
        let real = CrockfordBase32.encode([UInt8](repeating: 0x11, count: 16))
        let keychain = InMemoryKeychain([KeychainKey.recoveryCode: real])
        let harness = try await SyncCoordinatorHarness(keychain: keychain)
        keychain.failNextRead()

        let result = await harness.coordinator.enable(store: harness.store)

        #expect(result == .keychainFailed(.keychainUnreadable(InMemoryKeychain.simulatedFailure)))
        #expect(keychain.values == [KeychainKey.recoveryCode: real])
        #expect(harness.worker.server.requests.isEmpty)
    }

    @Test("Turn on reports the account before its first backup starts")
    func enableReportsAccountFirst() async throws {
        let harness = try await SyncCoordinatorHarness()
        let seen = SyncLineLog()
        let worker = harness.worker

        let result = await harness.coordinator.enable(store: harness.store) { account in
            seen.append("\(account.id.count) \(worker.state.backups.count)")
        }

        #expect(seen.lines == ["32 0"])
        guard case .account(_, .uploaded) = result else {
            Issue.record("expected an uploaded first backup")
            return
        }
    }

    @Test("restoring the stored account's latest backup leaves the keychain alone (03 B12)")
    func restoreLatest() async throws {
        let harness = try await SyncCoordinatorHarness(keychain: InMemoryKeychain([KeychainKey.recoveryCode: SyncFakeWorker.defaultCode]))
        let account = try harness.account
        _ = await harness.coordinator.backupNow(store: harness.store, account: account)
        try await harness.store.queue.write { db in try db.execute(sql: "DELETE FROM items") }

        let result = await harness.coordinator.restoreLatest(account: account, store: harness.store, afterRestore: {})

        #expect(result == .restored(account, schemaVersion: 7))
        #expect(try await harness.inventory.count("items") == 1)
        #expect(harness.keychain.values == [KeychainKey.recoveryCode: SyncFakeWorker.defaultCode])
    }
}
