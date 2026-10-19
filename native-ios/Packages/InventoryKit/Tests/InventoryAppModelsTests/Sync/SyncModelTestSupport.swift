import Foundation
import GRDB
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage
import InventoryTestSupport
import Synchronization
@testable import InventoryAppModels

// Doubles for the SyncModel tests. Names carry the SyncModel prefix so they never collide with
// another model's helpers in this target.

/// A minimal sync Worker behind a real `SyncClient` over ``StubServer``: photos, backups
/// (`capturedAt = 1000 × n`, as RN's backup.test.ts fake), listing, per-route failures, and
/// holds that park a request until the test releases it.
final class SyncModelFakeWorker: Sendable {
    struct Backup: Sendable {
        let bytes: Data
        let schemaVersion: String
        let capturedAt: Int64
    }

    struct State: Sendable {
        var photos: [String: Data] = [:]
        var backups: [Backup] = []
        var offlineBackups = false
        var offlinePhotos = false
    }

    private final class Box: Sendable {
        let state = Mutex(State())
        let holds = Mutex<[(method: String, path: String, hold: SyncModelRequestHold)]>([])

        func handle(_ request: RecordedRequest) async -> StubReply {
            let hold = holds.withLock { holds -> SyncModelRequestHold? in
                guard let index = holds.firstIndex(where: { $0.method == request.method && request.path.hasPrefix($0.path) })
                else { return nil }
                return holds.remove(at: index).hold
            }
            if let hold { await hold.arriveAndWait() }
            return state.withLock { route(request, &$0) }
        }

        private func route(_ request: RecordedRequest, _ s: inout State) -> StubReply {
            let offline = StubReply.failure(.notConnectedToInternet, delay: nil)
            let path = request.path
            if path.hasPrefix("/v1/photos/") {
                if s.offlinePhotos { return offline }
                let id = String(path.dropFirst("/v1/photos/".count))
                switch request.method {
                case "PUT":
                    s.photos[id] = request.body
                    return .json(201, #"{"id":"\#(id)","size":\#(request.body.count)}"#)
                case "GET":
                    guard let bytes = s.photos[id] else { return .json(404, #"{"error":"Not found."}"#) }
                    return .bytes(200, bytes)
                default:
                    s.photos[id] = nil
                    return .status(204)
                }
            }
            if s.offlineBackups { return offline }
            switch (request.method, path) {
            case ("PUT", "/v1/backups"):
                let capturedAt = Int64(1000 * (s.backups.count + 1))
                let schema = request.header("x-snapshot-schema-version") ?? "0"
                s.backups.append(Backup(bytes: request.body, schemaVersion: schema, capturedAt: capturedAt))
                return .json(201, #"{"id":"\#(capturedAt)","size":\#(request.body.count),"capturedAt":\#(capturedAt),"schemaVersion":\#(schema)}"#)
            case ("GET", "/v1/backups"):
                let items = s.backups.reversed().map {
                    #"{"id":"\#($0.capturedAt)","size":\#($0.bytes.count),"capturedAt":\#($0.capturedAt),"schemaVersion":\#($0.schemaVersion)}"#
                }
                return .json(200, #"{"contractVersion":1,"backups":[\#(items.joined(separator: ","))]}"#)
            case ("GET", "/v1/backups/latest"):
                guard let newest = s.backups.last else { return .json(404, #"{"error":"No backups yet."}"#) }
                return .bytes(200, newest.bytes, headers: ["x-snapshot-schema-version": newest.schemaVersion])
            default:
                return .json(404, #"{"error":"Not found."}"#)
            }
        }
    }

    private let box: Box
    let server: StubServer
    let telemetry = RecordingTelemetry()

    init() {
        let box = Box()
        self.box = box
        server = StubServer { request in await box.handle(request) }
    }

    var clientFactory: SyncCoordinator.ClientFactory {
        { [self] code in
            SyncClient(
                recoveryCode: code, endpoint: "https://sync.example", key: nil, timeout: .seconds(20),
                transport: SyncModelStubTransport(server: server),
                telemetry: NetworkTelemetry(event: { _, _ in }, error: { _, _ in })
            )
        }
    }

    var state: State { box.state.withLock { $0 } }

    func update(_ change: (inout State) -> Void) {
        box.state.withLock { change(&$0) }
    }

    @discardableResult
    func hold(_ method: String, _ path: String) -> SyncModelRequestHold {
        let hold = SyncModelRequestHold()
        box.holds.withLock { $0.append((method, path, hold)) }
        return hold
    }

    var requestLines: [String] { server.requests.map { "\($0.method) \($0.path)" } }
}

struct SyncModelStubTransport: HTTPTransport {
    let server: StubServer

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await URLSessionTransport(session: server.session).send(request)
    }
}

/// A request parked in the fake Worker until released.
final class SyncModelRequestHold: Sendable {
    private struct State {
        var arrived = false
        var released = false
        /// A waiting test was cancelled (its time limit ran out): stop waiting for arrivals.
        var abandoned = false
        var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
        var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func arriveAndWait() async {
        let arrivals = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.arrived = true
            defer { state.arrivalWaiters = [] }
            return state.arrivalWaiters
        }
        for waiter in arrivals { waiter.resume() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state -> Bool in
                if state.released { return true }
                state.releaseWaiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Returns once the parked request has arrived, or once the waiting test is cancelled, so a
    /// suite's time limit ends a test whose request never comes.
    func arrived() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = state.withLock { state -> Bool in
                    if state.arrived || state.abandoned { return true }
                    state.arrivalWaiters.append(continuation)
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.abandoned = true
                defer { state.arrivalWaiters = [] }
                return state.arrivalWaiters
            }
            for waiter in waiters { waiter.resume() }
        }
    }

    func release() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.released = true
            defer { state.releaseWaiters = [] }
            return state.releaseWaiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// An ``InMemoryKeychain`` that counts reads, to prove when the keychain is not touched.
final class SyncModelCountingKeychain: KeychainStore {
    let inner: InMemoryKeychain
    private let readCount = Mutex(0)

    init(_ values: [String: String] = [:]) {
        inner = InMemoryKeychain(values)
    }

    var reads: Int { readCount.withLock { $0 } }
    var values: [String: String] { inner.values }

    func string(forKey key: String) throws(KeychainError) -> String? {
        readCount.withLock { $0 += 1 }
        return try inner.string(forKey: key)
    }

    func set(_ value: String, forKey key: String) throws(KeychainError) {
        try inner.set(value, forKey: key)
    }

    func delete(forKey key: String) {
        inner.delete(forKey: key)
    }
}

/// Photo files as a URI-to-bytes map (RN photoSync.test.ts's mock of the image store).
final class SyncModelPhotoFiles: PhotoStoring {
    private let storage = Mutex<[String: Data]>([:])

    var files: [String: Data] { storage.withLock { $0 } }

    func set(_ data: Data?, at uri: String) { storage.withLock { $0[uri] = data } }

    func storeItemPhoto(_ source: ImageSource, cropToAspect aspect: CGSize?) async throws -> StoredImage {
        throw ImageStoreError.couldNotProcess
    }

    func writeStoredPhoto(photoId: String, bytes: Data) async throws -> StoredImage {
        let uri = "file:///documents/item-photos/\(photoId).webp"
        let thumbUri = "file:///documents/item-photos/\(photoId)-thumb.webp"
        storage.withLock {
            $0[uri] = bytes
            $0[thumbUri] = bytes.prefix(1)
        }
        return StoredImage(uri: uri, thumbUri: thumbUri, width: 0, height: 0, byteSize: bytes.count)
    }

    func readStoredPhoto(_ uri: String) async -> Data? { storage.withLock { $0[uri] } }

    func deleteStoredPhotos(_ uris: [String?]) {
        storage.withLock { files in for uri in uris { if let uri { files[uri] = nil } } }
    }

    func hasRoomForPhoto(estimatedBytes: Int64) -> Bool { true }
}

/// A gate standing in for "protected data is available": `wait()` returns once `open()` ran.
@MainActor
final class SyncModelProtectedDataGate {
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waits = 0

    init(open: Bool) {
        isOpen = open
    }

    func wait() async {
        waits += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

/// Everything a SyncModel test needs, wired as the app wires it.
@MainActor
final class SyncModelHarness {
    static let code = "89144GJ289144GJ289144GJ288"
    static let account = SyncAccount(id: "900dfeb7f1b5e344209e2abce56c333d", recoveryCode: code)

    let store: DatabaseStore
    let worker: SyncModelFakeWorker
    let keychain: SyncModelCountingKeychain
    let preferences: InMemoryPreferences
    let files: SyncModelPhotoFiles
    let invalidations: SharedSeamsInvalidationCounter
    let telemetry: RecordingTelemetry
    let gate: SyncModelProtectedDataGate
    let coordinator: SyncCoordinator
    let model: SyncModel

    /// - Parameters:
    ///   - endpoint: the sync endpoint; nil makes backup unavailable.
    ///   - keychain: what the keychain holds.
    ///   - preferences: the stored preferences (the `lastBackupAt` marker).
    ///   - empty: a database with only the seeded drop zone (a reinstall) instead of a Garage with
    ///     one item.
    ///   - protectedDataAvailable: whether the gate starts open.
    ///   - now: the coordinator's device clock (epoch ms); 2000 keeps the gate closed right after
    ///     the fake Worker's first `capturedAt` of 1000.
    init(
        endpoint: String? = "https://sync.example",
        keychain: [String: String] = [:],
        preferences: [String: String] = [:],
        empty: Bool = false,
        protectedDataAvailable: Bool = true,
        now: Int64 = 2_000
    ) async throws {
        store = try DatabaseStore.temporary()
        let repos = try await LocalRepositories.initialize(store)
        if !empty {
            let space = try await repos.spaces.create(CreateSpaceInput(name: "Garage", icon: "car", color: "#5B8DEF"))
            let container = try await repos.containers.create(CreateContainerInput(spaceId: space.id, visualType: .box))
            _ = try await repos.items.create(ItemDraft(containerId: container.id, name: "Cordless Drill", quantity: 1))
        }
        let countingKeychain = SyncModelCountingKeychain(keychain)
        let storedPreferences = InMemoryPreferences(preferences)
        let gate = SyncModelProtectedDataGate(open: protectedDataAvailable)
        let worker = SyncModelFakeWorker()
        let files = SyncModelPhotoFiles()
        let telemetry = RecordingTelemetry()
        let invalidations = SharedSeamsInvalidationCounter()
        let coordinator = SyncCoordinator(
            accounts: SyncAccountStore(keychain: countingKeychain),
            lastBackup: LastBackupPreference(preferences: storedPreferences),
            photos: files,
            resolver: nil,
            makeClient: worker.clientFactory,
            telemetry: TelemetryReporter(sink: telemetry),
            now: { now }
        )
        self.keychain = countingKeychain
        self.preferences = storedPreferences
        self.gate = gate
        self.worker = worker
        self.files = files
        self.telemetry = telemetry
        self.invalidations = invalidations
        self.coordinator = coordinator
        model = SyncModel(
            config: AppConfig(syncEndpoint: endpoint),
            coordinator: coordinator,
            invalidator: invalidations,
            waitForProtectedData: { await gate.wait() },
            telemetry: TelemetryReporter(sink: telemetry)
        )
    }

    /// Starts the model with the database open, and lets every pass it starts finish.
    func startReady() async {
        await model.start()
        model.databaseReady(store)
        await model.waitForBackgroundWork()
    }

    /// Adds an unsynced photo row whose file exists.
    func addPendingPhoto(_ id: String) async throws {
        let uri = "file:///documents/item-photos/\(id).webp"
        files.set(Data([1, 2, 3]), at: uri)
        try await store.queue.write { db in
            let itemId = try String.fetchOne(db, sql: "SELECT id FROM items LIMIT 1") ?? ""
            try db.execute(
                sql: "INSERT INTO item_photos (id, item_id, uri, thumb_uri, byte_size, created_at) VALUES (?, ?, ?, NULL, 3, 1)",
                arguments: [id, itemId, uri])
        }
    }

    func itemCount() async throws -> Int {
        try await store.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items") ?? 0 }
    }
}

/// A lowercase UUID-shaped photo id.
func syncModelPhotoId(_ n: Int) -> String {
    String(format: "bbbbbbbb-0000-4000-8000-%012d", n)
}
