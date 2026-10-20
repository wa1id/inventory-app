import Foundation
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage
import Observation

/// The composition root: every app-scoped model and service, built once and wired together
/// (09 §13.2, §3.2; the wave 3 hand-off list).
///
/// Building it does no disk, keychain or network I/O (09 §3.2 step 0): the root view's `.task`
/// runs ``boot`` (`AppBoot.run()`), which reads protected data, imports the RN preferences, opens
/// the database and loads the household session and the backup account. Everything that must
/// not wait for the gate is wired here, before boot runs, as RN's providers sat above the gate:
/// - the database's state reaches the backup model (`ready` → `SyncModel.databaseReady`,
///   anything else → `databaseUnavailable`);
/// - the connection follows the household session (once);
/// - app activity reaches sync, then the connection (``activityChanged(_:)``, in that order);
/// - every session change re-points Home's and the drop zone's reads and invalidates.
///
/// Factories: ``live(platform:)`` for the app, ``preview(platform:seed:onboardingCompleted:)``
/// for `#Preview`s and the DEBUG demo, ``test(resolver:config:keychain:preferences:openDatabase:transport:clock:telemetry:platform:)``
/// for tests.
@MainActor
@Observable
public final class AppContainer {
    /// Where the I/O goes. Live, preview and test containers differ only here.
    public struct Dependencies: Sendable {
        public var config: AppConfig
        public var keychain: any KeychainStore
        public var preferences: any PreferenceStoring
        /// Opens and migrates the database (the live file, or an in-memory one).
        public var openDatabase: DatabaseModel.Opener
        public var repositoryEnvironment: RepositoryEnvironment
        /// Every HTTP client's transport (household, sync, recognition).
        public var transport: any HTTPTransport
        public var networkTelemetry: NetworkTelemetry
        /// The container's `Documents` and `Library/Caches` (photos, the household photo cache).
        public var photoPathResolver: PhotoPathResolver
        public var protectedData: HouseholdModel.ProtectedDataGate
        /// The timers' clock.
        public var clock: any Clock<Duration>
        public var telemetry: TelemetryReporter
        /// The boot steps that touch the system (protected data, the legacy preference import,
        /// the cache purge); nil runs the live ones (`AppBoot.Steps.live`).
        public var bootSystem: BootSystem?
        /// Epoch milliseconds.
        public var now: @Sendable () -> Int64

        public init(
            config: AppConfig,
            keychain: any KeychainStore,
            preferences: any PreferenceStoring,
            openDatabase: @escaping DatabaseModel.Opener,
            repositoryEnvironment: RepositoryEnvironment = .live,
            transport: any HTTPTransport,
            networkTelemetry: NetworkTelemetry = .standard,
            photoPathResolver: PhotoPathResolver,
            protectedData: HouseholdModel.ProtectedDataGate,
            clock: any Clock<Duration> = ContinuousClock(),
            telemetry: TelemetryReporter = .shared,
            bootSystem: BootSystem? = nil,
            now: @escaping @Sendable () -> Int64 = { epochMillis() }
        ) {
            self.config = config
            self.keychain = keychain
            self.preferences = preferences
            self.openDatabase = openDatabase
            self.repositoryEnvironment = repositoryEnvironment
            self.transport = transport
            self.networkTelemetry = networkTelemetry
            self.photoPathResolver = photoPathResolver
            self.protectedData = protectedData
            self.clock = clock
            self.telemetry = telemetry
            self.bootSystem = bootSystem
            self.now = now
        }

        /// The app's: `Info.plist` config, the Expo-compatible keychain, `UserDefaults.standard`,
        /// `Documents/SQLite/inventory.db`, the shared URL session and the real container.
        public static func live() -> Dependencies {
            Dependencies(
                config: AppConfig.load(),
                keychain: ExpoCompatibleKeychain(),
                preferences: UserDefaults.standard,
                openDatabase: { try await DatabaseStore.openLive() },
                transport: URLSessionTransport.shared,
                photoPathResolver: PhotoPathResolver(),
                protectedData: .live
            )
        }
    }

    /// Boot steps that stand in for the system ones (tests, previews).
    public struct BootSystem: Sendable {
        public var waitForProtectedData: @MainActor @Sendable () async -> Void
        public var importLegacyPreferences: @MainActor @Sendable () -> Void
        public var purgeTemporaryCaches: @Sendable () async -> Void

        public init(
            waitForProtectedData: @escaping @MainActor @Sendable () async -> Void = {},
            importLegacyPreferences: @escaping @MainActor @Sendable () -> Void = {},
            purgeTemporaryCaches: @escaping @Sendable () async -> Void = {}
        ) {
            self.waitForProtectedData = waitForProtectedData
            self.importLegacyPreferences = importLegacyPreferences
            self.purgeTemporaryCaches = purgeTemporaryCaches
        }

        /// Nothing to wait for, import or purge.
        public static let inert = BootSystem()
    }

    // MARK: Platform and configuration

    public let platform: AppPlatform
    public let config: AppConfig
    public let telemetry: TelemetryReporter
    /// The timers' clock (the screen models take it).
    public let clock: any Clock<Duration>
    /// Epoch milliseconds (the screen models take it).
    public let now: @Sendable () -> Int64

    // MARK: Services

    /// The one reachability side channel every household request reports to.
    public let reachability: ReachabilityHub
    /// The household client aimed at the build's origin, without a token (pairing); its
    /// transport and hub carry over to every session client.
    public let householdClient: HouseholdClient
    public let photoPathResolver: PhotoPathResolver
    /// Item photos on disk.
    public let imageStore: ImageStore
    public let photoCache: HouseholdPhotoCache
    public let recognition: RecognitionClient
    /// The app-scoped Quick Snap pipeline: shots keep processing after the camera closes.
    public let fastCapture: FastCapturePipeline
    /// The sync service shared by the backup model and the household import's photo fallback.
    public let syncCoordinator: SyncCoordinator

    // MARK: Preferences and memory

    public let preferences: any PreferenceStoring
    public let keychain: any KeychainStore
    public let recentPlaces: RecentPlacesStore
    public let categories: CategoryMemory
    public let joinPreferences: HouseholdJoinPreferences
    public let unpairedNotice: UnpairedNoticeModel
    /// The one Add-sheet draft.
    public let drafts: AddDraftStore

    // MARK: Models

    public let database: DatabaseModel
    public let onboarding: OnboardingModel
    public let lifecycle: AppLifecycle
    public let toasts: ToastCenter
    public let household: HouseholdModel
    public let connection: ConnectionModel
    public let repositoryProvider: RepositoryProvider
    public let sync: SyncModel
    public let boot: AppBoot
    public let router: Router
    /// The tab shell's shared drop-zone read (badge, Home card, Drop zone list).
    public let dropZone: DropZoneModel
    /// The repositories in use at each call; hand this to models created once (see
    /// ``CurrentRepositories``).
    public let repositories: CurrentRepositories

    @ObservationIgnored private var homeModel: HomeModel?
    /// The lifecycle stages the container registered, in order (for tests).
    @ObservationIgnored private(set) var activityStages: [AppLifecycle.Stage] = []
    @ObservationIgnored private let transport: any HTTPTransport

    // MARK: Factories

    /// The app's container. No I/O happens until ``boot`` runs.
    public static func live(platform: AppPlatform) -> AppContainer {
        AppContainer(dependencies: .live(), platform: platform)
    }

    /// A container for tests: in-memory keychain, preferences and database, an offline network
    /// and no system boot steps, unless given. Photos go under `resolver` (a temporary directory).
    public static func test(
        resolver: PhotoPathResolver,
        config: AppConfig = AppConfig(),
        keychain: any KeychainStore = InMemoryKeychain(),
        preferences: any PreferenceStoring = InMemoryPreferences(),
        openDatabase: @escaping DatabaseModel.Opener = AppContainer.inMemoryDatabase,
        transport: any HTTPTransport = ShellOfflineTransport(),
        clock: any Clock<Duration> = ContinuousClock(),
        telemetry: TelemetryReporter = .shared,
        platform: AppPlatform = .silent()
    ) -> AppContainer {
        AppContainer(
            dependencies: Dependencies(
                config: config,
                keychain: keychain,
                preferences: preferences,
                openDatabase: openDatabase,
                transport: transport,
                networkTelemetry: NetworkTelemetry(event: { _, _ in }, error: { _, _ in }),
                photoPathResolver: resolver,
                protectedData: HouseholdModel.ProtectedDataGate(isAvailable: { true }, waitUntilAvailable: {}),
                clock: clock,
                telemetry: telemetry,
                bootSystem: .inert
            ),
            platform: platform
        )
    }

    /// A migrated private in-memory database.
    public nonisolated static let inMemoryDatabase: DatabaseModel.Opener = {
        let store = try DatabaseStore.inMemory()
        try await store.migrate()
        return store
    }

    /// Builds the graph over `dependencies`. Does no I/O.
    public init(dependencies: Dependencies, platform: AppPlatform) {
        let config = dependencies.config
        let clock = dependencies.clock
        let telemetry = dependencies.telemetry
        let resolver = dependencies.photoPathResolver
        let preferences = dependencies.preferences
        let transport = dependencies.transport

        self.platform = platform
        self.config = config
        self.telemetry = telemetry
        self.clock = clock
        now = dependencies.now
        self.preferences = preferences
        keychain = dependencies.keychain
        photoPathResolver = resolver
        self.transport = transport

        // Services.
        let hub = ReachabilityHub()
        reachability = hub
        let imageStore = ImageStore(resolver: resolver)
        self.imageStore = imageStore
        let photoCache = HouseholdPhotoCache(resolver: resolver)
        self.photoCache = photoCache
        let recognition = RecognitionClient(
            endpoint: config.recognitionEndpoint,
            key: config.recognitionKey,
            timeout: config.recognitionTimeout,
            transport: transport,
            telemetry: dependencies.networkTelemetry
        )
        self.recognition = recognition
        fastCapture = FastCapturePipeline(
            photos: imageStore,
            recognizer: FastCapturePipeline.recognizer(client: recognition, resolver: resolver)
        )
        let syncCoordinator = SyncCoordinator(
            accounts: SyncAccountStore(keychain: dependencies.keychain),
            lastBackup: LastBackupPreference(preferences: preferences),
            photos: imageStore,
            resolver: resolver,
            makeClient: { code in
                SyncClient(
                    recoveryCode: code,
                    endpoint: config.syncEndpoint,
                    key: config.syncKey,
                    timeout: config.syncTimeout,
                    transport: transport,
                    telemetry: dependencies.networkTelemetry
                )
            },
            telemetry: telemetry,
            now: dependencies.now
        )
        self.syncCoordinator = syncCoordinator

        // Preferences and memory (read lazily: nothing is read before boot imports them).
        recentPlaces = RecentPlacesStore(preferences: preferences)
        categories = CategoryMemory(preferences: preferences)
        let joinPreferences = HouseholdJoinPreferences(preferences: preferences)
        self.joinPreferences = joinPreferences
        unpairedNotice = UnpairedNoticeModel(preference: UnpairedNoticePreference(preferences: preferences))
        drafts = AddDraftStore(photos: imageStore)

        // Models.
        let database = DatabaseModel(
            open: dependencies.openDatabase,
            environment: dependencies.repositoryEnvironment,
            clock: clock,
            telemetry: telemetry
        )
        self.database = database
        let onboarding = OnboardingModel(preferences: preferences)
        self.onboarding = onboarding
        let lifecycle = AppLifecycle()
        self.lifecycle = lifecycle
        toasts = ToastCenter(
            clock: clock,
            isVoiceOverRunning: platform.isVoiceOverRunning(),
            announce: platform.announceQueued
        )
        let householdClient = HouseholdClient(
            origin: config.householdOrigin,
            token: nil,
            transport: transport,
            reachability: hub,
            clock: clock,
            telemetry: dependencies.networkTelemetry
        )
        let household = HouseholdModel(
            store: HouseholdSessionStore(keychain: dependencies.keychain),
            client: householdClient,
            photos: imageStore,
            photoCache: photoCache,
            protectedData: dependencies.protectedData
        )
        self.household = household
        self.householdClient = household.client
        // With the lifecycle's activity: AppLifecycle starts inactive, ConnectionModel active.
        let connection = ConnectionModel(
            reachability: hub,
            client: household.client,
            invalidator: database,
            joinPreferences: joinPreferences,
            activity: lifecycle.activity,
            clock: clock,
            announce: platform.announce
        )
        self.connection = connection
        let provider = RepositoryProvider(
            household: household,
            localRepositories: { [weak database] in database?.repositories },
            telemetry: telemetry
        )
        repositoryProvider = provider
        let protectedData = dependencies.protectedData
        let sync = SyncModel(
            config: config,
            coordinator: syncCoordinator,
            invalidator: database,
            waitForProtectedData: { await protectedData.waitUntilAvailable() },
            telemetry: telemetry
        )
        self.sync = sync

        // Never read the keychain for backup in a build without a sync endpoint. A closure in a
        // ternary is not typed from context, so this is an `if`.
        var loadSyncAccount: (@MainActor @Sendable () async -> Void)?
        if sync.isConfigured { loadSyncAccount = { await sync.start() } }
        let steps: AppBoot.Steps
        if let system = dependencies.bootSystem {
            steps = AppBoot.Steps(
                waitForProtectedData: system.waitForProtectedData,
                importLegacyPreferences: system.importLegacyPreferences,
                loadHouseholdSession: { await household.load() },
                loadSyncAccount: loadSyncAccount,
                purgeTemporaryCaches: system.purgeTemporaryCaches
            )
        } else {
            steps = .live(loadHouseholdSession: { await household.load() }, loadSyncAccount: loadSyncAccount)
        }
        boot = AppBoot(database: database, onboarding: onboarding, steps: steps)

        router = Router(haptics: platform.haptics, clock: clock)
        let repositories = CurrentRepositories(provider: provider)
        self.repositories = repositories
        dropZone = DropZoneModel(repositories: repositories, revision: database.revision)

        wire()
    }

    /// The wiring that must be in place before boot runs (09 §3.2 step 4).
    private func wire() {
        let sync = sync
        database.addStateObserver { state in
            if case .ready(let local) = state {
                sync.databaseReady(local)
            } else {
                sync.databaseUnavailable()
            }
        }
        connection.follow(household)
        let connection = connection
        lifecycle.register(.sync) { sync.activityChanged($0) }
        lifecycle.register(.connection) { connection.activityChanged($0) }
        activityStages = [.sync, .connection]
        household.addSessionObserver { [weak self] _ in
            self?.sessionChanged()
        }
    }

    /// Joined, rejoined or left: Home's and the drop zone's reads follow the new repositories
    /// (they already resolve them per call through ``repositories``; the reads are re-set so a
    /// model that cached one starts clean), then every screen reads again.
    private func sessionChanged() {
        dropZone.setRead(DropZoneModel.read(from: repositories))
        homeModel?.setReads(homeReads)
        database.invalidate()
    }

    // MARK: Shell inputs

    /// The app's scene phase changed: sync first, then the connection (09 §6).
    public func activityChanged(_ activity: AppActivity) {
        lifecycle.activityChanged(activity)
    }

    /// The root view's gate changed: deep links and quick actions are delivered once the main
    /// shell shows, and navigation resets when onboarding replays.
    public func rootPhaseChanged(_ phase: BootGate.Phase) {
        router.setAcceptsNavigation(phase == .main)
    }

    // MARK: Screen models

    /// Home's reads over the current repositories. A search that finds nothing is corrected
    /// against the words of this phone's own database, local or joined (in a household it holds
    /// what this phone had and wrote), so household search needs nothing new from the home server.
    private var homeReads: HomeReads {
        let database = database
        return HomeReads(repositories: repositories, vocabulary: {
            guard let local = await MainActor.run(body: { database.repositories }) else { return .empty }
            return try await local.search.vocabulary()
        })
    }

    /// Home's model, made the first time Home shows and kept for the life of the app (the tab
    /// root never goes away while the main shell is up).
    public var home: HomeModel {
        if let homeModel { return homeModel }
        let household = household
        let connection = connection
        let categories = categories
        let model = HomeModel(
            revision: database.revision,
            reads: homeReads,
            dropZone: dropZone,
            context: HomeContext(
                householdName: { household.session?.householdName },
                connectionIsOnline: { connection.state == .online },
                connectionIsOffline: { connection.state == .offline }
            ),
            unpairedNotice: unpairedNotice,
            clock: clock,
            telemetry: telemetry,
            rememberCategories: { categories.rememberCategories($0) },
            announce: platform.announce
        )
        homeModel = model
        return model
    }

    /// Recognises a stored photo, anchored to a name hint (the Add sheet's `recognize`): the URI
    /// is resolved against the current container first (DECISIONS D-4).
    public var recognize: AddSheetModel.Recognize {
        let resolver = photoPathResolver
        let recognition = recognition
        return { uri, hint in
            let url = resolver.resolve(uri) ?? URL(string: uri) ?? URL(filePath: uri)
            return await recognition.recognize(imageAt: url, nameHint: hint)
        }
    }

    /// The camera permission gate for the capture screen or the Scan tab.
    public func makeCameraPermission(purpose: CameraPermissionPurpose) -> CameraPermissionModel {
        CameraPermissionModel(
            purpose: purpose,
            readAuthorization: platform.cameraAuthorization,
            requestAccess: platform.requestCameraAccess,
            telemetry: telemetry
        )
    }

    /// Copies this phone's inventory into `session`'s household; a photo missing here comes from
    /// the backup when this phone has one (RN importHousehold.ts).
    public func makeHouseholdImporter(for session: HouseholdSession) -> HouseholdImporter {
        HouseholdImporter(
            session: session,
            client: householdClient,
            photos: imageStore,
            makeFallback: HouseholdImporter.backupPhotoFallback(
                recoveryCodes: RecoveryCodeStore(keychain: keychain),
                config: config,
                transport: transport
            ),
            telemetry: telemetry
        )
    }
}

/// A transport with no network: every request fails as if offline. The test and preview default,
/// so nothing ever reaches a real server.
public struct ShellOfflineTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}
