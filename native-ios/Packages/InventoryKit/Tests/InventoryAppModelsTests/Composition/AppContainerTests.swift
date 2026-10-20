import Foundation
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage
import InventoryTestSupport
import Synchronization
import Testing
@testable import InventoryAppModels

// The composition root (09 §13.2, §3.2): the wave 3 integration test, extended to the real
// AppContainer. Names carry the Composition prefix.

/// Records every keychain call.
private final class CompositionRecordingKeychain: KeychainStore {
    private let inner = InMemoryKeychain()
    private let calls = Mutex<[String]>([])

    var log: [String] { calls.withLock { $0 } }

    func string(forKey key: String) throws(KeychainError) -> String? {
        calls.withLock { $0.append("get \(key)") }
        return try inner.string(forKey: key)
    }

    func set(_ value: String, forKey key: String) throws(KeychainError) {
        calls.withLock { $0.append("set \(key)") }
        try inner.set(value, forKey: key)
    }

    func delete(forKey key: String) {
        calls.withLock { $0.append("delete \(key)") }
        inner.delete(forKey: key)
    }
}

/// Records every preference call.
private final class CompositionRecordingPreferences: PreferenceStoring {
    private let inner: InMemoryPreferences
    private let calls = Mutex<[String]>([])

    init(_ values: [String: String] = [:]) {
        inner = InMemoryPreferences(values)
    }

    var log: [String] { calls.withLock { $0 } }

    func storedString(forKey key: String) -> String? {
        calls.withLock { $0.append("read \(key)") }
        return inner.storedString(forKey: key)
    }

    func setString(_ value: String, forKey key: String) {
        calls.withLock { $0.append("write \(key)") }
        inner.setString(value, forKey: key)
    }

    func removeValue(forKey key: String) {
        calls.withLock { $0.append("remove \(key)") }
        inner.removeValue(forKey: key)
    }
}

/// Counts calls from any isolation domain.
private final class CompositionCounter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func increment() { value.withLock { $0 += 1 } }
}

/// Sends household requests to a stub home server and sync requests to the fake Worker.
private struct CompositionRoutingTransport: HTTPTransport {
    let household: StubServer
    let worker: SyncModelFakeWorker
    let sends: CompositionCounter

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        sends.increment()
        if request.url?.host == "sync.example" {
            return try await SyncModelStubTransport(server: worker.server).send(request)
        }
        return try await HouseholdModelStubTransport(household).send(request)
    }
}

/// A container over temporary directories, a stub home server and the fake Worker.
@MainActor
private struct CompositionFixture {
    nonisolated static let pairAnswer = #"{"deviceId":"dev-9","token":"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd","origin":"https://box.example/","householdName":"Home","contractVersion":1}"#

    let directory: TemporaryDirectory
    let keychain = CompositionRecordingKeychain()
    let preferences: CompositionRecordingPreferences
    let opens = CompositionCounter()
    let sends = CompositionCounter()
    let homeServer: StubServer
    let worker = SyncModelFakeWorker()
    let telemetry = RecordingTelemetry()
    let container: AppContainer

    init(onboardingCompleted: Bool = false, clock: any Clock<Duration> = ContinuousClock()) throws {
        let directory = try TemporaryDirectory(prefix: "composition")
        self.directory = directory
        preferences = CompositionRecordingPreferences(onboardingCompleted ? [PreferenceKey.onboardingCompleted: "true"] : [:])
        homeServer = StubServer { request in
            switch request.path {
            case "/v1/pair": .json(200, CompositionFixture.pairAnswer)
            case "/v1/spaces": .json(200, #"{"spaces":[]}"#)
            default: .json(200, "{}")
            }
        }
        let opens = opens
        container = AppContainer.test(
            resolver: PhotoPathResolver(documents: directory.documents, caches: directory.caches),
            config: AppConfig(syncEndpoint: "https://sync.example"),
            keychain: keychain,
            preferences: preferences,
            openDatabase: {
                opens.increment()
                let store = try DatabaseStore.temporary()
                try await store.migrate()
                return store
            },
            transport: CompositionRoutingTransport(household: homeServer, worker: worker, sends: sends),
            clock: clock,
            telemetry: TelemetryReporter(sink: telemetry)
        )
    }
}

@Suite("AppContainer")
@MainActor
struct CompositionAppContainerTests {
    @Test("building the container does no disk, keychain, preference or network I/O")
    func noIOBeforeBoot() async throws {
        let fixture = try CompositionFixture()
        let app = fixture.container

        #expect(fixture.opens.count == 0)
        #expect(fixture.keychain.log.isEmpty)
        #expect(fixture.preferences.log.isEmpty)
        #expect(fixture.sends.count == 0)
        #expect(fixture.directory.contents(of: "Documents").isEmpty)
        #expect(app.database.status == .loading)
        #expect(app.boot.phase == .booting)
        #expect(app.boot.progress == .notStarted)
        #expect(app.onboarding.status == .loading)
        #expect(!app.household.ready)
        #expect(app.connection.state == .local)
        #expect(app.lifecycle.activity == .inactive)

        // The stable repositories exist from the start and say "not ready" until the database opens.
        await #expect(throws: CurrentRepositoriesNotReady.self) {
            _ = try await app.repositories.spaces.listWithCounts()
        }
        #expect(fixture.opens.count == 0)

        await app.boot.run()
        await app.boot.syncAccountTask?.value
        #expect(fixture.opens.count == 1)
        #expect(fixture.keychain.log.contains("get \(KeychainKey.householdSession)"))
        #expect(fixture.keychain.log.contains("get \(KeychainKey.recoveryCode)"))
        #expect(fixture.preferences.log.contains("read \(PreferenceKey.onboardingCompleted)"))
    }

    @Test("one boot reaches the onboarding gate, then the main shell, and the database observer reaches sync")
    func bootsToReady() async throws {
        let fixture = try CompositionFixture()
        let app = fixture.container

        await app.boot.run()
        await app.boot.syncAccountTask?.value
        #expect(app.database.status == .ready)
        #expect(app.household.ready)
        #expect(app.boot.phase == .onboarding)
        #expect(app.sync.status == .off)
        #expect(app.repositoryProvider.repositories is LocalRepositories)

        app.onboarding.complete()
        #expect(app.boot.phase == .main)
        app.rootPhaseChanged(app.boot.phase)
        #expect(app.router.acceptsNavigation)

        // Ready reached the sync model: Turn on backs the open database up at once.
        let enabled = await app.sync.enable()
        let account = try #require(enabled.account)
        #expect(enabled == .enabled(account))
        await app.sync.waitForBackgroundWork()
        #expect(fixture.worker.state.backups.count == 1)
    }

    @Test("a failed open and Try again reach the sync model through the state observer")
    func retryReachesSync() async throws {
        let directory = try TemporaryDirectory(prefix: "composition")
        let failures = CompositionCounter()
        let app = AppContainer.test(
            resolver: PhotoPathResolver(documents: directory.documents, caches: directory.caches),
            config: AppConfig(syncEndpoint: "https://sync.example"),
            openDatabase: {
                failures.increment()
                if failures.count == 1 { throw ShellTestError("migrate") }
                return try await AppContainer.inMemoryDatabase()
            }
        )
        await app.boot.run()
        await app.boot.syncAccountTask?.value
        #expect(app.boot.phase == .failed)
        // No database for the backup: Turn on creates nothing.
        #expect(await app.sync.enable() == .notStarted(.notConfigured))

        await app.database.retry()
        #expect(app.database.status == .ready)
        #expect(app.boot.phase == .onboarding)
        // The reopened database reached the backup: Turn on creates the account (its first backup
        // fails offline, which still reveals the code).
        let enabled = await app.sync.enable()
        #expect(enabled.account != nil)
        #expect(enabled != .notStarted(.notConfigured))
        await app.sync.waitForBackgroundWork()
    }

    @Test("app activity reaches sync, then the connection, and the lifecycle remembers it")
    func activityRouting() async throws {
        let fixture = try CompositionFixture()
        let app = fixture.container
        #expect(app.activityStages == [.sync, .connection])

        var seen: [AppActivity] = []
        app.lifecycle.register(.other) { seen.append($0) }
        app.activityChanged(.active)
        app.activityChanged(.active)
        app.activityChanged(.background)
        #expect(seen == [.active, .background])
        #expect(app.lifecycle.activity == .background)
    }

    @Test("the connection hears the app come back: a paired phone re-reads on a resume 5 s after the last")
    func activityReachesTheConnection() async throws {
        let clock = ManualClock()
        let fixture = try CompositionFixture(onboardingCompleted: true, clock: clock)
        let app = fixture.container
        await app.boot.run()
        try await app.household.pair(bootstrapSecret: "MMWKYM2H78ABCDEFGHJKMNPQRS", deviceName: "Anna’s iPhone")
        #expect(app.connection.state == .online)

        // The first activation only starts the resume clock (RN: the screens read anyway).
        let armed = app.database.revision
        app.activityChanged(.active)
        #expect(app.database.revision == armed)
        app.activityChanged(.background)
        await clock.advance(by: .seconds(6))

        // Back to the front more than 5 s later: one re-read, from the connection.
        app.activityChanged(.active)
        #expect(app.database.revision == armed + 1)
    }

    @Test("the stable repositories follow the session: local, the household while paired, local again")
    func forwarderFollowsSession() async throws {
        let fixture = try CompositionFixture(onboardingCompleted: true)
        let app = fixture.container
        await app.boot.run()

        let repositories = app.repositories
        _ = try await repositories.spaces.create(CreateSpaceInput(name: "Garage", icon: "🧰", color: "#5B8DEF"))
        #expect(try await repositories.spaces.listWithCounts().map(\.space.name) == ["Garage"])
        #expect(!fixture.homeServer.requests.contains { $0.path == "/v1/spaces" })

        let before = app.database.revision
        try await app.household.pair(bootstrapSecret: "MMWKYM2H78ABCDEFGHJKMNPQRS", deviceName: "Anna’s iPhone")
        #expect(app.repositoryProvider.isPaired)
        #expect(app.database.revision == before + 1)
        #expect(try await repositories.spaces.listWithCounts().isEmpty)
        #expect(fixture.homeServer.requests.contains { $0.line == "GET https://box.example/v1/spaces" })

        app.household.disconnect(revokeDevice: false)
        #expect(app.database.revision == before + 2)
        #expect(try await repositories.spaces.listWithCounts().map(\.space.name) == ["Garage"])
    }

    @Test("Home is made once over the stable repositories and follows a join without being rebuilt")
    func homeFollowsSession() async throws {
        let fixture = try CompositionFixture(onboardingCompleted: true)
        let app = fixture.container
        await app.boot.run()

        let home = app.home
        #expect(app.home === home)
        #expect(home.dropZone === app.dropZone)
        home.focusChanged(true, revision: app.database.revision)
        app.dropZone.focusChanged(true, revision: app.database.revision)
        await ShellWait.until("Home's first read") { home.spaces.data != nil && !app.dropZone.loading }
        #expect(home.spaces.data?.isEmpty == true)
        #expect(!home.paired)

        try await app.household.pair(bootstrapSecret: "MMWKYM2H78ABCDEFGHJKMNPQRS", deviceName: "Anna’s iPhone")
        home.revisionChanged(app.database.revision)
        app.dropZone.revisionChanged(app.database.revision)
        #expect(home.paired)
        await ShellWait.until("Home re-read from the home server") {
            fixture.homeServer.requests.contains { $0.line == "GET https://box.example/v1/spaces" }
        }
    }

    @Test("the router waits for the main shell before opening a deep link")
    func gate() async throws {
        let fixture = try CompositionFixture()
        let app = fixture.container
        app.rootPhaseChanged(app.boot.phase)
        app.router.open(try #require(URL(string: "inventory://c/abc")))
        await app.boot.run()
        app.rootPhaseChanged(app.boot.phase)
        #expect(app.router.pendingExternalRequest == .deepLink(.label(token: "abc")))
        app.onboarding.complete()
        app.rootPhaseChanged(app.boot.phase)
        #expect(app.router.path(.home).map(\.route) == [.label(token: "abc")])
    }

    @Test("helpers for the screens: camera permission from the platform, the photo importer, recognition off without an endpoint")
    func helpers() async throws {
        let fixture = try CompositionFixture()
        let app = fixture.container
        let permission = app.makeCameraPermission(purpose: .scan)
        #expect(permission.authorization == .authorized)
        let importer = app.makeHouseholdImporter(for: HouseholdSession(
            origin: "https://box.example", token: "t", deviceId: "d", deviceName: "Phone", householdName: "Home"))
        _ = importer
        let result = await app.recognize("file:///nowhere/a.webp", nil)
        #expect(result == .failed(.notConfigured))
    }

    @Test("the preview container boots seeded: spaces, containers with codes, items with photos and a drop-zone backlog")
    func preview() async throws {
        let app = AppContainer.preview()
        await app.boot.run()
        #expect(app.boot.phase == .main)
        let local = try #require(app.database.repositories)
        let spaces = try await local.spaces.listWithCounts()
        #expect(spaces.map(\.space.name) == ["Attic", "Garage", "Kitchen"])
        let containers = try await local.containers.listAllWithSpace()
        #expect(containers.count == 6)
        #expect(containers.allSatisfy { !$0.container.shortCode.isEmpty })
        let waiting = try await local.items.listUnsorted()
        #expect(waiting.count == 4)
        let withPhotos = try await local.items.listRecent(limit: 100).filter { $0.photoUri != nil }
        #expect(withPhotos.count == 4)
        for item in withPhotos {
            let uri = try #require(item.photoThumbUri)
            let url = try #require(app.photoPathResolver.resolve(uri))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
