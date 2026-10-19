import CoreGraphics
import Foundation
import InventoryAppModels
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryTestSupport
import Synchronization
import Testing

/// Holds async calls until the test answers them, oldest first.
actor CaptureTestLatch<Value: Sendable> {
    private var held: [CheckedContinuation<Value, Never>] = []
    private var arrivals = 0
    private var arrivalWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Suspends until ``release(_:)`` answers this call.
    func hold() async -> Value {
        await withCheckedContinuation { continuation in
            held.append(continuation)
            arrivals += 1
            let ready = arrivalWaiters.filter { $0.count <= arrivals }
            arrivalWaiters.removeAll { $0.count <= arrivals }
            for waiter in ready { waiter.continuation.resume() }
        }
    }

    /// Waits until `count` calls have arrived in total.
    func waitForArrivals(_ count: Int) async {
        if arrivals >= count { return }
        await withCheckedContinuation { arrivalWaiters.append((count, $0)) }
    }

    /// Answers the oldest held call.
    func release(_ value: Value) {
        guard !held.isEmpty else {
            Issue.record("CaptureTestLatch: nothing to release")
            return
        }
        held.removeFirst().resume(returning: value)
    }

    var heldCount: Int { held.count }
}

struct CaptureTestError: Error, Equatable {
    var name = "boom"
}

/// A `PhotoStoring` for camera tests: room on demand, stores answered at once or held, deletes
/// recorded.
final class CaptureTestPhotos: PhotoStoring {
    struct Store: Sendable {
        let data: Data?
        let crop: CGSize?
        let isFile: Bool
    }

    private struct State {
        var hasRoom = true
        var stores: [Store] = []
        var deleted: [[String?]] = []
        var result: Result<StoredImage, CaptureTestError> = .success(CaptureTestPhotos.stored)
    }

    static let stored = StoredImage(uri: "file:///docs/item-photos/p.webp", thumbUri: "file:///docs/item-photos/p-thumb.webp", width: 646, height: 1400, byteSize: 52_000)

    private let state = Mutex(State())
    /// When set, every store waits for the test to answer it.
    let latch: CaptureTestLatch<Result<StoredImage, CaptureTestError>>?

    init(holdStores: Bool = false) {
        latch = holdStores ? CaptureTestLatch() : nil
    }

    var hasRoom: Bool {
        get { state.withLock { $0.hasRoom } }
        set { state.withLock { $0.hasRoom = newValue } }
    }

    var result: Result<StoredImage, CaptureTestError> {
        get { state.withLock { $0.result } }
        set { state.withLock { $0.result = newValue } }
    }

    var stores: [Store] { state.withLock { $0.stores } }
    var deleted: [[String?]] { state.withLock { $0.deleted } }

    func storeItemPhoto(_ source: ImageSource, cropToAspect aspect: CGSize?) async throws -> StoredImage {
        let entry: Store = switch source {
        case .data(let data): Store(data: data, crop: aspect, isFile: false)
        case .file: Store(data: nil, crop: aspect, isFile: true)
        case .image: Store(data: nil, crop: aspect, isFile: false)
        }
        state.withLock { $0.stores.append(entry) }
        if let latch {
            return try await latch.hold().get()
        }
        return try result.get()
    }

    func writeStoredPhoto(photoId: String, bytes: Data) async throws -> StoredImage {
        throw CaptureTestError(name: "unused")
    }

    func readStoredPhoto(_ uri: String) async -> Data? { nil }

    func deleteStoredPhotos(_ uris: [String?]) {
        state.withLock { $0.deleted.append(uris) }
    }

    func hasRoomForPhoto(estimatedBytes: Int64) -> Bool {
        state.withLock { $0.hasRoom }
    }
}

/// A `FastCapturing` whose pipelines wait for the test to finish them.
actor CaptureTestPipeline: FastCapturing {
    struct Call: Sendable {
        let containerId: String
        let data: Data?
        let crop: CGSize?
    }

    private(set) var calls: [Call] = []
    let latch = CaptureTestLatch<Result<FastCaptureOutcome, CaptureTestError>>()

    func capture(
        containerId: String,
        photo: ImageSource,
        cropToAspect: CGSize?,
        items: any ItemsRepository
    ) async throws -> FastCaptureOutcome {
        let data: Data? = if case .data(let bytes) = photo { bytes } else { nil }
        calls.append(Call(containerId: containerId, data: data, crop: cropToAspect))
        return try await latch.hold().get()
    }

    /// Finishes the oldest running pipeline.
    func finish(_ result: Result<FastCaptureOutcome, CaptureTestError>) async {
        await latch.release(result)
    }
}

/// An items repository for the camera and review tests: scripted reads and deletes.
final class CaptureTestItems: ItemsRepository {
    private struct State {
        var rows: [ItemWithContext] = []
        var readError: (any Error)?
        var listCalls: [String] = []
        var deleted: [String] = []
        var deleteResult: Result<DeletionResult, any Error> = .success(DeletionResult(deleted: true, orphanedPhotoUris: []))
    }

    private let state = Mutex(State())
    /// When set, every `listByContainer` waits for the test to let it through.
    let readLatch: CaptureTestLatch<Void>?

    init(holdReads: Bool = false) {
        readLatch = holdReads ? CaptureTestLatch() : nil
    }

    /// What `listByContainer` answers (newest first, as the repository does).
    var rows: [ItemWithContext] {
        get { state.withLock { $0.rows } }
        set { state.withLock { $0.rows = newValue } }
    }

    var readError: (any Error)? {
        get { state.withLock { $0.readError } }
        set { state.withLock { $0.readError = newValue } }
    }

    var deleteResult: Result<DeletionResult, any Error> {
        get { state.withLock { $0.deleteResult } }
        set { state.withLock { $0.deleteResult = newValue } }
    }

    var listCalls: [String] { state.withLock { $0.listCalls } }
    var deleted: [String] { state.withLock { $0.deleted } }

    func listByContainer(_ containerId: String) async throws -> [ItemWithContext] {
        state.withLock { $0.listCalls.append(containerId) }
        let snapshot = state.withLock { ($0.rows, $0.readError) }
        if let readLatch { await readLatch.hold() }
        if let error = snapshot.1 { throw error }
        return snapshot.0
    }

    func delete(_ id: String) async throws -> DeletionResult {
        state.withLock { $0.deleted.append(id) }
        return try state.withLock { $0.deleteResult }.get()
    }

    func create(_ draft: ItemDraft) async throws -> Item { throw CaptureTestError(name: "unused") }
    func update(_ id: String, _ input: UpdateItemInput) async throws -> Item? { nil }
    func listUnsorted() async throws -> [ItemWithContext] { [] }
    func listRecent(limit: Int) async throws -> [ItemWithContext] { [] }
    func countUnsorted() async throws -> Int { 0 }
    func getById(_ id: String) async throws -> ItemWithContext? { nil }
    func getPhotos(_ itemId: String) async throws -> [ItemPhoto] { [] }
    func countAll() async throws -> Int { 0 }
}

/// A confirmation that waits for the test to answer it.
@MainActor
final class CaptureTestHeldConfirm: ConfirmPresenting {
    let latch = CaptureTestLatch<Bool>()
    private(set) var asked: [ConfirmOptions] = []

    func confirm(_ options: ConfirmOptions) async -> Bool {
        asked.append(options)
        return await latch.hold()
    }
}

/// Records where a model navigated, oldest first.
@MainActor
final class CaptureTestNavigation<Destination: Sendable> {
    private(set) var destinations: [Destination] = []

    var navigate: @MainActor @Sendable (Destination) -> Void {
        { [self] destination in destinations.append(destination) }
    }
}

/// The camera permission as a test sets it.
@MainActor
final class CaptureTestAuthorization {
    var status: CameraAuthorization
    var answer: Bool
    private(set) var requests = 0

    init(_ status: CameraAuthorization = .authorized, answer: Bool = true) {
        self.status = status
        self.answer = answer
    }

    func model(_ purpose: CameraPermissionPurpose, telemetry: RecordingTelemetry = RecordingTelemetry()) -> CameraPermissionModel {
        CameraPermissionModel(
            purpose: purpose,
            readAuthorization: { [self] in status },
            requestAccess: { [self] in await ask() },
            telemetry: TelemetryReporter(sink: telemetry)
        )
    }

    private func ask() -> Bool {
        requests += 1
        status = answer ? .authorized : .denied
        return answer
    }
}

/// Item rows for the review tests.
enum CaptureTestRows {
    static func row(
        _ id: String,
        name: String = "",
        createdAt: Int64 = 1,
        updatedAt: Int64? = nil,
        containerId: String = "c1",
        containerName: String? = "Tool chest",
        shortCode: String = "CAB-J92R"
    ) -> ItemWithContext {
        ItemWithContext(
            item: Item(
                id: id,
                containerId: containerId,
                name: name,
                category: nil,
                quantity: 1,
                notes: nil,
                createdAt: createdAt,
                updatedAt: updatedAt ?? createdAt
            ),
            photoId: nil,
            photoUri: nil,
            photoThumbUri: nil,
            tags: [],
            spaceId: "s1",
            spaceName: "Garage",
            spaceIcon: "🚗",
            spaceColor: "#5B8DEF",
            containerName: containerName,
            containerShortCode: shortCode
        )
    }

    /// A drop-zone row, as the repository reads it.
    static func dropZone(_ id: String, name: String = "", createdAt: Int64 = 1, updatedAt: Int64? = nil) -> ItemWithContext {
        row(id, name: name, createdAt: createdAt, updatedAt: updatedAt, containerId: DropZone.containerId, containerName: "Drop zone", shortCode: "DROP-ZONE")
    }
}

/// Lets queued main-actor work and freshly woken tasks run.
func captureTestSettle() async {
    for _ in 0..<20 {
        await Task.yield()
    }
}

/// Yields until `condition` holds, recording an issue when it never does.
@MainActor
func captureTestEventually(
    _ condition: @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0..<2000 {
        if condition() { return }
        await Task.yield()
    }
    if !condition() {
        Issue.record("condition never became true", sourceLocation: sourceLocation)
    }
}
