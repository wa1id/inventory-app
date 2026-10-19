import CoreGraphics
import Foundation
import InventoryCore
import InventoryNetwork
import InventoryStorage
import InventoryTestSupport
import Synchronization
import Testing
@testable import InventoryServices

/// Photos kept in memory: `storeItemPhoto` answers `stored://<n>` (a `PhotoStoring` for pipeline tests).
final class CapturePipelinePhotoStore: PhotoStoring {
    private let counter = Mutex(0)

    func storeItemPhoto(_ source: ImageSource, cropToAspect aspect: CGSize?) async throws -> StoredImage {
        let number = counter.withLock { value -> Int in
            value += 1
            return value
        }
        return StoredImage(uri: "stored://\(number)", thumbUri: "stored://\(number)-thumb", width: 10, height: 20, byteSize: 30)
    }

    func writeStoredPhoto(photoId: String, bytes: Data) async throws -> StoredImage {
        throw ImageStoreError.couldNotProcess
    }

    func readStoredPhoto(_ uri: String) async -> Data? { nil }
    func deleteStoredPhotos(_ uris: [String?]) {}
    func hasRoomForPhoto(estimatedBytes: Int64) -> Bool { true }
}

/// An items repository that only creates and updates, counting both.
final class CapturePipelineItems: ItemsRepository {
    private struct State {
        var created = 0
        var updated: [String] = []
    }

    private let state = Mutex(State())

    var createdCount: Int { state.withLock { $0.created } }
    var updatedIds: [String] { state.withLock { $0.updated } }

    func create(_ draft: ItemDraft) async throws -> Item {
        let number = state.withLock { state -> Int in
            state.created += 1
            return state.created
        }
        return Item(id: "item-\(number)", containerId: draft.containerId, name: "", category: nil, quantity: 1, notes: nil, createdAt: 1, updatedAt: 1)
    }

    func update(_ id: String, _ input: UpdateItemInput) async throws -> Item? {
        state.withLock { $0.updated.append(id) }
        return nil
    }

    func listByContainer(_ containerId: String) async throws -> [ItemWithContext] { [] }
    func listUnsorted() async throws -> [ItemWithContext] { [] }
    func listRecent(limit: Int) async throws -> [ItemWithContext] { [] }
    func countUnsorted() async throws -> Int { 0 }
    func getById(_ id: String) async throws -> ItemWithContext? { nil }
    func getPhotos(_ itemId: String) async throws -> [ItemPhoto] { [] }
    func delete(_ id: String) async throws -> DeletionResult { .notDeleted }
    func countAll() async throws -> Int { 0 }
}

/// A recogniser that holds every call until the test lets it go, counting how many are inside.
actor CapturePipelineRecognitionGate {
    private(set) var inside = 0
    private(set) var mostInside = 0
    private(set) var entered: [String] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func recognize(_ uri: String) async -> RecognitionResult {
        inside += 1
        mostInside = max(mostInside, inside)
        entered.append(uri)
        let ready = enteredWaiters.filter { $0.count <= entered.count }
        enteredWaiters.removeAll { $0.count <= entered.count }
        for waiter in ready { waiter.continuation.resume() }
        await withCheckedContinuation { held.append($0) }
        inside -= 1
        return .failed(.offline)
    }

    /// Waits until `count` calls have entered in total.
    func waitForEntered(_ count: Int) async {
        if entered.count >= count { return }
        await withCheckedContinuation { enteredWaiters.append((count, $0)) }
    }

    /// Lets the oldest held call finish.
    func releaseOne() {
        guard !held.isEmpty else { return }
        held.removeFirst().resume()
    }

    var heldCount: Int { held.count }
}

@Suite("FastCapturePipeline")
struct FastCapturePipelineTests {
    @Test("keeps at most two recognitions in flight, and lets the rest in as slots free up")
    func capsRecognitions() async throws {
        let gate = CapturePipelineRecognitionGate()
        let items = CapturePipelineItems()
        let pipeline = FastCapturePipeline(
            photos: CapturePipelinePhotoStore(),
            recognizer: { await gate.recognize($0) }
        )
        #expect(pipeline.maxConcurrentRecognitions == FastCapturePipeline.defaultMaxConcurrentRecognitions)
        #expect(pipeline.maxConcurrentRecognitions == 2)

        let shots = (0..<5).map { _ in
            Task { try await pipeline.capture(containerId: "c1", photo: .data(Data()), cropToAspect: nil, items: items) }
        }

        await gate.waitForEntered(2)
        // Every row is written before its recognition waits for a slot.
        for _ in 0..<200 where items.createdCount < 5 { await Task.yield() }
        #expect(items.createdCount == 5)
        for _ in 0..<50 { await Task.yield() }
        #expect(await gate.inside == 2)
        #expect(await pipeline.recognitionsInFlight == 2)

        for released in 1...5 {
            await gate.releaseOne()
            if released <= 3 { await gate.waitForEntered(2 + released) }
        }
        var outcomes: [FastCaptureOutcome] = []
        for shot in shots { outcomes.append(try await shot.value) }

        #expect(await gate.mostInside == 2)
        #expect(await gate.entered.count == 5)
        #expect(Set(outcomes.map(\.itemId)).count == 5)
        #expect(outcomes.allSatisfy { if case .unrecognized(_, .offline) = $0 { true } else { false } })
        #expect(await pipeline.recognitionsInFlight == 0)
    }

    @Test("a cap below one still lets recognitions through, one at a time")
    func capAtLeastOne() async throws {
        let gate = CapturePipelineRecognitionGate()
        let pipeline = FastCapturePipeline(photos: CapturePipelinePhotoStore(), recognizer: { await gate.recognize($0) }, maxConcurrentRecognitions: 0)
        #expect(pipeline.maxConcurrentRecognitions == 1)
        let items = CapturePipelineItems()
        let shot = Task { try await pipeline.capture(containerId: "c1", photo: .data(Data()), cropToAspect: nil, items: items) }
        await gate.waitForEntered(1)
        await gate.releaseOne()
        #expect(try await shot.value == .unrecognized(itemId: "item-1", reason: .offline))
    }

    @Test("stores a real photo, files an unnamed row in the drop zone, then names it from the suggestion")
    func endToEndLocal() async throws {
        let container = try PhotoContainer()
        let telemetry = RecordingTelemetry()
        let photos = container.store(telemetry: telemetry)
        let store = try DatabaseStore.inMemory()
        try await store.migrate()
        let repos = LocalRepositories(store: store)
        let seenUnnamed = Mutex<[String]>([])

        let pipeline = FastCapturePipeline(photos: photos, recognizer: { uri in
            // The row is already there, unnamed, while recognition runs.
            let rows = (try? await repos.items.listUnsorted()) ?? []
            seenUnnamed.withLock { $0 = rows.map(\.name) }
            #expect(container.resolver.resolve(uri) != nil)
            return .success(RecognitionSuggestion(name: "Cordless drill", category: "Tools", tags: ["dewalt"], confidence: 0.9), contractVersion: 1)
        })

        let jpeg = try TestImages.jpeg(TestImages.marked(width: 3024, height: 4032))
        let outcome = try await pipeline.capture(
            containerId: DropZone.containerId,
            photo: .data(jpeg),
            cropToAspect: CGSize(width: 393, height: 852),
            items: repos.items
        )

        guard case .recognized(let itemId, let name) = outcome else {
            Issue.record("expected a recognized outcome, got \(outcome)")
            return
        }
        #expect(name == "Cordless drill")
        #expect(seenUnnamed.withLock { $0 } == [""])

        let row = try #require(try await repos.items.getById(itemId))
        #expect(row.containerId == DropZone.containerId)
        #expect(row.name == "Cordless drill")
        #expect(row.category == "Tools")
        #expect(row.tags == ["dewalt"])
        let photosOfItem = try await repos.items.getPhotos(itemId)
        let photo = try #require(photosOfItem.first)
        #expect(photosOfItem.count == 1)
        // Cropped to the preview's aspect, then scaled to fit 1400 (DECISIONS U7).
        #expect(photo.height == 1400)
        #expect(abs((photo.width ?? 0) - 646) <= 1)
        #expect(container.resolver.resolve(photo.uri) != nil)
        #expect(container.resolver.resolve(photo.thumbUri) != nil)
        #expect(telemetry.names == ["photo_stored"])
    }

    @Test("the production recogniser reads the stored photo from the current container, never hinted")
    func recognizerResolvesStalePaths() async throws {
        let container = try PhotoContainer()
        try FileManager.default.createDirectory(at: container.photoDirectory, withIntermediateDirectories: true)
        let bytes = Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)
        try bytes.write(to: container.photoDirectory.appending(path: "x.webp"))

        let reads = Mutex<[URL]>([])
        let bodies = Mutex<[Data]>([])
        let client = RecognitionClient(
            endpoint: "https://recognition.example/api/recognize",
            key: nil,
            transport: CapturePipelineTransport { request in
                bodies.withLock { $0.append(request.httpBody ?? Data()) }
                return HTTPResponse(status: 200, body: Data(#"{"contractVersion":1,"status":"unrecognized"}"#.utf8))
            },
            readImage: { url in
                reads.withLock { $0.append(url) }
                return try Data(contentsOf: url)
            },
            telemetry: NetworkTelemetry(event: { _, _ in }, error: { _, _ in })
        )
        let recognize = FastCapturePipeline.recognizer(client: client, resolver: container.resolver)

        let stale = "file:///var/mobile/Containers/Data/Application/0000-OLD/Documents/item-photos/x.webp"
        #expect(await recognize(stale) == .failed(.unrecognized))
        #expect(reads.withLock { $0 } == [container.photoDirectory.appending(path: "x.webp")])
        let body = try #require(bodies.withLock { $0.first })
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["nameHint"] == nil)
        #expect((json["image"] as? [String: Any])?["mediaType"] as? String == "image/webp")
    }

    @Test("a stored photo that cannot be found reads as server_error, without a request")
    func recognizerMissingFile() async throws {
        let container = try PhotoContainer()
        let client = RecognitionClient(
            endpoint: "https://recognition.example/api/recognize",
            key: nil,
            transport: CapturePipelineTransport { _ in
                Issue.record("no request should be sent")
                return HTTPResponse(status: 500)
            },
            telemetry: NetworkTelemetry(event: { _, _ in }, error: { _, _ in })
        )
        let recognize = FastCapturePipeline.recognizer(client: client, resolver: container.resolver)
        #expect(await recognize(container.resolver.storedURI(forPhotoNamed: "gone.webp")) == .failed(.serverError))
    }
}

/// An `HTTPTransport` that answers from a closure.
struct CapturePipelineTransport: HTTPTransport {
    let respond: @Sendable (URLRequest) async throws -> HTTPResponse

    init(_ respond: @escaping @Sendable (URLRequest) async throws -> HTTPResponse) {
        self.respond = respond
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await respond(request)
    }
}
