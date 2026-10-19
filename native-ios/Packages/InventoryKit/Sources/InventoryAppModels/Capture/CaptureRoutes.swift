import CoreGraphics
import Foundation
import InventoryCore
import InventoryServices

/// Opening the camera (RN `/capture?containerId&mode&since`, 05 §3-4.1). Presented as a full-screen
/// cover. Request mode (a photo for the Add sheet) is not part of the route: it is the delivery
/// closure given to ``CaptureModel``.
public struct CaptureRoute: Sendable, Hashable {
    /// `drop-zone` or a container id.
    public var containerId: String
    /// Asked-for mode; request mode is always single.
    public var mode: CaptureMode
    /// Epoch ms of the session's first shot, carried through Keep shooting so a resumed session
    /// reviews as one.
    public var since: Int64?
    /// Photos of the set already counted by the review before Keep shooting, so the next review
    /// still waits for the ones in flight (DECISIONS U6: RN reset this to zero, 05 C7).
    public var expectedBase: Int

    public init(containerId: String, mode: CaptureMode = .single, since: Int64? = nil, expectedBase: Int = 0) {
        self.containerId = containerId
        self.mode = mode
        self.since = since
        self.expectedBase = expectedBase
    }

    /// Quick Snap into the drop zone (RN `openQuickSnap()`): the Add tab's long press, the Home
    /// card and the Drop zone tab.
    public static let quickSnap = CaptureRoute(containerId: DropZone.containerId, mode: .fast)
}

/// Opening the Quick Snap review (RN `/capture/review?containerId&since&expected`).
public struct QuickSnapReviewRoute: Sendable, Hashable {
    public var containerId: String
    /// Rows created at or after this epoch ms in the container belong to the set.
    public var since: Int64
    /// Photos the camera (and any earlier part of the set) reported.
    public var expected: Int

    public init(containerId: String, since: Int64, expected: Int) {
        self.containerId = containerId
        self.since = since
        self.expected = expected
    }
}

/// Where the camera goes when it leaves (05 §3 "Exits from the camera"). Each camera leaves once.
public enum CaptureNavigation: Sendable, Hashable {
    /// Dismiss the camera: ✕ or Done with no shots, a delivered request photo, or "Type it
    /// instead" in request mode (back to the waiting Add sheet).
    case back
    /// Replace the camera with the Add sheet for `containerId`, with the stored photo or (Type it
    /// instead) without one (RN `/item/new?containerId[&photo…]`).
    case addItem(containerId: String, photo: StoredImage?)
    /// Replace the camera with the set's review.
    case review(QuickSnapReviewRoute)
}

/// A still the camera service took, with the crop that keeps what the preview showed
/// (`ImageStore.previewCropAspect`, DECISIONS U7).
public struct CapturedPhoto: Sendable, Hashable {
    /// `AVCapturePhoto.fileDataRepresentation()` (HEIC), straight to the image store.
    public var data: Data
    /// The preview's aspect as ``ImageStore/previewCropAspect(previewSize:previewRotationAngle:captureRotationAngle:)``
    /// computed it for this shot; nil keeps the whole still.
    public var cropAspect: CGSize?

    public init(data: Data, cropAspect: CGSize?) {
        self.data = data
        self.cropAspect = cropAspect
    }
}

/// How a library pick ended (PhotosPicker plus the Transferable load).
public enum CaptureLibraryPick: Sendable {
    /// The picker closed without a choice.
    case cancelled
    /// The photo could not be loaded (`strings.capture.libraryFailed`).
    case failed
    /// The chosen photo, as a file or bytes; the camera's crop does not apply.
    case picked(ImageSource)
}

/// Where the capture photos go, for the Into pill (RN `into` query, 05 §4.2): the container and its
/// space.
public struct CaptureIntoPlace: PlaceLike, Sendable, Hashable {
    public var containerId: String
    public var containerName: String?
    public var containerShortCode: String
    public var spaceId: String
    public var spaceName: String
    public var spaceColor: String

    public init(
        containerId: String,
        containerName: String?,
        containerShortCode: String,
        spaceId: String,
        spaceName: String,
        spaceColor: String
    ) {
        self.containerId = containerId
        self.containerName = containerName
        self.containerShortCode = containerShortCode
        self.spaceId = spaceId
        self.spaceName = spaceName
        self.spaceColor = spaceColor
    }

    /// The Into pill's read (RN `index.tsx:127-141`): nil for the drop zone, a missing container,
    /// or a container whose space is missing. Run it as the screen's query, keyed
    /// `capture-into:<containerId>`, and hand the answer to ``CaptureModel/intoLoaded(_:)``.
    // RN: app/capture/index.tsx:127-141
    public static func read(
        containerId: String,
        containers: any ContainersRepository,
        spaces: any SpacesRepository
    ) async throws -> CaptureIntoPlace? {
        if containerId == DropZone.containerId { return nil }
        guard let container = try await containers.getById(containerId) else { return nil }
        guard let home = try await spaces.getById(container.spaceId) else { return nil }
        return CaptureIntoPlace(
            containerId: container.id,
            containerName: container.name,
            containerShortCode: container.shortCode,
            spaceId: home.id,
            spaceName: home.name,
            spaceColor: home.color
        )
    }
}
