import Foundation
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage
import InventoryTestSupport
import Synchronization
import Testing
@testable import InventoryAppModels

// The wave 3 seams, checked together: every app-level model built the way the composition root
// (AppContainer, 09 §3.2) will build them, from what DatabaseModel and AppBoot expose, over
// in-memory fakes (keychain, preferences, a temporary database, a stub home server and a fake
// sync Worker). If a seam stops lining up, this file stops compiling.
//
// Names carry the Integration prefix so they never collide with an area's own helpers.

/// The app's object graph, wired as AppContainer will wire it.
@MainActor
private final class IntegrationAppContainer {
    nonisolated static let householdOrigin = "https://inventory.wystudio.be"
    nonisolated static let pairAnswer = #"{"deviceId":"dev-9","token":"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd","origin":"https://box.example/","householdName":"Home","contractVersion":1}"#

    let keychain: InMemoryKeychain
    let preferences: InMemoryPreferences
    let directory: TemporaryDirectory
    let homeServer: StubServer
    let worker: SyncModelFakeWorker
    let clock: ManualClock
    let telemetry: TelemetryReporter

    let database: DatabaseModel
    let onboarding: OnboardingModel
    let lifecycle: AppLifecycle
    let toasts: ToastCenter
    let household: HouseholdModel
    let connection: ConnectionModel
    let repositories: RepositoryProvider
    let sync: SyncModel
    let boot: AppBoot

    init() throws {
        let keychain = InMemoryKeychain()
        let preferences = InMemoryPreferences()
        let directory = try TemporaryDirectory()
        let homeServer = StubServer { request in
            request.path == "/v1/pair" ? .json(200, IntegrationAppContainer.pairAnswer) : .json(200, "{}")
        }
        let worker = SyncModelFakeWorker()
        let hub = ReachabilityHub()
        let clock = ManualClock()
        let telemetry = TelemetryReporter(sink: RecordingTelemetry())

        let database = DatabaseModel(
            open: {
                let store = try DatabaseStore.temporary()
                try await store.migrate()
                return store
            },
            clock: clock,
            telemetry: telemetry
        )
        let onboarding = OnboardingModel(preferences: preferences)
        let lifecycle = AppLifecycle()
        let household = HouseholdModel(
            store: HouseholdSessionStore(keychain: keychain),
            client: homeServer.householdModelClient(origin: Self.householdOrigin, hub: hub),
            photos: HouseholdModelFakePhotos(),
            photoCache: HouseholdPhotoCache(resolver: PhotoPathResolver(documents: directory.documents, caches: directory.caches)),
            protectedData: HouseholdModel.ProtectedDataGate(isAvailable: { true }, waitUntilAvailable: {})
        )
        // Created with the lifecycle's activity: AppLifecycle starts at .inactive, while
        // ConnectionModel defaults to .active.
        let connection = ConnectionModel(
            reachability: hub,
            client: household.client,
            invalidator: database,
            joinPreferences: HouseholdJoinPreferences(preferences: preferences),
            activity: lifecycle.activity,
            clock: clock,
            announce: { _ in }
        )
        let repositories = RepositoryProvider(
            household: household,
            localRepositories: { database.repositories },
            telemetry: telemetry
        )
        let sync = SyncModel(
            config: AppConfig(syncEndpoint: "https://sync.example"),
            coordinator: SyncCoordinator(
                accounts: SyncAccountStore(keychain: keychain),
                lastBackup: LastBackupPreference(preferences: preferences),
                photos: SyncModelPhotoFiles(),
                resolver: nil,
                makeClient: worker.clientFactory,
                telemetry: telemetry,
                now: { 2_000 }
            ),
            invalidator: database,
            waitForProtectedData: {},
            telemetry: telemetry
        )
        // Never read the keychain for backup in a build without a sync endpoint.
        // A closure in a ternary is not typed from context, so it cannot become @MainActor @Sendable.
        var loadSyncAccount: (@MainActor @Sendable () async -> Void)?
        if sync.isConfigured { loadSyncAccount = { await sync.start() } }
        let boot = AppBoot(
            database: database,
            onboarding: onboarding,
            steps: AppBoot.Steps(
                waitForProtectedData: {},
                importLegacyPreferences: {},
                loadHouseholdSession: { await household.load() },
                loadSyncAccount: loadSyncAccount,
                purgeTemporaryCaches: {}
            )
        )

        // AppContainer's wiring, before boot.run().
        database.addStateObserver { state in
            if case .ready(let local) = state {
                sync.databaseReady(local)
            } else {
                sync.databaseUnavailable()
            }
        }
        connection.follow(household)
        lifecycle.register(.sync) { sync.activityChanged($0) }
        lifecycle.register(.connection) { connection.activityChanged($0) }

        self.keychain = keychain
        self.preferences = preferences
        self.directory = directory
        self.homeServer = homeServer
        self.worker = worker
        self.clock = clock
        self.telemetry = telemetry
        self.database = database
        self.onboarding = onboarding
        self.lifecycle = lifecycle
        toasts = ToastCenter(clock: clock)
        self.household = household
        self.connection = connection
        self.repositories = repositories
        self.sync = sync
        self.boot = boot
    }

    /// The protocols the screens' models take, satisfied by the app's own objects.
    var invalidator: any InventoryInvalidating { database }
    var toastPresenter: any ToastPresenting { toasts }

    /// Home and the shared drop zone over the current repositories (the tab shell).
    func makeHome(unpairedNotice: UnpairedNoticeModel) throws -> HomeModel {
        let repos = try #require(repositories.repositories)
        let household = household
        let connection = connection
        return HomeModel(
            revision: database.revision,
            reads: HomeReads(repositories: repos),
            dropZone: DropZoneModel(repositories: repos, revision: database.revision),
            context: HomeContext(
                householdName: { household.session?.householdName },
                connectionIsOnline: { connection.state == .online },
                connectionIsOffline: { connection.state == .offline }
            ),
            unpairedNotice: unpairedNotice,
            clock: clock,
            telemetry: telemetry,
            announce: { _ in }
        )
    }
}

@Suite("App composition (wave 3 seams)")
@MainActor
struct IntegrationAppCompositionTests {
    @Test("the app-level models build from DatabaseModel and AppBoot, and one boot reaches ready")
    func bootsToReady() async throws {
        let app = try IntegrationAppContainer()
        #expect(app.boot.phase == .booting)
        #expect(app.repositories.repositories == nil)

        await app.boot.run()
        await app.boot.syncAccountTask?.value

        // The gate: database open, session read (unpaired), onboarding still to do.
        #expect(app.boot.progress == .finished)
        #expect(app.database.status == .ready)
        #expect(app.household.ready)
        #expect(app.boot.householdReady)
        #expect(app.boot.phase == .onboarding)
        app.onboarding.complete()
        #expect(app.boot.phase == .main)

        // Unpaired: local repositories, connection local, backup off but configured.
        let local = try #require(app.repositories.repositories)
        #expect(local is LocalRepositories)
        #expect(!app.repositories.isPaired)
        #expect(app.connection.state == .local)
        #expect(app.sync.status == .off)

        // Home over the provider's repositories follows the database's revision.
        let notice = UnpairedNoticeModel(preference: UnpairedNoticePreference(preferences: app.preferences))
        let home = try app.makeHome(unpairedNotice: notice)
        home.focusChanged(true, revision: app.database.revision)
        home.dropZone.focusChanged(true, revision: app.database.revision)
        await ShellWait.until("Home's first read") { home.spaces.data != nil && home.recentRows != nil }
        #expect(home.spaces.data?.isEmpty == true)
        #expect(home.noticeVisible)
        #expect(!home.paired)

        _ = try await local.spaces.create(CreateSpaceInput(name: "Garage", icon: "🧰", color: "#5B8DEF"))
        let before = app.database.revision
        app.invalidator.invalidate()
        #expect(app.database.revision == before + 1)
        home.revisionChanged(app.database.revision)
        await ShellWait.until("Home re-read after the write") { home.spaces.data?.count == 1 }

        // The database observer handed the store to the sync model: Turn on backs up at once.
        let enabled = await app.sync.enable()
        let account = try #require(enabled.account)
        #expect(enabled == .enabled(account))
        await app.sync.waitForBackgroundWork()
        #expect(app.sync.status.account == account)
        #expect(app.worker.state.backups.count == 1)

        // Scene phase reaches sync, then the connection.
        app.lifecycle.activityChanged(.active)
        #expect(app.lifecycle.activity == .active)
        await app.sync.waitForBackgroundWork()

        // Pairing switches the provider to the shadowed household repositories and the
        // connection to online; the composition root re-points Home and invalidates.
        try await app.household.pair(bootstrapSecret: "MMWKYM2H78ABCDEFGHJKMNPQRS", deviceName: "Anna’s iPhone")
        #expect(app.repositories.isPaired)
        let shared = try #require(app.repositories.repositories)
        #expect(shared is ShadowingRepositories)
        #expect(app.connection.state == .online)
        #expect(home.paired)
        #expect(!home.noticeVisible)

        home.setReads(HomeReads(repositories: shared))
        home.dropZone.setRead(DropZoneModel.read(from: shared))
        app.invalidator.invalidate()
        home.revisionChanged(app.database.revision)
        home.dropZone.revisionChanged(app.database.revision)
        await ShellWait.until("Home re-read from the home server") { home.spaces.data?.isEmpty == true }
        #expect(app.homeServer.requests.contains { $0.line == "GET https://box.example/v1/spaces" })

        // Screens' models take the same seams.
        let move = MoveModel(
            items: shared.items, filing: false, recentPlaces: RecentPlacesStore(preferences: app.preferences),
            invalidator: app.invalidator, toasts: app.toastPresenter, haptics: { _ in },
            telemetry: app.telemetry, isFocused: { true }, close: {}
        )
        let provider = app.repositories
        let scan = ScanModel(
            permission: CameraPermissionModel(
                purpose: .scan, readAuthorization: { .authorized }, requestAccess: { true }, telemetry: app.telemetry),
            qr: { provider.repositories!.qr },
            haptics: { _ in }, telemetry: app.telemetry, clock: app.clock, navigate: { _ in }
        )
        let join = JoinFormModel(
            household: app.household, joinPreferences: HouseholdJoinPreferences(preferences: app.preferences),
            localRepositories: { provider.localRepositories }, invalidator: app.invalidator, haptics: { _ in },
            householdOrigin: IntegrationAppContainer.householdOrigin, deviceName: "Anna’s iPhone",
            telemetry: app.telemetry
        )
        _ = (move, scan, join)

        // Leaving goes back to the local repositories and the local connection state.
        app.household.disconnect(revokeDevice: false)
        #expect(!app.repositories.isPaired)
        #expect(app.repositories.repositories is LocalRepositories)
        #expect(app.connection.state == .local)
    }

    @Test("a failed open and Try again reach the sync model through the state observer")
    func retryReachesSync() async throws {
        let failures = IntegrationCounter()
        let database = DatabaseModel(
            open: {
                if failures.next() == 1 { throw ShellTestError("migrate") }
                let store = try DatabaseStore.temporary()
                try await store.migrate()
                return store
            },
            telemetry: TelemetryReporter(sink: RecordingTelemetry())
        )
        let sync = SyncModel(
            config: AppConfig(syncEndpoint: nil),
            coordinator: SyncCoordinator(
                accounts: SyncAccountStore(keychain: InMemoryKeychain()),
                lastBackup: LastBackupPreference(preferences: InMemoryPreferences()),
                photos: SyncModelPhotoFiles(),
                resolver: nil,
                makeClient: SyncModelFakeWorker().clientFactory
            ),
            invalidator: database,
            waitForProtectedData: {}
        )
        var seen: [DatabaseModel.Status] = []
        database.addStateObserver { state in
            seen.append(DatabaseModel.Status(state))
            if case .ready(let local) = state { sync.databaseReady(local) } else { sync.databaseUnavailable() }
        }
        var loadSyncAccount: (@MainActor @Sendable () async -> Void)?
        if sync.isConfigured { loadSyncAccount = { await sync.start() } }
        let boot = AppBoot(
            database: database,
            onboarding: OnboardingModel(preferences: InMemoryPreferences()),
            steps: AppBoot.Steps(
                waitForProtectedData: {}, importLegacyPreferences: {}, loadHouseholdSession: {},
                loadSyncAccount: loadSyncAccount, purgeTemporaryCaches: {}
            )
        )

        await boot.run()
        #expect(boot.phase == .failed)
        #expect(boot.syncAccountTask == nil)
        #expect(sync.status == .unavailable)

        await database.retry()
        #expect(database.status == .ready)
        #expect(seen == [.failed, .loading, .ready])
        #expect(boot.phase == .onboarding)
    }
}

/// Counts calls across isolation domains.
private final class IntegrationCounter: Sendable {
    private let value = Mutex(0)

    func next() -> Int {
        value.withLock { value in
            value += 1
            return value
        }
    }
}

private extension DatabaseModel.Status {
    init(_ state: DatabaseModel.State) {
        switch state {
        case .loading: self = .loading
        case .ready: self = .ready
        case .failed: self = .failed
        }
    }
}
