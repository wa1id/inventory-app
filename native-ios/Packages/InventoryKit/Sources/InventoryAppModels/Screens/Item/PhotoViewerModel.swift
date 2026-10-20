import InventoryCore
import InventoryStrings
import Observation

// RN: app/item/[id]/photo.tsx. The photo viewer's logic: the read, what it shows, the spoken
// label and the swipe-down rules. The SwiftUI side is `PhotoViewerScreen`.

/// The item's photo, full screen (RN `PhotoScreen`, 05 §13).
///
/// It reads the item (`items.getById`, key `item:<id>`) and shows its full photo
/// (`photoUri ?? photoThumbUri`, 05 §9.6); a photo whose file cannot be read
/// (``imageFailed(_:)``) says the photo is missing, as a missing URI does.
@MainActor
@Observable
public final class PhotoViewerModel {
    /// What the viewer shows (RN lines 108-168).
    public enum Phase: Equatable {
        /// The read failed: the described title and body, and Try again.
        case failed(title: String, body: String)
        /// Nothing read yet: a spinner once 180 ms have passed.
        case loading
        /// The item is gone.
        case gone
        /// No photo, or its file could not be read.
        case missing
        /// The picture at this stored URI.
        case photo(uri: String)
    }

    public let itemId: String
    /// `items.getById(itemId)`, key `item:<id>`.
    public let query: InventoryQuery<ItemWithContext?>
    /// The URI whose image failed to load (RN `failedUri`).
    public private(set) var failedUri: String?
    /// The spinner shows once loading has lasted 180 ms (RN `useDelayedFlag`).
    public let spinner: DelayedFlag

    /// - Parameters:
    ///   - items: the items repository in use at each call (`app.repositories.items`).
    ///   - revision: the database revision now.
    public init(itemId: String, items: any ItemsRepository, revision: Int = 0, clock: any Clock<Duration> = ContinuousClock()) {
        self.itemId = itemId
        query = InventoryQuery(key: "item:\(itemId)", revision: revision) { try await items.getById(itemId) }
        spinner = DelayedFlag(clock: clock)
        query.onSettle = { [weak self] in self?.updateSpinner() }
    }

    // MARK: Driving

    public func focusChanged(_ focused: Bool, revision: Int? = nil) {
        query.focusChanged(focused, revision: revision)
        updateSpinner()
    }

    public func revisionChanged(_ revision: Int) {
        query.revisionChanged(revision)
        updateSpinner()
    }

    /// Try again.
    public func retry() {
        query.reload()
        updateSpinner()
    }

    /// The image at `uri` could not be decoded or read.
    public func imageFailed(_ uri: String) {
        failedUri = uri
    }

    // MARK: Outputs

    /// The item as last read; nil while loading or once it is gone.
    public var item: ItemWithContext? { query.data ?? nil }

    /// The full photo, or the thumbnail for rows from before thumbnails existed the other way
    /// round (05 §9.6).
    public var uri: String? { item.flatMap { $0.photoUri ?? $0.photoThumbUri } }

    public var phase: Phase {
        guard let item else {
            if let cause = query.cause {
                let described = describeError(cause, context: .read, subject: .item)
                return .failed(title: described.title, body: described.body)
            }
            return query.isLoading ? .loading : .gone
        }
        guard let uri = item.photoUri ?? item.photoThumbUri, uri != failedUri else { return .missing }
        return .photo(uri: uri)
    }

    /// "Photo of Cordless drill", or "Photo of this item".
    public var accessibilityLabel: String {
        guard let name = item?.name, !name.isEmpty else { return L10n.Photo.a11yUnnamed }
        return L10n.Photo.a11y(name: name)
    }

    private func updateSpinner() {
        spinner.setActive(query.isLoading && item == nil)
    }
}

/// The viewer's swipe down to close (RN photo.tsx:175-193).
///
/// A drag is taken only at zoom 1 (≤ 1.01), with one finger, once it is clearly downward: more
/// than 10 pt down and more than one and a half times as far down as sideways. The picture
/// follows it down (never up); let go more than 80 pt down and the viewer closes, otherwise it
/// settles back (180 ms on the settle curve, at once under Reduce Motion).
public enum PhotoViewerGesture {
    /// A downward drag longer than this closes the viewer (RN `CLOSE_DRAG`).
    public static let closeDistance: Double = 80
    /// A drag counts once it is this far down (RN `DRAG_START`).
    public static let startDistance: Double = 10
    /// Zoomed in beyond this, a drag pans the picture instead.
    public static let zoomedInAbove: Double = 1.01
    /// How far down per sideways point a drag must go to count.
    public static let downwardRatio: Double = 1.5
    /// The settle back after a short drag: `Motion.duration.expand` (0 under Reduce Motion) on
    /// `Motion.Easing.settle`.
    public static func settleMilliseconds(reduceMotion: Bool) -> Int {
        Motion.duration(reduceMotion: reduceMotion).expand
    }

    /// Whether a touch that has moved `dx`, `dy` from where it started begins the close drag.
    public static func beginsDrag(zoomScale: Double, touches: Int, dx: Double, dy: Double) -> Bool {
        dy > startDistance && takesDrag(zoomScale: zoomScale, touches: touches, dx: dx, dy: dy)
    }

    /// The same rule without the 10 pt start, for a pan recognizer that has already required
    /// its own movement before it asks (UIKit's pan hysteresis is about 10 pt).
    public static func takesDrag(zoomScale: Double, touches: Int, dx: Double, dy: Double) -> Bool {
        zoomScale <= zoomedInAbove && touches == 1 && dy > 0 && dy > abs(dx) * downwardRatio
    }

    /// How far the picture follows a drag `dy` down.
    public static func offset(forDrag dy: Double) -> Double {
        max(0, dy)
    }

    /// Whether letting go after a drag `dy` down closes the viewer.
    public static func closes(afterDrag dy: Double) -> Bool {
        dy > closeDistance
    }
}
