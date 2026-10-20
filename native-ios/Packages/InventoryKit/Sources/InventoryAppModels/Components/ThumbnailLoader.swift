import CoreGraphics
import Foundation
import ImageIO

// RN: src/ui/components/Thumb.tsx drew `<Image source={{ uri }}>`, which React Native decoded at
// full size. Natively the list thumbnails are decoded by ImageIO straight to the size they are
// drawn at, off the main actor, and kept in a small memory cache (05 §14).

/// A decoded thumbnail. Wraps `CGImage`, which is immutable and safe to share between threads
/// but not marked `Sendable` in the SDK, so the wrapper vouches for it.
public struct ThumbnailImage: @unchecked Sendable {
    public let cgImage: CGImage

    public init(cgImage: CGImage) {
        self.cgImage = cgImage
    }

    public var pixelWidth: Int { cgImage.width }
    public var pixelHeight: Int { cgImage.height }
}

/// Loads downsampled photos for thumbnails: decoded at the size they are drawn, never larger
/// than the file, oriented, and cached by file and size.
///
/// Decoding runs outside the actor so several rows decode at once and the cache never waits on
/// a slow file. Two requests for the same thumbnail share one decode. Failures are not cached:
/// a household photo that is downloaded later shows the next time a row asks.
public actor ThumbnailLoader {
    /// The app's loader.
    public static let shared = ThumbnailLoader()

    private let capacity: Int
    private var cache: [String: ThumbnailImage] = [:]
    /// Keys, least recently used first.
    private var order: [String] = []
    private var inFlight: [String: Task<ThumbnailImage?, Never>] = [:]

    /// - Parameter capacity: how many thumbnails stay in memory (about 120 rows of a list).
    public init(capacity: Int = 120) {
        self.capacity = max(1, capacity)
    }

    /// The photo at `url`, decoded so that its shorter side is at least `minimumPixelSize`
    /// pixels (so it can fill a square of that size), or nil when the file is missing or not an
    /// image.
    public func thumbnail(at url: URL, minimumPixelSize: Int) async -> ThumbnailImage? {
        let key = "\(url.path)|\(minimumPixelSize)"
        if let hit = cache[key] {
            touch(key)
            return hit
        }
        if let running = inFlight[key] { return await running.value }
        let task = Task.detached(priority: .userInitiated) {
            Self.decode(url, minimumPixelSize: minimumPixelSize)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { store(image, for: key) }
        return image
    }

    /// Drops every cached thumbnail (memory pressure).
    public func removeAll() {
        cache.removeAll()
        order.removeAll()
    }

    /// How many thumbnails are cached (for tests).
    public var cachedCount: Int { cache.count }

    /// Decodes one thumbnail with ImageIO, without caching the full image.
    public nonisolated static func decode(_ url: URL, minimumPixelSize: Int) -> ThumbnailImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else { return nil }
        let maxPixelSize = thumbnailMaxPixelSize(width: width, height: height, minimumPixelSize: minimumPixelSize)
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return ThumbnailImage(cgImage: image)
    }

    /// The longer side to ask ImageIO for, so that the shorter side reaches `minimumPixelSize`
    /// (a cover-fitted square needs its shorter side), never more than the image has.
    public nonisolated static func thumbnailMaxPixelSize(width: Int, height: Int, minimumPixelSize: Int) -> Int {
        let long = max(width, height)
        let short = max(1, min(width, height))
        let needed = (Double(max(1, minimumPixelSize)) * Double(long) / Double(short)).rounded(.up)
        return min(long, max(1, Int(needed)))
    }

    private func store(_ image: ThumbnailImage, for key: String) {
        cache[key] = image
        touch(key)
        while order.count > capacity {
            let evicted = order.removeFirst()
            cache[evicted] = nil
        }
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
