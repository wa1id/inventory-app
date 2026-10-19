/// A size in whole pixels.
public struct PixelSize: Sendable, Hashable, Codable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// The longer edge.
    public var longestEdge: Int { max(width, height) }
}

/// Sizing rules for stored photos (05 §2, §9.1).
///
/// Photos are the only thing in the app that grows without bound, so these numbers decide the
/// size of the app on the device and in the backup bucket.
// RN: src/services/capture/imageScaling.ts
public enum ImageScaling {
    /// Longest edge of a stored photo, whichever way it is turned. The recognition model
    /// downsamples to about 1568 px anyway, and the largest a photo is drawn is a full-width
    /// detail view.
    public static let maxImageDimension = 1400
    /// WebP quality of the stored photo.
    public static let imageQuality = 0.8

    /// Longest edge of the list-row thumbnail: a 64 pt slot at 3x with headroom.
    public static let thumbnailDimension = 320
    /// WebP quality of the thumbnail.
    public static let thumbnailQuality = 0.7

    /// Target dimensions that fit `maxEdge` on the **longer** side, or nil when the image already
    /// fits and must be left alone.
    ///
    /// Bounds the longer edge rather than the width, and never enlarges. Both dimensions round
    /// like JS `Math.round` (half up; the same as `.toNearestOrAwayFromZero` for the positive
    /// values here) and are at least 1, so a pathologically thin source never rounds to zero.
    // RN: src/services/capture/imageScaling.ts:50-64
    public static func scaleToFit(width: Int, height: Int, maxEdge: Int) -> PixelSize? {
        let longest = max(width, height)
        if longest <= maxEdge { return nil }

        // Same IEEE operations in the same order as the JS, so results match bit for bit.
        let scale = Double(maxEdge) / Double(longest)
        return PixelSize(
            width: max(1, Int((Double(width) * scale).rounded(.toNearestOrAwayFromZero))),
            height: max(1, Int((Double(height) * scale).rounded(.toNearestOrAwayFromZero)))
        )
    }

    /// ``scaleToFit(width:height:maxEdge:)`` applied to a size.
    public static func scaleToFit(_ size: PixelSize, maxEdge: Int) -> PixelSize? {
        scaleToFit(width: size.width, height: size.height, maxEdge: maxEdge)
    }
}
