import CoreGraphics
import Foundation
import InventoryCore
import InventoryNetwork
import InventoryStorage

/// How one Quick Snap photo ended (RN `FastCaptureOutcome`). Never a failure: recognition problems
/// leave a real, photographed item that needs naming later.
// RN: src/services/capture/fastCapture.ts:19-21
public enum FastCaptureOutcome: Sendable, Hashable {
    /// The row was named from the suggestion.
    case recognized(itemId: String, name: String)
    /// The row stays unnamed (`''`); `reason` says why recognition gave no name.
    case unrecognized(itemId: String, reason: RecognitionFailureReason)

    /// The item the photo became.
    public var itemId: String {
        switch self {
        case .recognized(let itemId, _), .unrecognized(let itemId, _): itemId
        }
    }
}

/// What ``captureFastItem(containerId:photo:cropToAspect:dependencies:)`` does its work with
/// (RN `FastCaptureDeps`). ``FastCapturePipeline`` wires the real ones; tests pass closures.
// RN: src/services/capture/fastCapture.ts:12-17
public struct FastCaptureDependencies: Sendable {
    /// Stores the photo and its thumbnail (RN `storeItemPhoto`).
    public var storePhoto: @Sendable (_ photo: ImageSource, _ cropToAspect: CGSize?) async throws -> StoredImage
    /// Writes the item with its photo row in one transaction (RN `repos.items.create`).
    public var createItem: @Sendable (_ draft: ItemDraft) async throws -> Item
    /// Patches the item (RN `repos.items.update`); the merged row, nil when it is gone, is not used.
    public var updateItem: @Sendable (_ id: String, _ input: UpdateItemInput) async throws -> Void
    /// Recognises the stored photo by its stored URI (RN `recognizeItem({imageUri})`, never hinted).
    /// Contractually total, but a thrown error is read as `server_error`.
    public var recognize: @Sendable (_ storedURI: String) async throws -> RecognitionResult

    public init(
        storePhoto: @escaping @Sendable (_ photo: ImageSource, _ cropToAspect: CGSize?) async throws -> StoredImage,
        createItem: @escaping @Sendable (_ draft: ItemDraft) async throws -> Item,
        updateItem: @escaping @Sendable (_ id: String, _ input: UpdateItemInput) async throws -> Void,
        recognize: @escaping @Sendable (_ storedURI: String) async throws -> RecognitionResult
    ) {
        self.storePhoto = storePhoto
        self.createItem = createItem
        self.updateItem = updateItem
        self.recognize = recognize
    }
}

/// Captures one item without interrupting the person holding the camera (RN `captureFastItem`,
/// 05 §5).
///
/// The item is written **before** recognition runs, so the shutter can fire again at once and a
/// crash mid-session loses nothing but a name. The row is created with no name (stored as `''`)
/// rather than an invented one. Recognition then enriches the row in place:
/// 1. store the photo (errors propagate);
/// 2. create the unnamed item with the photo, `byteSize` left out when unknown (errors propagate);
/// 3. recognise the stored photo; a recogniser that throws counts as `server_error`;
/// 4. a failed recognition writes nothing and returns `unrecognized` with its reason;
/// 5. a suggestion whose name is blank after a JS trim still writes its category and tags, and
///    returns `unrecognized(unrecognized)`;
/// 6. otherwise the trimmed name, the category and the tags are written, under the optimistic lock
///    of the created row's `updatedAt`, and the outcome is `recognized`.
///
/// Throws only when the photo or the row could not be written, or when the enriching update fails
/// (a ``InventoryCore/ConflictError`` included, as in RN, where the camera then counts the shot as
/// dropped).
// RN: src/services/capture/fastCapture.ts:49-105
public func captureFastItem(
    containerId: String,
    photo: ImageSource,
    cropToAspect: CGSize?,
    dependencies: FastCaptureDependencies
) async throws -> FastCaptureOutcome {
    let stored = try await dependencies.storePhoto(photo, cropToAspect)
    // No name: recognition has not run yet, and inventing one would be a lie the person then has
    // to clear before typing the real thing.
    let item = try await dependencies.createItem(ItemDraft(
        containerId: containerId,
        photo: ItemPhotoInput(
            uri: stored.uri,
            thumbUri: stored.thumbUri,
            width: stored.width,
            height: stored.height,
            byteSize: stored.byteSize
        )
    ))

    let result: RecognitionResult
    do {
        result = try await dependencies.recognize(stored.uri)
    } catch {
        result = .failed(.serverError)
    }

    let suggestion: RecognitionSuggestion
    switch result {
    case .failed(let reason):
        // Nothing to write: the row already reflects reality, a photographed item that still
        // needs a name.
        return .unrecognized(itemId: item.id, reason: reason)
    case .success(let value, _):
        suggestion = value
    }

    let name = suggestion.name?.jsTrimmed() ?? ""
    guard !name.isEmpty else {
        // Recognition succeeded on everything but the name; keep the rest.
        try await dependencies.updateItem(item.id, UpdateItemInput(
            category: FieldUpdate(suggestion.category),
            tags: suggestion.tags,
            expectedUpdatedAt: item.updatedAt
        ))
        return .unrecognized(itemId: item.id, reason: .unrecognized)
    }

    try await dependencies.updateItem(item.id, UpdateItemInput(
        name: name,
        category: FieldUpdate(suggestion.category),
        tags: suggestion.tags,
        expectedUpdatedAt: item.updatedAt
    ))
    return .recognized(itemId: item.id, name: name)
}

/// Runs a Quick Snap photo through the pipeline (``FastCapturePipeline`` in the app; a script in
/// tests of the camera model).
public protocol FastCapturing: Sendable {
    /// Stores `photo`, creates its unnamed item in `containerId` through `items` and names it when
    /// recognition can. Throws when the photo or the row could not be written.
    func capture(
        containerId: String,
        photo: ImageSource,
        cropToAspect: CGSize?,
        items: any ItemsRepository
    ) async throws -> FastCaptureOutcome
}

/// Recognises a stored photo by its stored URI. Never throws, like ``RecognitionClient``.
public typealias FastCaptureRecognizer = @Sendable (_ storedURI: String) async -> RecognitionResult

/// The Quick Snap pipeline, app-scoped so pipelines outlive the camera screen (05 §4.6).
///
/// Each shot runs ``captureFastItem(containerId:photo:cropToAspect:dependencies:)`` concurrently
/// with the others, as in RN, with two bounds RN did not have (00-index §5, 05 Q7):
/// - image processing is serial, because the ``ImageStore`` actor encodes one photo at a time;
/// - at most ``maxConcurrentRecognitions`` recognitions are in flight; later ones wait their turn
///   in shutter order. Rows are written before they wait, so nothing is lost meanwhile.
///
/// The items repository is passed per shot, as RN read `repos` at the shutter press: local, or the
/// household's while paired.
public actor FastCapturePipeline: FastCapturing {
    /// Recognitions allowed in flight at once unless the initialiser says otherwise.
    public static let defaultMaxConcurrentRecognitions = 2

    private let photos: any PhotoStoring
    private let recognizer: FastCaptureRecognizer
    /// The cap on concurrent recognitions (at least 1).
    public nonisolated let maxConcurrentRecognitions: Int

    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - photos: Where photos are stored; the app's ``ImageStore``.
    ///   - recognizer: Recognises a stored photo; see ``recognizer(client:resolver:)``.
    ///   - maxConcurrentRecognitions: The in-flight cap; values below 1 mean 1.
    public init(
        photos: any PhotoStoring,
        recognizer: @escaping FastCaptureRecognizer,
        maxConcurrentRecognitions: Int = FastCapturePipeline.defaultMaxConcurrentRecognitions
    ) {
        self.photos = photos
        self.recognizer = recognizer
        self.maxConcurrentRecognitions = max(1, maxConcurrentRecognitions)
    }

    /// Recognitions running right now.
    public var recognitionsInFlight: Int { running }

    public func capture(
        containerId: String,
        photo: ImageSource,
        cropToAspect: CGSize?,
        items: any ItemsRepository
    ) async throws -> FastCaptureOutcome {
        let photos = photos
        let dependencies = FastCaptureDependencies(
            storePhoto: { source, aspect in try await photos.storeItemPhoto(source, cropToAspect: aspect) },
            createItem: { draft in try await items.create(draft) },
            updateItem: { id, input in _ = try await items.update(id, input) },
            recognize: { [self] uri in await recognizeInTurn(uri) }
        )
        return try await captureFastItem(
            containerId: containerId,
            photo: photo,
            cropToAspect: cropToAspect,
            dependencies: dependencies
        )
    }

    /// Recognises within the cap: takes a slot, or waits for one in arrival order.
    private func recognizeInTurn(_ storedURI: String) async -> RecognitionResult {
        if running < maxConcurrentRecognitions {
            running += 1
        } else {
            // The slot is handed over by `finishRecognition`, so `running` stays counted.
            await withCheckedContinuation { waiting.append($0) }
        }
        let result = await recognizer(storedURI)
        finishRecognition()
        return result
    }

    private func finishRecognition() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }

    /// The production recogniser: resolves the stored URI to the current container's file
    /// (05 C1, DECISIONS D-4) and asks `client`, never hinted (RN `recognizeItem({imageUri})`).
    ///
    /// A URI that resolves to nothing is still handed over as a URL, so the client's file read
    /// fails inside its deadline and reports `server_error`, as RN's failed read did.
    public static func recognizer(client: RecognitionClient, resolver: PhotoPathResolver) -> FastCaptureRecognizer {
        { storedURI in
            let url = resolver.resolve(storedURI) ?? URL(string: storedURI) ?? URL(filePath: storedURI)
            return await client.recognize(imageAt: url)
        }
    }
}
