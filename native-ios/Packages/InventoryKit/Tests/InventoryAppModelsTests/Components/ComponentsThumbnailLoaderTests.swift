import CoreGraphics
import Foundation
import ImageIO
import InventoryTestSupport
import Testing
import UniformTypeIdentifiers
@testable import InventoryAppModels

/// The downsampling thumbnail loader behind `Thumb` (05 §14). RN decoded with `<Image>`; there
/// is no RN test.
@Suite("Thumbnail loader (Thumb.tsx)")
struct ComponentsThumbnailLoaderTests {
    /// Writes a solid PNG of `width` × `height` pixels and returns its URL.
    static func writePNG(width: Int, height: Int, in directory: TemporaryDirectory, name: String = "photo.png") throws -> URL {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        try FileManager.default.createDirectory(at: directory.root, withIntermediateDirectories: true)
        let url = directory.url(name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test("asks for a long side that lets the short side fill the square, never upscaling")
    func maxPixelSize() {
        #expect(ThumbnailLoader.thumbnailMaxPixelSize(width: 400, height: 200, minimumPixelSize: 100) == 200)
        #expect(ThumbnailLoader.thumbnailMaxPixelSize(width: 300, height: 300, minimumPixelSize: 168) == 168)
        #expect(ThumbnailLoader.thumbnailMaxPixelSize(width: 120, height: 60, minimumPixelSize: 228) == 120)
    }

    @Test("decodes at the drawn size")
    func downsamples() async throws {
        let directory = try TemporaryDirectory()
        let url = try Self.writePNG(width: 800, height: 400, in: directory)
        let loader = ThumbnailLoader()
        let thumbnail = try #require(await loader.thumbnail(at: url, minimumPixelSize: 100))
        #expect(min(thumbnail.pixelWidth, thumbnail.pixelHeight) == 100)
        #expect(max(thumbnail.pixelWidth, thumbnail.pixelHeight) == 200)
    }

    @Test("caches by file and size, and evicts the least recently used")
    func caches() async throws {
        let directory = try TemporaryDirectory()
        let first = try Self.writePNG(width: 64, height: 64, in: directory, name: "a.png")
        let second = try Self.writePNG(width: 64, height: 64, in: directory, name: "b.png")
        let loader = ThumbnailLoader(capacity: 1)
        let once = try #require(await loader.thumbnail(at: first, minimumPixelSize: 32))
        let again = try #require(await loader.thumbnail(at: first, minimumPixelSize: 32))
        #expect(once.cgImage === again.cgImage)
        _ = await loader.thumbnail(at: second, minimumPixelSize: 32)
        #expect(await loader.cachedCount == 1)
        let reloaded = try #require(await loader.thumbnail(at: first, minimumPixelSize: 32))
        #expect(reloaded.cgImage !== once.cgImage)
    }

    @Test("a missing or unreadable file gives nothing, and is tried again next time")
    func failures() async throws {
        let directory = try TemporaryDirectory()
        let loader = ThumbnailLoader()
        let missing = directory.url("missing.webp")
        #expect(await loader.thumbnail(at: missing, minimumPixelSize: 56) == nil)
        try directory.write(Data("not an image".utf8), to: "junk.webp")
        #expect(await loader.thumbnail(at: directory.url("junk.webp"), minimumPixelSize: 56) == nil)
        #expect(await loader.cachedCount == 0)
        // The household photo arrives later: the same URL now loads.
        _ = try Self.writePNG(width: 32, height: 32, in: directory, name: "missing.webp")
        #expect(await loader.thumbnail(at: missing, minimumPixelSize: 16) != nil)
    }
}
