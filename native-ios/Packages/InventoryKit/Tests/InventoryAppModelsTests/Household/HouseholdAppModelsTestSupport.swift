import CoreGraphics
import Foundation
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage
import InventoryTestSupport
import Synchronization
import Testing
@testable import InventoryAppModels

// Shared by the household model tests. Names carry the Household prefix so they never meet
// another model's helpers in this target.

/// A session as the Expo build stored it (64-hex token, the server's origin).
let householdModelSession = HouseholdSession(
    origin: "https://inventory.wystudio.be",
    token: String(repeating: "ab", count: 32),
    deviceId: "11111111-2222-4333-8444-555555555555",
    deviceName: "Kitchen iPhone",
    householdName: "Home"
)

/// URLSession over a stub server, holding the server alive for as long as a client uses it.
struct HouseholdModelStubTransport: HTTPTransport {
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
    /// A household client over this server, aimed at the build's origin without a token.
    func householdModelClient(origin: String = "https://inventory.wystudio.be", hub: ReachabilityHub? = nil) -> HouseholdClient {
        HouseholdClient(
            origin: origin,
            token: nil,
            transport: HouseholdModelStubTransport(self),
            reachability: hub,
            telemetry: NetworkTelemetry(event: { _, _ in }, error: { _, _ in })
        )
    }

    /// Requests whose path starts with `prefix`.
    func householdRequests(to prefix: String) -> [RecordedRequest] {
        requests.filter { $0.path.hasPrefix(prefix) }
    }
}

/// Photo files as a URI-to-bytes map (the image store's fake).
final class HouseholdModelFakePhotos: PhotoStoring {
    private let files: Mutex<[String: Data]>

    init(_ files: [String: Data] = [:]) {
        self.files = Mutex(files)
    }

    func storeItemPhoto(_ source: ImageSource, cropToAspect aspect: CGSize?) async throws -> StoredImage {
        throw ImageStoreError.couldNotProcess
    }

    func writeStoredPhoto(photoId: String, bytes: Data) async throws -> StoredImage {
        throw ImageStoreError.couldNotProcess
    }

    func readStoredPhoto(_ uri: String) async -> Data? {
        files.withLock { $0[uri] }
    }

    func deleteStoredPhotos(_ uris: [String?]) {}

    func hasRoomForPhoto(estimatedBytes: Int64) -> Bool { true }
}

/// Protected data that a test makes available when it wants (`UIApplication.isProtectedDataAvailable`).
@MainActor
final class HouseholdTestProtectedData {
    private(set) var available: Bool
    /// The next `isAvailable` check finds the device locked again.
    var lockOnNextCheck = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(available: Bool = true) {
        self.available = available
    }

    var waiterCount: Int { waiters.count }

    var gate: HouseholdModel.ProtectedDataGate {
        HouseholdModel.ProtectedDataGate(
            isAvailable: { [self] in
                if lockOnNextCheck {
                    lockOnNextCheck = false
                    available = false
                }
                return available
            },
            waitUntilAvailable: { [self] in await waitUntilAvailable() }
        )
    }

    private func waitUntilAvailable() async {
        guard !available else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// `protectedDataDidBecomeAvailableNotification`.
    func makeAvailable() {
        available = true
        let resumed = waiters
        waiters = []
        for waiter in resumed { waiter.resume() }
    }
}

/// A household model over an in-memory keychain and a stub home server.
@MainActor
struct HouseholdModelFixture {
    let server: StubServer
    let keychain: InMemoryKeychain
    let protectedData: HouseholdTestProtectedData
    let household: HouseholdModel
    let directory: TemporaryDirectory

    init(
        keychain: InMemoryKeychain = InMemoryKeychain(),
        protectedData: HouseholdTestProtectedData = HouseholdTestProtectedData(),
        hub: ReachabilityHub? = nil,
        _ handler: @escaping StubServer.Handler = { _ in .json(404, #"{"error":"not_found"}"#) }
    ) throws {
        server = StubServer(handler)
        self.keychain = keychain
        self.protectedData = protectedData
        directory = try TemporaryDirectory()
        household = HouseholdModel(
            store: HouseholdSessionStore(keychain: keychain),
            client: server.householdModelClient(hub: hub),
            photos: HouseholdModelFakePhotos(),
            photoCache: HouseholdPhotoCache(resolver: PhotoPathResolver(documents: directory.documents, caches: directory.caches)),
            protectedData: protectedData.gate
        )
    }

    /// The keychain item as it is stored now.
    var storedSession: String? { keychain.values[KeychainKey.householdSession] }
}

/// A fresh in-memory database migrated to v7, with the local repositories over it.
func householdModelLocal() throws -> LocalRepositories {
    let store = try DatabaseStore.inMemory()
    try store.migrate()
    return LocalRepositories(store: store)
}

/// Lets main-actor tasks that were just scheduled run.
@MainActor
func householdSettle(_ rounds: Int = 20) async {
    for _ in 0..<rounds {
        await Task.yield()
    }
}

/// Waits (in real time) until `condition` holds, for effects that cross URLSession or streams.
@MainActor
func householdWaitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
