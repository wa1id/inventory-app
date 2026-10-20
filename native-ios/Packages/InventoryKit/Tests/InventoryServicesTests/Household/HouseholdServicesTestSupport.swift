import CoreGraphics
import Foundation
import GRDB
import InventoryCore
import InventoryNetwork
import InventoryStorage
import InventoryTestSupport
import Synchronization
import Testing
@testable import InventoryServices

// Shared by the household service tests. Names carry the Household prefix so they never meet
// another area's helpers in this target.

/// The RN tests' session (`origin: https://inventory.wystudio.be`, `token: tok`).
let householdTestSession = HouseholdSession(
    origin: "https://inventory.wystudio.be",
    token: "tok",
    deviceId: "d1",
    deviceName: "Phone",
    householdName: "Home"
)

/// URLSession over a stub server, holding the server alive for as long as a client uses it.
struct HouseholdStubTransport: HTTPTransport {
    let server: StubServer
    let inner: URLSessionTransport

    init(_ server: StubServer) {
        self.server = server
        inner = URLSessionTransport(session: server.session)
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await inner.send(request)
    }
}

extension StubServer {
    /// A household client over this server: the build's origin and no token unless given.
    func householdClient(
        origin: String = householdTestSession.origin,
        token: String? = nil,
        hub: ReachabilityHub? = nil,
        telemetry: RecordingTelemetry? = nil
    ) -> HouseholdClient {
        HouseholdClient(
            origin: origin,
            token: token,
            transport: HouseholdStubTransport(self),
            reachability: hub,
            telemetry: telemetry.map { recorder in
                NetworkTelemetry(
                    event: { recorder.event($0, Telemetry.redact($1)) },
                    error: { recorder.error($0, Telemetry.redact($1)) }
                )
            } ?? NetworkTelemetry(event: { _, _ in }, error: { _, _ in })
        )
    }

    /// Requests whose path starts with `prefix`.
    func requests(to prefix: String) -> [RecordedRequest] {
        requests.filter { $0.path.hasPrefix(prefix) }
    }
}

/// Photo files as a URI-to-bytes map, like RN's `readPhoto` test seam (the image store's fake).
final class HouseholdFakePhotos: PhotoStoring {
    private let files: Mutex<[String: Data]>
    private let reads = Mutex<[String]>([])

    init(_ files: [String: Data] = [:]) {
        self.files = Mutex(files)
    }

    /// Every URI read, in order.
    var readURIs: [String] { reads.withLock { $0 } }

    func storeItemPhoto(_ source: ImageSource, cropToAspect aspect: CGSize?) async throws -> StoredImage {
        throw ImageStoreError.couldNotProcess
    }

    func writeStoredPhoto(photoId: String, bytes: Data) async throws -> StoredImage {
        throw ImageStoreError.couldNotProcess
    }

    func readStoredPhoto(_ uri: String) async -> Data? {
        reads.withLock { $0.append(uri) }
        return files.withLock { $0[uri] }
    }

    func deleteStoredPhotos(_ uris: [String?]) {}

    func hasRoomForPhoto(estimatedBytes: Int64) -> Bool { true }
}

/// A fresh in-memory database migrated to v7, with the local repositories over it (RN
/// `initializeRepositories(openNodeDatabase())`).
func householdFreshLocal() throws -> LocalRepositories {
    let store = try DatabaseStore.inMemory()
    try store.migrate()
    return LocalRepositories(store: store)
}

/// Rows of a table, oldest first, as dictionaries of SQLite values.
func householdRows(_ store: DatabaseStore, _ table: String) throws -> [[String: DatabaseValue]] {
    try store.queue.read { db in
        try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map { row in
            Dictionary(uniqueKeysWithValues: row.columnNames.map { ($0, row[$0] as DatabaseValue) })
        }
    }
}

/// `SELECT COUNT(*)` of a table.
func householdCount(_ store: DatabaseStore, _ table: String, where condition: String = "1") throws -> Int {
    try store.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(condition)") ?? 0 }
}

/// JSON fixtures for the household service tests, in `Fixtures/household`.
enum HouseholdServicesFixtures {
    static func url(_ name: String) throws -> URL {
        let directory = try #require(Bundle.module.url(forResource: "household", withExtension: nil, subdirectory: "Fixtures"))
        return directory.appending(path: name, directoryHint: .notDirectory)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }
}

/// JSON text for an `ItemWithContext` answer, in the shape the home server sends.
func householdItemJSON(
    id: String,
    containerId: String = "c1",
    name: String = "Cable",
    photoId: String? = nil,
    photoUri: String? = nil,
    photoThumbUri: String? = nil,
    tags: [String] = [],
    spaceId: String = "s1",
    containerShortCode: String = "BOX-7K2M"
) -> String {
    func value(_ string: String?) -> String { string.map(JSONValue.quote) ?? "null" }
    let tagList = tags.map(JSONValue.quote).joined(separator: ",")
    return """
        {"id":\(JSONValue.quote(id)),"containerId":\(JSONValue.quote(containerId)),"name":\(JSONValue.quote(name)),\
        "category":null,"quantity":1,"notes":null,"createdAt":10,"updatedAt":10,\
        "photoId":\(value(photoId)),"photoUri":\(value(photoUri)),"photoThumbUri":\(value(photoThumbUri)),\
        "tags":[\(tagList)],"spaceId":\(JSONValue.quote(spaceId)),"spaceName":"Garage","spaceIcon":"🧰",\
        "spaceColor":"#7A9E7E","containerName":"Box","containerShortCode":\(JSONValue.quote(containerShortCode))}
        """
}

/// A photo answer from `PUT /v1/photos/:id` for the id in the request's path.
func householdUploadReply(_ request: RecordedRequest) -> StubReply {
    let photoId = request.path.components(separatedBy: "/v1/photos/").last ?? "p1"
    return .json(201, #"{"id":"\#(photoId)","uri":"r2:household/primary/photos/\#(photoId).webp","thumbUri":"r2:household/primary/photos/\#(photoId)-thumb.webp","width":10,"height":10,"byteSize":3}"#)
}

/// Waits (in real time) until `condition` holds, for effects that cross URLSession. It returns as
/// soon as the condition holds; the long limit is for a loaded Mac, where a request took over
/// 5 s to reach the stub (CONVENTIONS.md, "Time in tests").
func householdEventually(
    timeout: Duration = .seconds(60),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
