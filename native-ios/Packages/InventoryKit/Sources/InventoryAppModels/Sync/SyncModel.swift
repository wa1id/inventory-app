import Foundation
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage
import Observation

// RN: the lifecycle side of src/providers/SyncProvider.tsx (09 §4.4, 03 §8), with the U6 fixes.

/// Backup's state for the whole app, and the actions the Backup screen calls (RN `useSync()`).
///
/// Started at launch by the composition root, not by a screen: like RN's provider it sits above
/// the onboarding gate, so the account loads and passes run while onboarding is still showing.
///
/// **Inputs**
/// - ``start()`` once at launch: loads the account after protected data is available (with no
///   sync endpoint it does nothing, and the keychain is never read).
/// - ``databaseReady(_:)`` when the database opens (or reopens after a retry), and
///   ``databaseUnavailable()`` when it goes away.
/// - ``activityChanged(_:)`` with every scene-phase change.
///
/// **Automatic passes** (photos, then a backup if 15 minutes have passed) start when the
/// database is ready and an account is loaded, whichever comes last, after a successful Turn on,
/// and on every return to `.active`. A pass that finds anything else running is skipped.
///
/// **What a finished automatic pass does to the status** (RN always set `idle`, which cleared a
/// failed manual backup's banner on the next foreground; DECISIONS U6, 09 Q23):
/// - while Turn on, Back up now or a restore is in flight, nothing (that action owns the status);
/// - over an `error`, only a pass whose own backup was stored clears it (to `idle`); a pass that
///   skipped its backup (15-minute gate) or failed it leaves the error and its copy in place;
/// - otherwise `idle` with the stored `lastBackupAt`. Automatic failures stay silent, as in RN.
@MainActor
@Observable
public final class SyncModel {
    /// Where backup stands. Starts at `off` with a sync endpoint, `unavailable` without; becomes
    /// `idle` once a stored account has loaded (until then a phone with an account reads `off`,
    /// as in RN).
    public private(set) var status: SyncStatus
    /// This device's account once loaded, created or restored.
    public private(set) var account: SyncAccount?
    /// The keychain refused the account read, so a recovery code may exist that this model cannot
    /// see (03 B8). The status stays `off`; the Backup screen should not offer Turn on or Restore
    /// (both would refuse anyway) but a retry (``retryAccountLoad()``). Returning to `.active`
    /// retries too.
    public private(set) var isAccountUnreadable = false
    /// A backup was held back because this phone's inventory is empty while the account already
    /// has backups (03 B12): the Backup screen offers ``restoreFromAccount()``. Cleared by a stored
    /// backup or a restore.
    public private(set) var suggestsRestore = false
    /// Whether this build has a sync endpoint.
    public let isConfigured: Bool

    private enum LoadState { case notStarted, loading, loaded }

    @ObservationIgnored private let coordinator: SyncCoordinator
    @ObservationIgnored private let invalidator: any InventoryInvalidating
    @ObservationIgnored private let waitForProtectedData: @MainActor @Sendable () async -> Void
    @ObservationIgnored private let telemetry: TelemetryReporter
    @ObservationIgnored private var store: DatabaseStore?
    @ObservationIgnored private var loadState = LoadState.notStarted
    /// Turn on, Back up now and restores in flight; while any runs, passes leave the status alone.
    @ObservationIgnored private var manualOperations = 0
    @ObservationIgnored private var backgroundWork: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextWorkID = 0

    /// - Parameters:
    ///   - config: decides `unavailable` (no `syncEndpoint`) versus `off`.
    ///   - coordinator: runs every pass, backup and restore.
    ///   - invalidator: re-reads every screen after a restore (the database model).
    ///   - waitForProtectedData: returns once `WhenUnlocked` keychain items can be read.
    ///   - telemetry: where `backup_enable_failed` goes.
    public init(
        config: AppConfig,
        coordinator: SyncCoordinator,
        invalidator: any InventoryInvalidating,
        waitForProtectedData: @escaping @MainActor @Sendable () async -> Void = { await ProtectedData.waitUntilAvailable() },
        telemetry: TelemetryReporter = .shared
    ) {
        isConfigured = config.syncEndpoint != nil
        status = isConfigured ? .off : .unavailable
        self.coordinator = coordinator
        self.invalidator = invalidator
        self.waitForProtectedData = waitForProtectedData
        self.telemetry = telemetry
    }

    /// The app's model: the Expo-compatible keychain, `UserDefaults` and the configured Worker.
    public convenience init(config: AppConfig, imageStore: ImageStore, invalidator: any InventoryInvalidating) {
        self.init(config: config, coordinator: .live(config: config, imageStore: imageStore), invalidator: invalidator)
    }

    // MARK: Inputs

    /// Loads the account once protected data is available (RN's mount effect). Only the first
    /// call does anything; with no sync endpoint, nothing happens.
    public func start() async {
        guard isConfigured, loadState == .notStarted else { return }
        loadState = .loading
        await waitForProtectedData()
        await loadAccount()
    }

    /// Reads the keychain again after it refused (03 B8).
    public func retryAccountLoad() async {
        guard isConfigured, loadState == .loaded, account == nil else { return }
        await loadAccount()
    }

    /// The database opened, or reopened after a retry. Starts a pass when an account is loaded
    /// (RN: `repos` changing re-ran the pass effect).
    public func databaseReady(_ store: DatabaseStore) {
        guard self.store !== store else { return }
        self.store = store
        startAutomaticPass()
    }

    /// ``databaseReady(_:)`` for the local repositories' store.
    public func databaseReady(_ repositories: LocalRepositories) {
        databaseReady(repositories.store)
    }

    /// The database is opening again or failed: no pass, backup or restore until it is ready.
    public func databaseUnavailable() {
        store = nil
    }

    /// The scene phase changed. Every transition to `.active` starts a pass, including the end
    /// of a plain `inactive` interruption, as in RN; it also retries an unreadable keychain.
    public func activityChanged(_ activity: AppActivity) {
        guard activity.isActive, isConfigured, loadState == .loaded else { return }
        if account == nil, isAccountUnreadable {
            spawn { await self.loadAccount() }
        } else {
            startAutomaticPass()
        }
    }

    // MARK: Commands

    /// RN `enable()`: creates the account and uploads its first backup, ignoring the 15-minute
    /// gate. The status shows the account as working while the backup runs, then `idle` or
    /// `error` (the account is kept either way, so backups keep retrying under it).
    ///
    /// The first backup holds the coordinator, so no automatic pass uploads a second snapshot
    /// beside it (03 B6); after it is stored, a normal pass follows (its own backup is skipped,
    /// the marker being fresh). After a failure, the next automatic pass retries. An account
    /// already stored is used, never replaced, and an unreadable keychain creates nothing (03 B8).
    public func enable() async -> EnableBackupOutcome {
        guard isConfigured, let store else { return .notStarted(.notConfigured) }
        manualOperations += 1
        defer { manualOperations -= 1 }

        let result = await coordinator.enable(store: store) { [weak self] created in
            await self?.publishWorking(created)
        }
        switch result {
        case .keychainFailed(let error):
            if case .keychainUnreadable = error { isAccountUnreadable = true }
            telemetry.error("backup_enable_failed", ["errorClass": .string(errorClass(of: error))])
            return .notStarted(.serverError)
        case .account(let created, let backup):
            account = created
            isAccountUnreadable = false
            switch backup {
            case .uploaded(let summary):
                status = .idle(account: created, lastBackupAt: summary.capturedAt)
                suggestsRestore = false
                startAutomaticPass()
                return .enabled(created)
            case .failed(let reason):
                status = .error(account: created, reason: reason)
                return .backupFailed(created, reason)
            case .heldBack:
                status = .idle(account: created, lastBackupAt: lastBackupAt)
                suggestsRestore = true
                return .backupHeldBack(created)
            }
        }
    }

    /// RN `backupNow()`: a forced backup without photo sync. Shows `working`, then `idle` or
    /// `error`. Waits for an automatic pass that is already running instead of overlapping it.
    @discardableResult
    public func backupNow() async -> BackupNowOutcome {
        guard isConfigured, let store, let account else { return .notStarted }
        manualOperations += 1
        defer { manualOperations -= 1 }

        status = .working(account: account)
        switch await coordinator.backupNow(store: store, account: account) {
        case .uploaded(let summary):
            status = .idle(account: account, lastBackupAt: summary.capturedAt)
            suggestsRestore = false
            return .backedUp(lastBackupAt: summary.capturedAt)
        case .failed(let reason):
            status = .error(account: account, reason: reason)
            return .failed(reason)
        case .heldBack:
            status = .idle(account: account, lastBackupAt: lastBackupAt)
            suggestsRestore = true
            return .heldBack
        }
    }

    /// RN `restoreFromCode(code)`: adopts the account a typed code stands for and replaces this
    /// phone's inventory with its newest backup.
    ///
    /// The adopted account is published only once the restore succeeded (03 §9.2), so the
    /// Backup screen keeps its form and the status stays `off` meanwhile. On success every screen
    /// re-reads, the photos the backup references start downloading, every screen re-reads
    /// again, and the status is `idle` with the stored marker. No pass is started; the next
    /// foreground runs one (its backup is due unless a marker is stored). On failure a code
    /// written for this restore is forgotten again and the status is `off`. An unreadable
    /// keychain or a different account already stored stops it before anything is written (03 B8).
    public func restoreFromCode(_ code: String) async -> RestoreOutcome {
        guard isConfigured, let store else { return .failed(.sync(.notConfigured)) }
        manualOperations += 1
        defer { manualOperations -= 1 }

        let result = await coordinator.restore(code: code, store: store) { [weak self] in
            await self?.invalidateInventory()
        }
        switch result {
        case .malformed:
            return .failed(.malformed)
        case .keychainUnreadable:
            isAccountUnreadable = true
            return .failed(.sync(.notConfigured))
        case .keychainWriteFailed:
            return .failed(.sync(.notConfigured))
        case .accountAlreadyStored(let existing):
            adoptLoadedAccount(existing)
            return .accountAlreadyOnThisPhone
        case .failed(let reason, let localDataReplaced):
            if localDataReplaced { invalidator.invalidate() }
            if account == nil { status = .off }
            return .failed(.sync(reason))
        case .restored(let adopted, _):
            account = adopted
            isAccountUnreadable = false
            suggestsRestore = false
            status = .idle(account: adopted, lastBackupAt: lastBackupAt)
            return .restored
        }
    }

    /// Restores the newest backup of the account already on this phone: what the Backup screen
    /// offers instead of backing up an empty inventory over it (03 B12). The keychain is not
    /// touched. Shows `working` meanwhile; a failure puts the previous status back.
    public func restoreFromAccount() async -> RestoreOutcome {
        guard isConfigured, let store, let account else { return .failed(.sync(.notConfigured)) }
        manualOperations += 1
        defer { manualOperations -= 1 }

        let previous = status
        status = .working(account: account)
        let result = await coordinator.restoreLatest(account: account, store: store) { [weak self] in
            await self?.invalidateInventory()
        }
        switch result {
        case .restored:
            suggestsRestore = false
            status = .idle(account: account, lastBackupAt: lastBackupAt)
            return .restored
        case .failed(let reason, let localDataReplaced):
            if localDataReplaced { invalidator.invalidate() }
            status = previous
            return .failed(.sync(reason))
        case .malformed, .keychainUnreadable, .keychainWriteFailed, .accountAlreadyStored:
            // restoreLatest never touches the keychain or parses a code.
            status = previous
            return .failed(.sync(.serverError))
        }
    }

    /// RN `refresh()`: re-reads the marker and shows `idle` for the loaded account. An explicit
    /// action, so it does clear an error. No RN screen calls it.
    public func refresh() {
        guard let account else { return }
        status = .idle(account: account, lastBackupAt: lastBackupAt)
    }

    // MARK: Internals

    /// The `sync.lastBackupAt.v1` marker in whole milliseconds.
    private var lastBackupAt: Int64? {
        coordinator.lastBackup.lastBackupAtMilliseconds
    }

    private func loadAccount() async {
        let lookup = await coordinator.lookupAccount()
        loadState = .loaded
        switch lookup {
        case .found(let found):
            isAccountUnreadable = false
            // A Turn on or restore that got there first publishes its own account.
            guard account == nil, manualOperations == 0 else { return }
            adoptLoadedAccount(found)
        case .absent:
            isAccountUnreadable = false
        case .unreadable:
            isAccountUnreadable = true
        }
    }

    /// Publishes an account found in the keychain and starts a pass (RN: `setAccount`, then the
    /// pass effect).
    private func adoptLoadedAccount(_ found: SyncAccount) {
        account = found
        isAccountUnreadable = false
        status = .idle(account: found, lastBackupAt: lastBackupAt)
        startAutomaticPass()
    }

    private func publishWorking(_ created: SyncAccount) {
        account = created
        status = .working(account: created)
    }

    private func invalidateInventory() {
        invalidator.invalidate()
    }

    private func startAutomaticPass() {
        guard isConfigured, let store, let account else { return }
        spawn { [coordinator] in
            guard let result = await coordinator.automaticPass(store: store, account: account) else { return }
            self.applyAutomaticPass(result, account: account)
        }
    }

    private func applyAutomaticPass(_ result: SyncPassResult, account passAccount: SyncAccount) {
        guard account == passAccount else { return }
        switch result.backup {
        case .heldBack?: suggestsRestore = true
        case .uploaded?: suggestsRestore = false
        case .failed?, nil: break
        }
        guard manualOperations == 0 else { return }
        if case .error = status {
            guard case .uploaded(let summary)? = result.backup else { return }
            status = .idle(account: passAccount, lastBackupAt: summary.capturedAt)
            return
        }
        status = .idle(account: passAccount, lastBackupAt: lastBackupAt)
    }

    private func spawn(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        let id = nextWorkID
        nextWorkID &+= 1
        backgroundWork[id] = Task {
            await operation()
            self.backgroundWork[id] = nil
        }
    }

    /// Waits for every account load and automatic pass this model started (tests, previews).
    func waitForBackgroundWork() async {
        while let task = backgroundWork.values.first {
            await task.value
        }
    }
}
