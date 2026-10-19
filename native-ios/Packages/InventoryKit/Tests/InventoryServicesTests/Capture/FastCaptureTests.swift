import CoreGraphics
import Foundation
import InventoryCore
import InventoryNetwork
import Synchronization
import Testing
@testable import InventoryServices

/// What the fake dependencies were asked to do (RN `makeDeps`'s `calls`), in order.
final class FastCaptureCalls: Sendable {
    struct State {
        var order: [String] = []
        var stored: [Data] = []
        var crops: [CGSize?] = []
        var created: [ItemDraft] = []
        var updated: [(id: String, input: UpdateItemInput)] = []
        var recognized: [String] = []
    }

    let state = Mutex(State())

    var order: [String] { state.withLock { $0.order } }
    var stored: [Data] { state.withLock { $0.stored } }
    var crops: [CGSize?] { state.withLock { $0.crops } }
    var created: [ItemDraft] { state.withLock { $0.created } }
    var updated: [(id: String, input: UpdateItemInput)] { state.withLock { $0.updated } }
    var recognized: [String] { state.withLock { $0.recognized } }
}

/// RN `makeDeps`: a store that echoes the URI with `stored://`, a create that answers `item-1`,
/// an update that records, and the given recognition.
enum FastCaptureFakes {
    static let createdAt: Int64 = 1_700_000_000_000

    static func dependencies(
        _ calls: FastCaptureCalls,
        storePhoto: (@Sendable (ImageSource, CGSize?) async throws -> StoredImage)? = nil,
        recognize: @escaping @Sendable (String) async throws -> RecognitionResult
    ) -> FastCaptureDependencies {
        FastCaptureDependencies(
            storePhoto: storePhoto ?? { source, aspect in
                guard case .data(let data) = source else { throw ImageStoreError.couldNotProcess }
                let name = String(decoding: data, as: UTF8.self)
                calls.state.withLock {
                    $0.order.append("store")
                    $0.stored.append(data)
                    $0.crops.append(aspect)
                }
                return StoredImage(uri: "stored://\(name)", thumbUri: "stored://\(name)-thumb", width: 100, height: 200, byteSize: 4242)
            },
            createItem: { draft in
                calls.state.withLock {
                    $0.order.append("create")
                    $0.created.append(draft)
                }
                return Item(
                    id: "item-1",
                    containerId: draft.containerId,
                    name: draft.name ?? "",
                    category: nil,
                    quantity: 1,
                    notes: nil,
                    createdAt: createdAt,
                    updatedAt: createdAt
                )
            },
            updateItem: { id, input in
                calls.state.withLock {
                    $0.order.append("update")
                    $0.updated.append((id, input))
                }
            },
            recognize: { uri in
                calls.state.withLock {
                    $0.order.append("recognize")
                    $0.recognized.append(uri)
                }
                return try await recognize(uri)
            }
        )
    }

    static let success = RecognitionResult.success(
        RecognitionSuggestion(name: "Cordless drill", category: "Tools", tags: ["dewalt", "power tool"], confidence: 0.9),
        contractVersion: 1
    )

    static let photo = ImageSource.data(Data("file://a.jpg".utf8))
}

private struct FastCaptureBoom: Error {}

@Suite("captureFastItem (fastCapture.test.ts)")
struct FastCaptureTests {
    private func capture(
        _ calls: FastCaptureCalls,
        recognize: @escaping @Sendable (String) async throws -> RecognitionResult = { _ in FastCaptureFakes.success }
    ) async throws -> FastCaptureOutcome {
        try await captureFastItem(
            containerId: "c1",
            photo: FastCaptureFakes.photo,
            cropToAspect: nil,
            dependencies: FastCaptureFakes.dependencies(calls, recognize: recognize)
        )
    }

    @Test("persists the item with its photo before recognition runs")
    func persistsBeforeRecognition() async throws {
        let calls = FastCaptureCalls()
        _ = try await capture(calls)
        #expect(calls.order.filter { $0 == "create" || $0 == "recognize" } == ["create", "recognize"])
        #expect(calls.order == ["store", "create", "recognize", "update"])
    }

    @Test("stores the photo and attaches it to the created item")
    func attachesPhoto() async throws {
        let calls = FastCaptureCalls()
        _ = try await capture(calls)

        #expect(calls.stored == [Data("file://a.jpg".utf8)])
        let draft = try #require(calls.created.first)
        #expect(draft.containerId == "c1")
        #expect(draft.photo == ItemPhotoInput(
            uri: "stored://file://a.jpg",
            thumbUri: "stored://file://a.jpg-thumb",
            width: 100,
            height: 200,
            byteSize: 4242
        ))
        // The photo row id is the repository's to choose.
        #expect(draft.photo?.id == nil)
    }

    @Test("fills the row in from a successful suggestion")
    func fillsRow() async throws {
        let calls = FastCaptureCalls()
        let outcome = try await capture(calls)

        #expect(outcome == .recognized(itemId: "item-1", name: "Cordless drill"))
        #expect(calls.updated.count == 1)
        let update = try #require(calls.updated.first)
        #expect(update.id == "item-1")
        #expect(update.input == UpdateItemInput(
            name: "Cordless drill",
            category: .set("Tools"),
            tags: ["dewalt", "power tool"],
            // RN's test fake returned no updatedAt, so its update ran unlocked; the repositories
            // always return one, and the pipeline locks on it.
            expectedUpdatedAt: FastCaptureFakes.createdAt
        ))
        // Recognition reads the stored photo, never hinted.
        #expect(calls.recognized == ["stored://file://a.jpg"])
    }

    @Test("leaves the item nameless rather than inventing a title when recognition fails")
    func namelessOnFailure() async throws {
        let calls = FastCaptureCalls()
        let outcome = try await capture(calls) { _ in .failed(.offline) }

        #expect(outcome == .unrecognized(itemId: "item-1", reason: .offline))
        // No name was written, so nothing has to be cleared before typing one.
        #expect(calls.updated.isEmpty)
        #expect(calls.created.first?.name == nil)
    }

    @Test(
        "treats not_configured, timeout, rate_limited and low_confidence as a nameable item rather than an error",
        arguments: [RecognitionFailureReason.notConfigured, .timeout, .rateLimited, .lowConfidence]
    )
    func failuresAreNameable(reason: RecognitionFailureReason) async throws {
        let calls = FastCaptureCalls()
        let outcome = try await capture(calls) { _ in .failed(reason) }

        #expect(outcome == .unrecognized(itemId: "item-1", reason: reason))
        #expect(outcome.itemId == "item-1")
    }

    @Test("survives a recognizer that throws instead of resolving")
    func survivesThrowingRecognizer() async throws {
        let calls = FastCaptureCalls()
        let outcome = try await capture(calls) { _ in throw FastCaptureBoom() }

        #expect(outcome == .unrecognized(itemId: "item-1", reason: .serverError))
        #expect(calls.updated.isEmpty)
    }

    @Test("keeps the other suggested fields when only the name comes back blank")
    func blankNameKeepsRest() async throws {
        let calls = FastCaptureCalls()
        let outcome = try await capture(calls) { _ in
            .success(RecognitionSuggestion(name: "   ", category: "Tools", tags: ["dewalt", "power tool"], confidence: 0.9), contractVersion: 1)
        }

        #expect(outcome == .unrecognized(itemId: "item-1", reason: .unrecognized))
        let update = try #require(calls.updated.first)
        #expect(update.input == UpdateItemInput(
            category: .set("Tools"),
            tags: ["dewalt", "power tool"],
            expectedUpdatedAt: FastCaptureFakes.createdAt
        ))
        #expect(update.input.name == nil)
    }

    @Test("propagates a storage failure so the camera can surface it")
    func propagatesStoreFailure() async throws {
        let calls = FastCaptureCalls()
        let dependencies = FastCaptureFakes.dependencies(
            calls,
            storePhoto: { _, _ in throw CocoaError(.fileWriteOutOfSpace) },
            recognize: { _ in FastCaptureFakes.success }
        )
        await #expect(throws: CocoaError.self) {
            try await captureFastItem(containerId: "c1", photo: FastCaptureFakes.photo, cropToAspect: nil, dependencies: dependencies)
        }
        #expect(calls.created.isEmpty)
    }

    // Native additions.

    @Test("trims the suggested name before writing it, and clears a missing category as RN's null did")
    func trimsName() async throws {
        let calls = FastCaptureCalls()
        let outcome = try await capture(calls) { _ in
            .success(RecognitionSuggestion(name: "  Angle grinder ", category: nil, tags: [], confidence: 0.8), contractVersion: 1)
        }

        #expect(outcome == .recognized(itemId: "item-1", name: "Angle grinder"))
        #expect(calls.updated.first?.input == UpdateItemInput(
            name: "Angle grinder",
            category: .clear,
            tags: [],
            expectedUpdatedAt: FastCaptureFakes.createdAt
        ))
    }

    @Test("passes the camera's crop to the store and leaves an unknown byte size out of the draft")
    func passesCropAndDropsUnknownSize() async throws {
        let calls = FastCaptureCalls()
        let dependencies = FastCaptureFakes.dependencies(
            calls,
            storePhoto: { _, aspect in
                calls.state.withLock { $0.crops.append(aspect) }
                return StoredImage(uri: "stored://x", thumbUri: "stored://x-thumb", width: 646, height: 1400, byteSize: nil)
            },
            recognize: { _ in .failed(.offline) }
        )
        _ = try await captureFastItem(
            containerId: DropZone.containerId,
            photo: FastCaptureFakes.photo,
            cropToAspect: CGSize(width: 393, height: 852),
            dependencies: dependencies
        )

        #expect(calls.crops == [CGSize(width: 393, height: 852)])
        let draft = try #require(calls.created.first)
        #expect(draft.containerId == DropZone.containerId)
        #expect(draft.photo?.byteSize == nil)
        #expect(draft.photo?.width == 646)
    }

    @Test("lets a conflict on the naming write propagate, as RN did")
    func conflictPropagates() async throws {
        let calls = FastCaptureCalls()
        var dependencies = FastCaptureFakes.dependencies(calls) { _ in FastCaptureFakes.success }
        dependencies.updateItem = { _, _ in throw ConflictError(updatedAt: 2) }
        await #expect(throws: ConflictError.self) {
            try await captureFastItem(containerId: "c1", photo: FastCaptureFakes.photo, cropToAspect: nil, dependencies: dependencies)
        }
        #expect(calls.created.count == 1)
    }
}
