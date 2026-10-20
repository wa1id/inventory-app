import CoreGraphics
import Foundation
import ImageIO

/// The last-shot tile's picture (05 §4.10): the newest Quick Snap shot, decoded straight to a
/// small size and turned upright. RN decoded the full-resolution q=1.0 temporary JPEG into a
/// 44 pt tile; natively only a thumbnail is ever decoded.
public enum CaptureShotThumbnail {
    /// The longer side the tile decodes to: a 44 pt square at 3× filled by photos up to about
    /// 2.2 : 1 (a portrait preview crop is 2.17 : 1).
    public static let maxPixelSize = 300

    /// The still's bytes (`AVCapturePhoto.fileDataRepresentation()`, HEIC or JPEG) decoded to at
    /// most `maxPixelSize` on the longer side, oriented by its EXIF orientation; nil when the
    /// bytes are not an image. Runs on the caller's thread: call it off the main actor.
    public static func decode(_ data: Data, maxPixelSize: Int = maxPixelSize) -> ThumbnailImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return ThumbnailImage(cgImage: image)
    }
}
