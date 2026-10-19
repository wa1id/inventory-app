import Foundation
import InventoryCore
import InventoryNetwork
import InventoryStorage

// RN: the orchestration half of src/providers/SyncProvider.tsx (runPass, enable, backupNow,
// restoreFromCode), 03 §6.3 and §8, with the exclusivity of 03 §8.7 / 09 §13.4 (DECISIONS U6).

/// One automatic pass (RN `runPass`): photos first, then the snapshot if one is due.
public struct SyncPassResult: Sendable, Equatable {
    public var photos: PhotoSyncOutcome
    /// The 15-minute gate's backup, or nil when none was due.
    public var backup: BackupRunOutcome?

    public init(photos: PhotoSyncOutcome, backup: BackupRunOutcome?) {
        self.photos = photos
        self.backup = backup
    }
}

/// What ``SyncCoordinator/enable(store:onAccount:)`` came to.
public enum SyncEnableResult: Sendable, Equatable {
    /// The account exists (created, or found already stored) and its first backup ran.
    case account(SyncAccount, backup: BackupRunOutcome)
    /// No account: the keychain could not be read or written, or the CSPRNG failed.
    case keychainFailed(SyncAccountError)
}

/// What a restore came to (RN `restoreFromCode` results, plus the native B8 states).
public enum SyncRestoreResult: Sendable, Equatable {
    /// The snapshot is in place and this account is stored as the device's account.
    case restored(SyncAccount, schemaVersion: Int)
    /// The code does not decode to 16 bytes. Nothing was written.
    case malformed
    /// The keychain could not be read, so a real code may be there; nothing was written or
    /// deleted and nothing was downloaded (03 B8; RN overwrote it).
    case keychainUnreadable
    /// The code could not be stored, so nothing was downloaded (RN `importAccount` →
    /// `unavailable`, reported as `not_configured`).
    case keychainWriteFailed
    /// A different account is already stored on this device: the device's state was stale
    /// (the read had failed or not finished). Nothing was overwritten or restored (03 B8).
    case accountAlreadyStored(SyncAccount)
    /// The download or the restore failed. A code written for it was forgotten again.
    case failed(SyncFailureReason, localDataReplaced: Bool)
}

/// The one place sync work runs, one operation at a time (03 §8.7, 09 §13.4).
///
/// Exclusivity, fixed per DECISIONS U6 (RN raced on all of it):
/// - an **automatic pass** is skipped (returns nil) while anything runs;
/// - **enable**, **backup now** and **restore** wait for whatever runs, then hold the flag, so a
///   pass can neither start during them nor clear it early; waiters are served in order, and
///   the flag passes straight from one to the next so no pass slips in between.
///
/// The flag is checked and set synchronously before the first suspension, because actors are
/// reentrant. Each call takes the database store it works on, so a store reopened by the
/// database model's retry is picked up without a separate attach step.
public actor SyncCoordinator {
    /// Builds the Worker client for a recovery code.
    public typealias ClientFactory = @Sendable (_ recoveryCode: String) -> SyncClient

    private struct Services {
        let store: DatabaseStore
        let backup: BackupService
        let restore: RestoreService
        let photos: PhotoSyncService
    }

    /// The account in the keychain.
    public nonisolated let accounts: SyncAccountStore
    /// The `lastBackupAt` marker the backups write and the status reads.
    public nonisolated let lastBackup: LastBackupPreference
    private let photoStore: any PhotoStoring
    private let resolver: PhotoPathResolver?
    private nonisolated let makeClient: ClientFactory
    private let telemetry: TelemetryReporter
    private let now: @Sendable () -> Int64

    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var services: Services?

    /// - Parameters:
    ///   - accounts: the recovery-code account store.
    ///   - lastBackup: the `sync.lastBackupAt.v1` marker.
    ///   - photos: the photo files (the app's ``ImageStore``).
    ///   - resolver: the image store's resolver, for cheap presence checks (03 B1, B4).
    ///   - makeClient: a Worker client for a recovery code.
    ///   - telemetry: where the services report.
    ///   - now: the device clock in epoch milliseconds.
    public init(
        accounts: SyncAccountStore,
        lastBackup: LastBackupPreference,
        photos: any PhotoStoring,
        resolver: PhotoPathResolver?,
        makeClient: @escaping ClientFactory,
        telemetry: TelemetryReporter = .shared,
        now: @escaping @Sendable () -> Int64 = { epochMillis() }
    ) {
        self.accounts = accounts
        self.lastBackup = lastBackup
        self.photoStore = photos
        self.resolver = resolver
        self.makeClient = makeClient
        self.telemetry = telemetry
        self.now = now
    }

    /// The app's coordinator: the Expo-compatible keychain, `UserDefaults`, the image store and
    /// the configured Worker (endpoint, app key, 60 s total deadline).
    public static func live(
        config: AppConfig,
        imageStore: ImageStore,
        keychain: any KeychainStore = ExpoCompatibleKeychain(),
        preferences: any PreferenceStoring = UserDefaults.standard
    ) -> SyncCoordinator {
        SyncCoordinator(
            accounts: SyncAccountStore(keychain: keychain),
            lastBackup: LastBackupPreference(preferences: preferences),
            photos: imageStore,
            resolver: imageStore.resolver,
            makeClient: { code in
                SyncClient(recoveryCode: code, endpoint: config.syncEndpoint, key: config.syncKey, timeout: config.syncTimeout)
            }
        )
    }

    /// Whether an operation holds the flag now.
    public var isBusy: Bool { isRunning }

    /// A Worker client for `account`, for callers outside a pass: the household import falls
    /// back to the backup's copy of a photo whose file is missing (03 §16, RN importHousehold.ts:41-51).
    public nonisolated func client(for account: SyncAccount) -> SyncClient {
        makeClient(account.recoveryCode)
    }

    /// The account in the keychain, its absence, or an unreadable keychain (03 B8).
    /// Never writes. Call it once protected data is available.
    public func lookupAccount() -> SyncAccountLookup {
        accounts.lookup()
    }

    // MARK: Automatic pass

    /// RN `runPass`: ``PhotoSyncService/syncPhotos(client:)``, then
    /// ``BackupService/maybeBackup(client:now:)``. Nil when skipped because something else runs.
    ///
    /// The backup runs whatever happened to the photos (03 B3): nothing in the photo pass throws.
    public func automaticPass(store: DatabaseStore, account: SyncAccount) async -> SyncPassResult? {
        guard !isRunning else { return nil }
        isRunning = true
        defer { release() }

        let services = services(for: store)
        let client = makeClient(account.recoveryCode)
        await services.photos.prepare(forAccount: account.id)
        let photos = await services.photos.syncPhotos(client: client)
        let backup = await services.backup.maybeBackup(client: client)
        return SyncPassResult(photos: photos, backup: backup)
    }

    // MARK: Enable

    /// RN `enable()` without its race (03 B6): creates the account and runs the first, forced
    /// backup while holding the flag, so no automatic pass can upload a second snapshot beside it.
    ///
    /// `onAccount` runs once the account exists and before the backup starts, so the status can
    /// show it as working (RN published the account at that point). An account already stored
    /// is used rather than replaced, and an unreadable keychain creates nothing (03 B8).
    public func enable(
        store: DatabaseStore,
        onAccount: @Sendable (SyncAccount) async -> Void = { _ in }
    ) async -> SyncEnableResult {
        await acquire()
        defer { release() }

        let account: SyncAccount
        do {
            account = try accounts.create()
        } catch {
            return .keychainFailed(error)
        }
        await onAccount(account)
        let backup = await services(for: store).backup.runBackup(client: makeClient(account.recoveryCode))
        return .account(account, backup: backup)
    }

    // MARK: Backup now

    /// RN `backupNow()`: a forced backup, with no photo sync. Waits for whatever runs, then holds
    /// the flag (RN overlapped an automatic pass).
    public func backupNow(store: DatabaseStore, account: SyncAccount) async -> BackupRunOutcome {
        await acquire()
        defer { release() }
        return await services(for: store).backup.runBackup(client: makeClient(account.recoveryCode))
    }

    // MARK: Restore

    /// RN `restoreFromCode(code)`: adopts a typed code and restores its newest snapshot.
    ///
    /// Waits for an in-flight pass, then holds the flag for the whole restore (RN set it without
    /// waiting, and the pass's `finally` cleared it early). With no account stored, the canonical
    /// code is written before the download and forgotten again if the restore fails, as in RN.
    /// An unreadable keychain or a different stored account stops it before anything is written
    /// (03 B8); the same account already stored is kept whatever happens.
    ///
    /// On success, `afterRestore` runs (every screen re-reads), the photos are synced under the
    /// adopted account (rehydrating what the snapshot references), and `afterRestore` runs again.
    public func restore(
        code: String,
        store: DatabaseStore,
        afterRestore: @Sendable () async -> Void
    ) async -> SyncRestoreResult {
        guard let canonical = RecoveryCode.canonical(code), let adopted = SyncAccount(storedCode: canonical) else {
            return .malformed
        }
        await acquire()
        defer { release() }

        let wrote: Bool
        switch accounts.lookup() {
        case .unreadable:
            return .keychainUnreadable
        case .found(let existing) where existing.id != adopted.id:
            return .accountAlreadyStored(existing)
        case .found:
            wrote = false
        case .absent:
            do {
                try accounts.save(adopted)
            } catch {
                return .keychainWriteFailed
            }
            wrote = true
        }

        let result = await restoreLocked(account: adopted, store: store, afterRestore: afterRestore)
        if case .failed = result, wrote {
            // Restore is only offered while backup is off, so a code that did not restore must
            // not become this phone's account.
            accounts.forget()
        }
        return result
    }

    /// Restores the newest snapshot of the account already on this device: what the Backup
    /// screen offers when a backup was held back because the inventory is empty (03 B12).
    /// The keychain is not touched.
    public func restoreLatest(
        account: SyncAccount,
        store: DatabaseStore,
        afterRestore: @Sendable () async -> Void
    ) async -> SyncRestoreResult {
        await acquire()
        defer { release() }
        return await restoreLocked(account: account, store: store, afterRestore: afterRestore)
    }

    private func restoreLocked(
        account: SyncAccount,
        store: DatabaseStore,
        afterRestore: @Sendable () async -> Void
    ) async -> SyncRestoreResult {
        let services = services(for: store)
        let client = makeClient(account.recoveryCode)
        switch await services.restore.restore(using: client) {
        case .failed(let reason, let replaced):
            return .failed(reason, localDataReplaced: replaced)
        case .restored(let schemaVersion):
            // Every screen reads SQLite, so the restored rows are announced before the photos
            // start arriving behind them.
            await afterRestore()
            await services.photos.prepare(forAccount: account.id)
            await services.photos.forgetSkippedPhotos()
            _ = await services.photos.syncPhotos(client: client)
            await afterRestore()
            return .restored(account, schemaVersion: schemaVersion)
        }
    }

    // MARK: Exclusivity

    /// Waits until nothing runs, then holds the flag.
    private func acquire() async {
        if !isRunning {
            isRunning = true
            return
        }
        // Released straight to us: the flag stays set while it changes hands.
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the flag to the oldest waiter, or clears it.
    private func release() {
        if waiters.isEmpty {
            isRunning = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func services(for store: DatabaseStore) -> Services {
        if let services, services.store === store { return services }
        let made = Services(
            store: store,
            backup: BackupService(store: store, lastBackup: lastBackup, telemetry: telemetry, now: now),
            restore: RestoreService(store: store, telemetry: telemetry),
            photos: PhotoSyncService(store: store, photos: photoStore, resolver: resolver, telemetry: telemetry, now: now)
        )
        services = made
        return made
    }
}
