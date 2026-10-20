import Foundation
import Synchronization
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage

/// States the account screens can be put in without tapping, for the DEBUG demo
/// (`-demo YES -demoArea account -demoState <scenario>`), previews and tests. Each runs on
/// ``AppContainer/accountDemo(_:platform:now:)``: memory only, with ``AccountDemoServer``
/// answering for the home server and the backup service, so nothing leaves the device.
public enum AccountDemoScenario: String, CaseIterable, Sendable {
    /// Onboarding's Welcome on a phone of its own (the seeded inventory).
    case onboarding
    /// Onboarding's Join step (the screen moves there itself).
    case onboardingJoin
    /// Onboarding's "You are in" after joining Home (the screen moves there itself).
    case onboardingJoined
    /// Onboarding replayed on a phone that already joined: Continue only.
    case onboardingReplay
    /// Not joined: the join form. ``AccountDemoServer/householdCode`` is accepted.
    case unpaired
    /// Joined: three phones, this one first, the home server answering.
    case paired
    /// Joined, with this phone's own inventory on offer to copy in.
    case pairedOffer
    /// Joined; the phone list never answers (the skeleton).
    case devicesLoading
    /// Joined; the phone list answers 500 (a warning with Try again).
    case devicesFailed
    /// Joined; the home server is out of reach (the connection banner after 2.5 s).
    case householdOffline
    /// A build without a backup service or photo suggestions.
    case backupUnavailable
    /// Backup off: Turn on and Restore.
    case backupOff
    /// Backup on, the last backup five minutes ago.
    case backupOn
    /// Backup on, its first backup still uploading ("On, not yet run").
    case backupNotYetRun
    /// Backup on, the last backup failed (the demo runs Back up now while the service is down).
    case backupFailing
    /// The keychain refuses to read the recovery code (03 B8).
    case backupUnreadable
    /// An empty phone whose account already has backups: the Restore offer (03 B12).
    case backupRestoreOffer
    /// Turn on carries on with a code already stored instead of making one (the screen turns
    /// backup on itself while the keychain is still being read; 03 B8, B12).
    case backupKeptCode
    /// The recovery code on screen (the screen shows it itself).
    case backupReveal
    /// Joined, with backup on: the paired note over "Backup is on".
    case backupPaired

    /// Onboarding still to do.
    var onboardingPending: Bool {
        switch self {
        case .onboarding, .onboardingJoin, .onboardingJoined, .onboardingReplay: true
        default: false
        }
    }

    /// Joined to the demo household at launch.
    var startsPaired: Bool {
        switch self {
        case .paired, .pairedOffer, .devicesLoading, .devicesFailed, .householdOffline, .onboardingReplay, .backupPaired: true
        default: false
        }
    }

    /// A recovery code in the keychain at launch.
    var hasAccount: Bool {
        switch self {
        case .backupOn, .backupNotYetRun, .backupFailing, .backupUnreadable, .backupRestoreOffer, .backupKeptCode,
             .backupReveal, .backupPaired:
            true
        default: false
        }
    }

    /// A backup recorded on this phone five minutes ago.
    var hasRecentBackup: Bool {
        switch self {
        case .backupOn, .backupFailing, .backupReveal, .backupPaired: true
        default: false
        }
    }

    /// This phone's database holds only the seeded drop zone.
    var startsEmpty: Bool {
        self == .backupRestoreOffer || self == .backupKeptCode
    }
}

extension AppContainer {
    /// The container for an account demo state: an in-memory database (the seeded inventory
    /// unless the state starts empty), photos in a fresh temporary directory, an in-memory
    /// keychain and preferences, and ``AccountDemoServer`` for every request.
    ///
    /// - Parameter now: the device clock in epoch milliseconds (the "5 minutes ago" backup).
    public static func accountDemo(
        _ scenario: AccountDemoScenario,
        platform: AppPlatform,
        now: @escaping @Sendable () -> Int64 = { epochMillis() }
    ) -> AppContainer {
        accountDemoWithServer(scenario, platform: platform, now: now).app
    }

    /// ``accountDemo(_:platform:now:)`` and the server it answers from, for tests that look at
    /// the requests made or change how it answers.
    public static func accountDemoWithServer(
        _ scenario: AccountDemoScenario,
        platform: AppPlatform,
        now: @escaping @Sendable () -> Int64 = { epochMillis() }
    ) -> (app: AppContainer, server: AccountDemoServer) {
        let root = URL.temporaryDirectory.appending(path: "inventory-account-demo-\(UUID().uuidString)", directoryHint: .isDirectory)
        let resolver = PhotoPathResolver(
            documents: root.appending(path: "Documents", directoryHint: .isDirectory),
            caches: root.appending(path: "Library/Caches", directoryHint: .isDirectory)
        )
        let bundle = AppConfig.load()
        let configured = scenario != .backupUnavailable
        let config = AppConfig(
            recognitionEndpoint: configured ? AccountDemoServer.recognitionEndpoint : nil,
            syncEndpoint: configured ? AccountDemoServer.syncEndpoint : nil,
            householdOrigin: AccountDemoServer.householdOrigin,
            environment: bundle.environment,
            appVersion: bundle.appVersion
        )

        let launchedAt = now()
        var stored: [String: String] = [:]
        if !scenario.onboardingPending { stored[PreferenceKey.onboardingCompleted] = "true" }
        if scenario.startsPaired { stored[PreferenceKey.householdJoinedBefore] = "true" }
        if scenario == .pairedOffer { stored[PreferenceKey.householdImportOffer] = #"{"spaces":3,"items":12}"# }
        let recentBackupAt = launchedAt - 5 * 60 * 1000
        if scenario.hasRecentBackup { stored[PreferenceKey.lastBackupAt] = String(recentBackupAt) }
        let preferences = InMemoryPreferences(stored)

        let codes = InMemoryKeychain()
        if scenario.hasAccount { try? codes.set(AccountDemoServer.recoveryCode, forKey: KeychainKey.recoveryCode) }
        if scenario.startsPaired { try? HouseholdSessionStore(keychain: codes).save(AccountDemoServer.session) }
        let keychain: any KeychainStore = switch scenario {
        case .backupUnreadable: AccountDemoKeychain(codes, refusesRecoveryCode: true)
        case .backupKeptCode: AccountDemoKeychain(codes, firstRecoveryCodeReadDelay: .seconds(3))
        default: codes
        }

        let devices: AccountDemoServer.Devices = switch scenario {
        case .devicesLoading: .hang
        case .devicesFailed: .fail
        default: .answer
        }
        let server = AccountDemoServer(
            behaviour: AccountDemoServer.Behaviour(
                householdReachable: scenario != .householdOffline,
                devices: devices,
                backupServiceReachable: scenario != .backupFailing,
                backupsHang: scenario == .backupNotYetRun
            ),
            phones: scenario.startsPaired ? AccountDemoServer.phones(now: launchedAt) : [],
            backups: scenario.hasAccount ? [AccountDemoServer.StoredBackup(capturedAt: scenario.hasRecentBackup ? recentBackupAt : launchedAt - 3 * 86_400_000)] : [],
            savedInventory: {
                // The newest backup's bytes: the sample inventory, its photos stored where this
                // container keeps them, so a restore brings them along.
                let store = try DatabaseStore.inMemory()
                try await store.migrate()
                try await AppContainerPreviewData.seed(
                    LocalRepositories(store: store, environment: AppContainerPreviewData.environment),
                    photos: ImageStore(resolver: resolver)
                )
                return try await store.snapshot()
            },
            now: now
        )

        let seed = !scenario.startsEmpty
        let app = AppContainer(
            dependencies: Dependencies(
                config: config,
                keychain: keychain,
                preferences: preferences,
                openDatabase: {
                    let store = try DatabaseStore.inMemory()
                    try await store.migrate()
                    if seed {
                        try await AppContainerPreviewData.seed(
                            LocalRepositories(store: store, environment: AppContainerPreviewData.environment),
                            photos: ImageStore(resolver: resolver)
                        )
                    }
                    return store
                },
                repositoryEnvironment: AppContainerPreviewData.environment,
                transport: server,
                networkTelemetry: NetworkTelemetry(event: { _, _ in }, error: { _, _ in }),
                photoPathResolver: resolver,
                protectedData: HouseholdModel.ProtectedDataGate(isAvailable: { true }, waitUntilAvailable: {}),
                bootSystem: .inert,
                now: now
            ),
            platform: platform
        )
        return (app, server)
    }
}

/// A keychain that stands in for one the device will not read: every read of the recovery
/// code refused (`errSecInteractionNotAllowed`, as while locked), or the first one slow.
public final class AccountDemoKeychain: KeychainStore {
    private let inner: InMemoryKeychain
    private let refusesRecoveryCode: Bool
    private let firstReadDelay: Duration?
    private let reads = Mutex(0)

    public init(_ inner: InMemoryKeychain, refusesRecoveryCode: Bool = false, firstRecoveryCodeReadDelay: Duration? = nil) {
        self.inner = inner
        self.refusesRecoveryCode = refusesRecoveryCode
        firstReadDelay = firstRecoveryCodeReadDelay
    }

    public func string(forKey key: String) throws(KeychainError) -> String? {
        if key == KeychainKey.recoveryCode {
            if refusesRecoveryCode { throw InMemoryKeychain.simulatedFailure }
            let first = reads.withLock { count in
                defer { count += 1 }
                return count == 0
            }
            if first, let firstReadDelay {
                let parts = firstReadDelay.components
                Thread.sleep(forTimeInterval: Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
            }
        }
        return try inner.string(forKey: key)
    }

    public func set(_ value: String, forKey key: String) throws(KeychainError) {
        try inner.set(value, forKey: key)
    }

    public func delete(forKey key: String) {
        inner.delete(forKey: key)
    }
}
