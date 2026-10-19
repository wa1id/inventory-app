import CoreGraphics
import Foundation
import ImageIO

/// Upright pixels that stand for a source image of `fullSize`.
///
/// `image` may be downsampled, but it always covers the whole source, so a rectangle measured in
/// full-resolution pixels maps onto it by scaling alone.
struct DecodedImage: Sendable {
    /// Upright pixels: the EXIF orientation is already applied.
    let image: CGImage
    /// Upright size of the source at full resolution.
    let fullSize: PixelSize
}

/// Reads images with ImageIO: HEIC and JPEG captures, library imports, WebP photos and the legacy
/// JPEG photos of the MVP era, which may sit under a `.webp` name after a restore (03 §7.4). The
/// format is sniffed from the bytes, never taken from a file extension.
public enum ImageDecoder {
    /// The upright size of encoded image bytes at full resolution, read from the header without
    /// decoding pixels, or nil when ImageIO cannot read it.
    public static func uprightSize(of data: Data) -> PixelSize? {
        guard let source = makeSource(data) else { return nil }
        return uprightSize(of: source)
    }

    /// Decodes encoded bytes into upright pixels whose longer edge is at most `maxPixelSize`
    /// (never enlarged; nil keeps the full resolution).
    public static func decode(_ data: Data, maxPixelSize: Int? = nil) throws -> CGImage {
        try decodeUpright(data) { full in maxPixelSize.map { min($0, full.longestEdge) } }.image
    }

    /// ``decode(_:maxPixelSize:)`` for a local file.
    public static func decode(contentsOf url: URL, maxPixelSize: Int? = nil) throws -> CGImage {
        try decode(readFile(url), maxPixelSize: maxPixelSize)
    }

    /// Decodes `source` upright. For encoded sources, `longestEdge` receives the upright
    /// full-resolution size and returns the longer edge to decode at (nil for full resolution),
    /// so a large capture is downsampled while it is decoded instead of being decoded whole.
    static func decodeUpright(_ source: ImageSource, longestEdge: (PixelSize) -> Int?) throws -> DecodedImage {
        switch source {
        case .data(let data):
            return try decodeUpright(data, longestEdge: longestEdge)
        case .file(let url):
            return try decodeUpright(readFile(url), longestEdge: longestEdge)
        case .image(let image):
            guard image.width > 0, image.height > 0 else { throw ImageStoreError.unsupportedSize }
            return DecodedImage(image: image, fullSize: PixelSize(width: image.width, height: image.height))
        }
    }

    static func decodeUpright(_ data: Data, longestEdge: (PixelSize) -> Int?) throws -> DecodedImage {
        guard let source = makeSource(data) else { throw ImageStoreError.undecodable }
        let header = uprightSize(of: source)

        // RN decodes through UIImage and ImageFixOrientationTransformer, which bakes the EXIF
        // orientation into the pixels (05 §9.2 step 1). The transform option does the same here.
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let header, let edge = longestEdge(header) {
            options[kCGImageSourceThumbnailMaxPixelSize] = max(1, min(edge, header.longestEdge))
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageStoreError.undecodable
        }
        guard image.width > 0, image.height > 0 else { throw ImageStoreError.unsupportedSize }

        var full = header ?? PixelSize(width: image.width, height: image.height)
        // The header and the decoded pixels must agree on which way round the image is.
        if (image.width > image.height && full.width < full.height)
            || (image.width < image.height && full.width > full.height) {
            full = PixelSize(width: full.height, height: full.width)
        }
        if image.width > full.width || image.height > full.height {
            full = PixelSize(width: image.width, height: image.height)
        }
        return DecodedImage(image: image, fullSize: full)
    }

    private static func makeSource(_ data: Data) -> CGImageSource? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        return source
    }

    private static func uprightSize(of source: CGImageSource) -> PixelSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
              width > 0, height > 0
        else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        // EXIF orientations 5–8 turn the image a quarter, so its upright size is transposed.
        return (5...8).contains(orientation)
            ? PixelSize(width: height, height: width)
            : PixelSize(width: width, height: height)
    }

    private static func readFile(_ url: URL) throws -> Data {
        // Only local files: Data(contentsOf:) would fetch a remote URL synchronously.
        guard url.isFileURL else { throw ImageStoreError.undecodable }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
}
