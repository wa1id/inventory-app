import Foundation
import InventoryCore
import InventoryStorage
import Observation

/// The boot sequence, once per process (09 §3.2, 02 §8), and the gate it feeds.
///
/// Creating it does nothing (no disk or keychain I/O at process start, 09 §3.2 step 0); the
/// root view's `.task` calls ``run()``:
/// 1. wait until protected data is readable (before the first unlock after a reboot the
///    database, the RN preference manifest and the `WhenUnlocked` keychain items all fail, and
///    a failed keychain read would make a paired phone look unpaired, 02 §8 step 0);
/// 2. import the RN AsyncStorage preferences (``Steps/importLegacyPreferences``), before
///    **any** `UserDefaults` read;
/// 3. read the onboarding flag, start the backup account load on the side (never gating; only
///    wired when sync is configured), and open the database and load the household session
///    together; the gate passes once all three gate inputs are known;
/// 4. purge the RN temporary caches once, in the background (DECISIONS U11).
///
/// The gate is ``phase``: the database error first, then any of database, onboarding or
/// session still loading, then onboarding or the main shell (``BootGate``). The connection
/// subscription, sync passes and app-activity routing do not wait for the gate (in RN they sat
/// above it, 09 §3.2 step 4); the composition root starts them.
@MainActor
@Observable
public final class AppBoot {
    /// The I/O steps, injected so tests can order and fake them.
    public struct Steps: Sendable {
        /// Returns once protected data is readable (`ProtectedData.waitUntilAvailable()`).
        public var waitForProtectedData: @MainActor @Sendable () async -> Void
        /// The one-time AsyncStorage → `UserDefaults` copy (`LegacyImport().runIfNeeded()`).
        public var importLegacyPreferences: @MainActor @Sendable () -> Void
        /// Reads the household session from the keychain (``HouseholdModel/load()``).
        /// The gate waits for it, paired or not.
        public var loadHouseholdSession: @MainActor @Sendable () async -> Void
        /// Reads the backup account (``SyncModel/start()``); nil when sync is not configured
        /// (`!SyncModel.isConfigured`), so the keychain is never read and the status stays
        /// unavailable. Never waited for. Set it with an `if`: a closure literal in a ternary is
        /// not typed from context, so `cond ? { await sync.start() } : nil` does not compile.
        public var loadSyncAccount: (@MainActor @Sendable () async -> Void)?
        /// Deletes the RN temporary caches once per install (`TemporaryCachePurge`). Runs in
        /// the background after the gate inputs are known.
        public var purgeTemporaryCaches: @Sendable () async -> Void

        public init(
            waitForProtectedData: @escaping @MainActor @Sendable () async -> Void,
            importLegacyPreferences: @escaping @MainActor @Sendable () -> Void,
            loadHouseholdSession: @escaping @MainActor @Sendable () async -> Void,
            loadSyncAccount: (@MainActor @Sendable () async -> Void)?,
            purgeTemporaryCaches: @escaping @Sendable () async -> Void
        ) {
            self.waitForProtectedData = waitForProtectedData
            self.importLegacyPreferences = importLegacyPreferences
            self.loadHouseholdSession = loadHouseholdSession
            self.loadSyncAccount = loadSyncAccount
            self.purgeTemporaryCaches = purgeTemporaryCaches
        }

        /// The app's steps over the standard `UserDefaults`, the real container and the real
        /// protected-data state, with the household and sync loads the composition root wires.
        public static func live(
            loadHouseholdSession: @escaping @MainActor @Sendable () async -> Void,
            loadSyncAccount: (@MainActor @Sendable () async -> Void)?
        ) -> Steps {
            Steps(
                waitForProtectedData: { await ProtectedData.waitUntilAvailable() },
                importLegacyPreferences: {
                    let summary = switch LegacyImport().runIfNeeded() {
                    case .alreadyImported: "already imported"
                    case .protectedDataUnavailable: "protected data unavailable"
                    case .failed: "failed; retried next launch"
                    case .imported(let keys): "imported \(keys.count) keys"
                    }
                    InventoryLog.boot.debug("legacy preference import: \(summary, privacy: .public)")
                },
                loadHouseholdSession: loadHouseholdSession,
                loadSyncAccount: loadSyncAccount,
                purgeTemporaryCaches: {
                    let removed = TemporaryCachePurge().runIfNeeded()
                    InventoryLog.boot.debug("temporary caches purged: \(removed.count, privacy: .public)")
                }
            )
        }
    }

    /// How far ``run()`` has got.
    public enum Progress: Sendable, Hashable {
        case notStarted
        /// Waiting for the first unlock.
        case waitingForProtectedData
        /// Preferences imported; database and session loading.
        case loading
        /// The database open and the session load have both returned (the database may have failed).
        case finished
    }

    public let database: DatabaseModel
    public let onboarding: OnboardingModel
    /// The household session has come back from the keychain, paired or not (RN `household.ready`).
    public private(set) var householdReady = false
    public private(set) var progress: Progress = .notStarted

    @ObservationIgnored private let steps: Steps
    /// The boot sequence, started by the first ``run()``.
    @ObservationIgnored private var bootTask: Task<Void, Never>?
    /// The backup account load, running beside the gate.
    @ObservationIgnored public private(set) var syncAccountTask: Task<Void, Never>?
    /// The background cache purge.
    @ObservationIgnored public private(set) var cachePurgeTask: Task<Void, Never>?

    public init(database: DatabaseModel, onboarding: OnboardingModel, steps: Steps) {
        self.database = database
        self.onboarding = onboarding
        self.steps = steps
    }

    /// What the root view shows now.
    public var phase: BootGate.Phase {
        BootGate.phase(database: database.status, onboarding: onboarding.status, householdReady: householdReady)
    }

    /// Runs the boot sequence. Only the first call starts it; every call returns once the
    /// database open and the household session load have returned. A failed database is retried
    /// from the failure screen with `DatabaseModel.retry()`, not by running boot again.
    ///
    /// The sequence runs in a task of its own: cancelling the caller (the root view's `.task`
    /// going away or restarting) neither cuts the boot short nor leaves it half done, since a
    /// later call only waits for it.
    public func run() async {
        if bootTask == nil {
            bootTask = Task { await self.sequence() }
        }
        await bootTask?.value
    }

    private func sequence() async {
        progress = .waitingForProtectedData
        await steps.waitForProtectedData()

        progress = .loading
        // Before anything reads UserDefaults, or every existing user sees onboarding again.
        steps.importLegacyPreferences()
        onboarding.load()
        if let loadSyncAccount = steps.loadSyncAccount {
            syncAccountTask = Task { await loadSyncAccount() }
        }
        await withDiscardingTaskGroup { group in
            group.addTask { await self.database.open() }
            group.addTask { await self.loadHouseholdSession() }
        }
        progress = .finished

        let purge = steps.purgeTemporaryCaches
        cachePurgeTask = Task.detached(priority: .background) { await purge() }
    }

    private func loadHouseholdSession() async {
        await steps.loadHouseholdSession()
        householdReady = true
    }
}
