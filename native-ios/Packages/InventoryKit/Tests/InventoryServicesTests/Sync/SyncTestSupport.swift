import Foundation
import GRDB
import InventoryCore
import InventoryNetwork
import InventoryStorage
import InventoryTestSupport
import Synchronization
import Testing
@testable import InventoryServices

// Doubles for the sync tests. Every name carries the Sync prefix so they never collide with
// another area's helpers in this target.

let syncTestEndpoint = "https://sync.example"

// MARK: - Fake Worker

/// An in-process stand-in for the sync Worker (worker/src/index.ts), reached through a real
/// `SyncClient` over ``StubServer``: photos, backups, listing, the Worker's own refusals (400 for
/// an empty body or a non-UUID id, 413 over 4 MiB), per-route failures, and holds that park a
/// request until the test releases it.
///
/// The shape follows the fake clients of RN's `backup.test.ts` (uploads get `capturedAt = 1000 × n`)
/// and `photoSync.test.ts` (`remote`, `uploads`, `deletes`, `downloads`).
final class SyncFakeWorker: Sendable {
    enum Failure: Sendable {
        case status(Int)
        case offline

        var reply: StubReply {
            switch self {
            case .status(let code): .json(code, #"{"error":"Failed."}"#)
            case .offline: .failure(.notConnectedToInternet, delay: nil)
            }
        }
    }

    struct StoredBackup: Sendable {
        let bytes: Data
        let schemaVersion: String?
        let checksum: String?
        let capturedAt: Int64
    }

    struct State: Sendable {
        var photos: [String: Data] = [:]
        var backups: [StoredBackup] = []
        var uploads: [String] = []
        var deletes: [String] = []
        var downloads: [String] = []
        var backupListings = 0
        var failUploads: Failure?
        var failDeletes: Failure?
        var failDownloads: Failure?
        var failBackupUploads: Failure?
        var failBackupDownloads: Failure?
        var failBackupList: Failure?
        /// Replaces the stored schema header on `GET /v1/backups/latest`; `.some(nil)` omits it.
        var servedSchemaHeader: String??
        /// Replaces the stored bytes on `GET /v1/backups/latest`.
        var servedBackupBody: Data?
        /// Replaces the answer to `GET /v1/photos/{id}` for these ids.
        var photoReplies: [String: StubReply] = [:]
        /// Replaces the answer to `PUT /v1/photos/{id}` for these ids.
        var photoUploadReplies: [String: StubReply] = [:]
    }

    private final class Box: Sendable {
        let state = Mutex(State())
        let holds = Mutex<[(method: String, path: String, hold: SyncRequestHold)]>([])

        func handle(_ request: RecordedRequest) async -> StubReply {
            let hold = holds.withLock { holds -> SyncRequestHold? in
                guard let index = holds.firstIndex(where: { $0.method == request.method && request.path.hasPrefix($0.path) })
                else { return nil }
                return holds.remove(at: index).hold
            }
            if let hold { await hold.arriveAndWait() }
            return state.withLock { route(request, &$0) }
        }

        private func route(_ request: RecordedRequest, _ s: inout State) -> StubReply {
            let path = request.path
            let photoPrefix = "/v1/photos/"
            if path.hasPrefix(photoPrefix) {
                let id = String(path.dropFirst(photoPrefix.count))
                switch request.method {
                case "PUT":
                    if let failure = s.failUploads { return failure.reply }
                    if let reply = s.photoUploadReplies[id] { return reply }
                    guard SyncWorkerRules.isPhotoId(id) else { return .json(400, #"{"error":"Invalid photo id."}"#) }
                    guard !request.body.isEmpty else { return .json(400, #"{"error":"Empty upload."}"#) }
                    guard request.body.count <= SyncLimits.maxPhotoBytes else {
                        return .json(413, #"{"error":"Upload is too large."}"#)
                    }
                    s.uploads.append(id)
                    s.photos[id] = request.body
                    return .json(201, #"{"id":"\#(id)","size":\#(request.body.count)}"#)
                case "GET":
                    s.downloads.append(id)
                    if let failure = s.failDownloads { return failure.reply }
                    if let reply = s.photoReplies[id] { return reply }
                    guard let bytes = s.photos[id] else { return .json(404, #"{"error":"Not found."}"#) }
                    return .bytes(200, bytes, headers: ["Content-Type": "image/jpeg"])
                case "DELETE":
                    if let failure = s.failDeletes { return failure.reply }
                    s.deletes.append(id)
                    s.photos[id] = nil
                    return .status(204)
                default:
                    return .json(405, #"{"error":"Method not allowed."}"#)
                }
            }
            switch (request.method, path) {
            case ("PUT", "/v1/backups"):
                if let failure = s.failBackupUploads { return failure.reply }
                let capturedAt = Int64(1000 * (s.backups.count + 1))
                let schema = request.header("x-snapshot-schema-version")
                s.backups.append(StoredBackup(
                    bytes: request.body, schemaVersion: schema,
                    checksum: request.header("x-snapshot-sha256"), capturedAt: capturedAt))
                return .json(201, #"{"id":"\#(s.backups.count)","size":\#(request.body.count),"capturedAt":\#(capturedAt),"schemaVersion":\#(Int(schema ?? "0") ?? 0)}"#)
            case ("GET", "/v1/backups"):
                s.backupListings += 1
                if let failure = s.failBackupList { return failure.reply }
                let items = s.backups.reversed().map { backup in
                    #"{"id":"\#(backup.capturedAt)","size":\#(backup.bytes.count),"capturedAt":\#(backup.capturedAt),"schemaVersion":\#(Int(backup.schemaVersion ?? "0") ?? 0)}"#
                }
                return .json(200, #"{"contractVersion":1,"backups":[\#(items.joined(separator: ","))]}"#)
            case ("GET", "/v1/backups/latest"):
                if let failure = s.failBackupDownloads { return failure.reply }
                guard let newest = s.backups.last else { return .json(404, #"{"error":"No backups yet."}"#) }
                var headers = ["Content-Type": "application/vnd.sqlite3"]
                let header = s.servedSchemaHeader ?? newest.schemaVersion
                if let header { headers["x-snapshot-schema-version"] = header }
                return .bytes(200, s.servedBackupBody ?? newest.bytes, headers: headers)
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

    /// A Worker client for `code` over this fake.
    func client(code: String = SyncFakeWorker.defaultCode) -> SyncClient {
        SyncClient(
            recoveryCode: code, endpoint: syncTestEndpoint, key: nil, timeout: .seconds(20),
            transport: SyncStubTransport(server: server), telemetry: telemetry.syncNetworkTelemetry
        )
    }

    /// The factory a ``SyncCoordinator`` takes.
    var clientFactory: SyncCoordinator.ClientFactory {
        { [self] code in client(code: code) }
    }

    /// 16 × 0x42 encoded (identity.test.ts vectors).
    static let defaultCode = "89144GJ289144GJ289144GJ288"

    var state: State { box.state.withLock { $0 } }

    func update(_ change: (inout State) -> Void) {
        box.state.withLock { change(&$0) }
    }

    /// Parks the next `method` request whose path starts with `path` until the hold is released.
    @discardableResult
    func hold(_ method: String, _ path: String) -> SyncRequestHold {
        let hold = SyncRequestHold()
        box.holds.withLock { $0.append((method, path, hold)) }
        return hold
    }

    /// Every request received, as `METHOD /path`.
    var requestLines: [String] { server.requests.map { "\($0.method) \($0.path)" } }
}

/// ``URLSessionTransport`` that keeps its stub server alive for as long as a client holds it.
struct SyncStubTransport: HTTPTransport {
    let server: StubServer

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await URLSessionTransport(session: server.session).send(request)
    }
}

/// A request parked inside the fake Worker until the test lets it go, for ordering races.
final class SyncRequestHold: Sendable {
    private struct State {
        var arrived = false
        var released = false
        /// A waiting test was cancelled (its time limit ran out): stop waiting for arrivals.
        var abandoned = false
        var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
        var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// Called by the Worker: marks the request as arrived, then waits for ``release()``.
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

    /// Returns once the parked request has reached the Worker, or once the waiting test is
    /// cancelled, so a suite's time limit ends a test whose request never comes.
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

    /// Lets the parked request (and any later one on this hold) through.
    func release() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.released = true
            defer { state.releaseWaiters = [] }
            return state.releaseWaiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

extension RecordingTelemetry {
    /// The clients' telemetry seam, redacting as `NetworkTelemetry.standard` does.
    var syncNetworkTelemetry: NetworkTelemetry {
        NetworkTelemetry(
            event: { [self] name, payload in event(name, Telemetry.redact(payload)) },
            error: { [self] name, payload in error(name, Telemetry.redact(payload)) }
        )
    }

    /// The service seam: same redaction.
    var syncReporter: TelemetryReporter { TelemetryReporter(sink: self) }
}

// MARK: - Fake photo files

/// The image store faked as a URI-to-bytes map, as RN's `photoSync.test.ts` mocks
/// `src/services/capture/imageStore`. `writeStoredPhoto` writes
/// `file:///documents/item-photos/<id>.webp` and `-thumb.webp`.
final class SyncFakePhotoStore: PhotoStoring {
    private let storage = Mutex<[String: Data]>([:])
    private let failingWrites = Mutex<Set<String>>([])

    static func uri(_ photoId: String) -> String { "file:///documents/item-photos/\(photoId).webp" }
    static func thumbUri(_ photoId: String) -> String { "file:///documents/item-photos/\(photoId)-thumb.webp" }

    var files: [String: Data] { storage.withLock { $0 } }

    func set(_ data: Data?, at uri: String) {
        storage.withLock { $0[uri] = data }
    }

    func removeAll() {
        storage.withLock { $0.removeAll() }
    }

    /// Makes `writeStoredPhoto` throw for this id, as a decode failure would (03 B3).
    func failWrites(for photoId: String) {
        _ = failingWrites.withLock { $0.insert(photoId) }
    }

    func storeItemPhoto(_ source: ImageSource, cropToAspect aspect: CGSize?) async throws -> StoredImage {
        throw ImageStoreError.couldNotProcess
    }

    func writeStoredPhoto(photoId: String, bytes: Data) async throws -> StoredImage {
        if failingWrites.withLock({ $0.contains(photoId) }) { throw ImageStoreError.undecodable }
        let uri = Self.uri(photoId)
        let thumbUri = Self.thumbUri(photoId)
        storage.withLock {
            $0[uri] = bytes
            // The real one re-derives the thumbnail from the downloaded bytes.
            $0[thumbUri] = bytes.prefix(1)
        }
        return StoredImage(uri: uri, thumbUri: thumbUri, width: 0, height: 0, byteSize: bytes.count)
    }

    func readStoredPhoto(_ uri: String) async -> Data? {
        storage.withLock { $0[uri] }
    }

    func deleteStoredPhotos(_ uris: [String?]) {
        storage.withLock { files in
            for uri in uris {
                if let uri { files[uri] = nil }
            }
        }
    }

    func hasRoomForPhoto(estimatedBytes: Int64) -> Bool { true }
}

// MARK: - Inventory database

/// A migrated temporary database with RN's seed: a Garage space, a box and one item.
struct SyncTestInventory {
    let store: DatabaseStore
    let repos: LocalRepositories
    let itemId: String

    /// RN `seededDb()` (backup.test.ts) and `seed()` (photoSync.test.ts).
    static func seeded(itemName: String = "Drill") async throws -> SyncTestInventory {
        let store = try DatabaseStore.temporary()
        let repos = try await LocalRepositories.initialize(store)
        let space = try await repos.spaces.create(CreateSpaceInput(name: "Garage", icon: "car", color: "#5B8DEF"))
        let container = try await repos.containers.create(CreateContainerInput(spaceId: space.id, visualType: .box))
        let item = try await repos.items.create(ItemDraft(containerId: container.id, name: itemName, quantity: 1))
        return SyncTestInventory(store: store, repos: repos, itemId: item.id)
    }

    /// A freshly migrated database with only the seeded drop zone (a reinstall, 03 B12).
    static func empty() async throws -> DatabaseStore {
        let store = try DatabaseStore.temporary()
        _ = try await LocalRepositories.initialize(store)
        return store
    }

    /// RN `addPhoto`: a photo row whose files exist in `files` (3 bytes and a 1-byte thumbnail).
    @discardableResult
    func addPhoto(
        _ photoId: String,
        synced: Bool = false,
        files: SyncFakePhotoStore? = nil,
        bytes: Data = Data([1, 2, 3]),
        uri: String? = nil,
        createdAt: Int64 = epochMillis()
    ) async throws -> (uri: String, thumbUri: String) {
        let uri = uri ?? SyncFakePhotoStore.uri(photoId)
        let thumbUri = SyncFakePhotoStore.thumbUri(photoId)
        files?.set(bytes, at: uri)
        files?.set(Data([1]), at: thumbUri)
        let syncedAt: Int64? = synced ? epochMillis() : nil
        try await store.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO item_photos (id, item_id, uri, thumb_uri, byte_size, created_at, remote_synced_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [photoId, itemId, uri, thumbUri, bytes.count, createdAt, syncedAt])
        }
        return (uri, thumbUri)
    }

    /// One `item_photos` row's file columns.
    struct PhotoColumns: Sendable, Equatable {
        let uri: String
        let thumbUri: String?
        let byteSize: Int?
    }

    func photoColumns(_ photoId: String) async throws -> PhotoColumns? {
        try await store.queue.read { db in
            try Row.fetchOne(db, sql: "SELECT uri, thumb_uri, byte_size FROM item_photos WHERE id = ?", arguments: [photoId])
                .map { row in PhotoColumns(uri: row["uri"], thumbUri: row["thumb_uri"], byteSize: row["byte_size"]) }
        }
    }

    func strings(_ sql: String) async throws -> [String] {
        try await store.queue.read { db in try String.fetchAll(db, sql: sql) }
    }

    func count(_ table: String) async throws -> Int {
        try await store.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }
}

/// A lowercase v4-shaped photo id, as RN `newId()` makes them: `aaaaaaaa-0000-4000-8000-00000000000n`.
func syncPhotoId(_ n: Int) -> String {
    String(format: "aaaaaaaa-0000-4000-8000-%012d", n)
}
