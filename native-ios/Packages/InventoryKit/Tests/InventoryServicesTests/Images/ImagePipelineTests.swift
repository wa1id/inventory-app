import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import InventoryServices

@Suite("WebP encoder")
struct WebPEncoderTests {
    static func bitmap(_ image: CGImage) throws -> OpaqueBitmap {
        let decoded = DecodedImage(image: image, fullSize: PixelSize(width: image.width, height: image.height))
        return try OpaqueBitmap.render(decoded, crop: PixelRect(decoded.fullSize), size: decoded.fullSize)
    }

    @Test("round-trips its dimensions through ImageIO and the VP8 header", arguments: [
        (1400, 1050), (1050, 1400), (320, 240), (1, 1), (1400, 1), (3, 7), (999, 333),
    ])
    func roundTripsDimensions(width: Int, height: Int) throws {
        let data = try WebPEncoder.encode(Self.bitmap(TestImages.marked(width: width, height: height)), quality: 0.8)

        #expect(Inspect.typeIdentifier(data) == UTType.webP.identifier)
        let decoded = try Inspect.image(data)
        #expect(decoded.width == width)
        #expect(decoded.height == height)
        #expect(try Inspect.vp8Size(data) == PixelSize(width: width, height: height))
    }

    @Test("writes a bare lossy file: one VP8 chunk, so no EXIF, XMP, ICC profile or alpha")
    func writesBareLossyFile() throws {
        let data = try WebPEncoder.encode(Self.bitmap(TestImages.marked(width: 400, height: 300)), quality: 0.7)

        #expect(try Inspect.webPChunks(data) == ["VP8 "])
    }

    @Test("keeps flat colours within a few levels")
    func keepsColours() throws {
        let image = try TestImages.make(width: 256, height: 256, background: .grey, blocks: [
            .init(x: 0, y: 0, width: 128, height: 128, color: .red),
            .init(x: 128, y: 128, width: 128, height: 128, color: .blue),
        ])
        let decoded = try Inspect.image(WebPEncoder.encode(Self.bitmap(image), quality: 0.8))

        #expect(try Inspect.pixel(decoded, x: 64, y: 64).isClose(to: .red, tolerance: 6))
        #expect(try Inspect.pixel(decoded, x: 192, y: 192).isClose(to: .blue, tolerance: 6))
        #expect(try Inspect.pixel(decoded, x: 192, y: 64).isClose(to: .grey, tolerance: 6))
    }

    @Test("a lower quality makes a smaller file")
    func qualityChangesSize() throws {
        // Noise, so the encoder has detail to throw away.
        var generator = SplitMix(seed: 7)
        let blocks = (0..<600).map { _ in
            TestImages.Block(
                x: Int(generator.next() % 380), y: Int(generator.next() % 280), width: 1 + Int(generator.next() % 20),
                height: 1 + Int(generator.next() % 20),
                color: RGB(r: Int(generator.next() % 256), g: Int(generator.next() % 256), b: Int(generator.next() % 256)))
        }
        let bitmap = try Self.bitmap(TestImages.make(width: 400, height: 300, blocks: blocks))

        let high = try WebPEncoder.encode(bitmap, quality: ImageScaling.imageQuality)
        let low = try WebPEncoder.encode(bitmap, quality: ImageScaling.thumbnailQuality)
        #expect(low.count < high.count)
        // libwebp is deterministic, so the same pixels and quality give the same bytes.
        #expect(try WebPEncoder.encode(bitmap, quality: ImageScaling.imageQuality) == high)
    }
}

@Suite("Image pipeline")
struct ImagePipelineTests {
    // MARK: Crop to the preview (DECISIONS U7, 05 C4)

    @Test("crops a portrait still to a phone preview like expo-camera")
    func cropsToPhonePreview() {
        // 393×852 pt preview over a 3024×4032 still: AVMakeRect gives x = 582.08…, width 1859.83…,
        // which CGRectIntegral rounds out to 582…2442.
        let crop = ImagePipeline.cropRect(
            for: PixelSize(width: 3024, height: 4032), aspect: CGSize(width: 393, height: 852))
        #expect(crop == PixelRect(x: 582, y: 0, width: 1860, height: 4032))
    }

    @Test("crops a landscape still to the same rectangle turned a quarter")
    func cropsLandscape() {
        let crop = ImagePipeline.cropRect(
            for: PixelSize(width: 4032, height: 3024), aspect: CGSize(width: 852, height: 393))
        #expect(crop == PixelRect(x: 0, y: 582, width: 4032, height: 1860))
    }

    @Test("keeps the whole image for a matching, missing or unusable aspect", arguments: [
        CGSize(width: 3, height: 4), CGSize(width: 0, height: 4), CGSize(width: 3, height: 0),
        CGSize(width: -1, height: 4), CGSize(width: CGFloat.nan, height: 4), CGSize(width: CGFloat.infinity, height: 1),
    ])
    func keepsWholeImage(aspect: CGSize) {
        let whole = PixelRect(x: 0, y: 0, width: 3024, height: 4032)
        #expect(ImagePipeline.cropRect(for: PixelSize(width: 3024, height: 4032), aspect: aspect) == whole)
        #expect(ImagePipeline.cropRect(for: PixelSize(width: 3024, height: 4032), aspect: nil) == whole)
    }

    @Test("a wider aspect shortens the long edge")
    func widerAspectShortensLongEdge() {
        // An iPad-style crop of a portrait still to 16:9: 3024 × 1701 out of the middle.
        let crop = ImagePipeline.cropRect(
            for: PixelSize(width: 3024, height: 4032), aspect: CGSize(width: 16, height: 9))
        #expect(crop == PixelRect(x: 0, y: 1165, width: 3024, height: 1702))
    }

    @Test("decodes just large enough for the crop to fill the target")
    func decodeEdge() {
        let full = PixelSize(width: 3024, height: 4032)
        #expect(ImagePipeline.decodeEdge(
            full: full, crop: PixelRect(full), target: PixelSize(width: 1050, height: 1400)) == 1400)
        #expect(ImagePipeline.decodeEdge(
            full: full, crop: PixelRect(x: 582, y: 0, width: 1860, height: 4032),
            target: PixelSize(width: 646, height: 1400)) == 1400)
        // The crop's long edge is the short side of the still: 4032 × 1400 / 3024 = 1866.7.
        #expect(ImagePipeline.decodeEdge(
            full: full, crop: PixelRect(x: 0, y: 1165, width: 3024, height: 1702),
            target: PixelSize(width: 1400, height: 788)) == 1867)
        // Nothing to shrink: decode whole, never larger.
        let small = PixelSize(width: 800, height: 600)
        #expect(ImagePipeline.decodeEdge(full: small, crop: PixelRect(small), target: small) == 800)
    }

    // MARK: Renditions

    @Test("sizes the full image and thumbnail from the cropped full-resolution source")
    func cropRenditionSizes() throws {
        // The crop keeps x 582…2442 of 3024 (see above).
        let image = try TestImages.make(width: 3024, height: 4032, blocks: [
            // Strips the crop must remove…
            .init(x: 0, y: 0, width: 570, height: 4032, color: .blue),
            .init(x: 2454, y: 0, width: 570, height: 4032, color: .blue),
            // …strips just inside it that must survive, and the centre.
            .init(x: 600, y: 0, width: 60, height: 4032, color: .red),
            .init(x: 2364, y: 0, width: 60, height: 4032, color: .red),
            .init(x: 1312, y: 1816, width: 400, height: 400, color: .red),
        ])
        let (full, thumb) = try ImagePipeline.photoRenditions(
            of: .data(TestImages.jpeg(image)), cropToAspect: CGSize(width: 393, height: 852))

        // scaleToFit(1860, 4032, 1400) and (…, 320).
        #expect(full.size == PixelSize(width: 646, height: 1400))
        #expect(thumb.size == PixelSize(width: 148, height: 320))
        for rendition in [full, thumb] {
            let decoded = try Inspect.image(rendition.data)
            #expect(decoded.width == rendition.size.width && decoded.height == rendition.size.height)
            #expect(try Inspect.pixel(decoded, fx: 0.5, fy: 0.5).isClose(to: .red, tolerance: 30))
            for fx in [0.026, 0.974] {
                #expect(try Inspect.pixel(decoded, fx: fx, fy: 0.25).isClose(to: .red, tolerance: 45))
            }
            for x in [0, decoded.width - 1] {
                #expect(try !Inspect.pixel(decoded, x: x, y: decoded.height / 4).isClose(to: .blue, tolerance: 60))
            }
            for fx in [0.25, 0.75] {
                #expect(try Inspect.pixel(decoded, fx: fx, fy: 0.25).isClose(to: .grey, tolerance: 20))
            }
        }
    }

    @Test("flattens transparency onto white and writes no alpha")
    func flattensTransparency() throws {
        let image = try TestImages.make(width: 200, height: 100, background: nil, blocks: [
            .init(x: 0, y: 0, width: 100, height: 100, color: .red),
        ])
        let png = try TestImages.encode(image, as: .png)
        #expect(try Inspect.properties(png)[kCGImagePropertyHasAlpha as String] as? Bool == true)

        let (full, thumb) = try ImagePipeline.photoRenditions(of: .data(png), cropToAspect: nil)
        for rendition in [full, thumb] {
            #expect(try Inspect.webPChunks(rendition.data) == ["VP8 "])
            let decoded = try Inspect.image(rendition.data)
            #expect(try Inspect.pixel(decoded, fx: 0.25, fy: 0.5).isClose(to: .red, tolerance: 8))
            #expect(try Inspect.pixel(decoded, fx: 0.75, fy: 0.5).isClose(to: .white, tolerance: 4))
        }
    }

    @Test("colour-matches a Display P3 capture into sRGB")
    func convertsDisplayP3() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: p3,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let color = try #require(CGColor(colorSpace: p3, components: [0.8, 0.3, 0.2, 1]))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try #require(context.makeImage())
        let expected = try #require(color.converted(to: srgb, intent: .defaultIntent, options: nil)?.components)
        let expectedRGB = RGB(
            r: Int((expected[0] * 255).rounded()), g: Int((expected[1] * 255).rounded()),
            b: Int((expected[2] * 255).rounded()))
        // The conversion is not a no-op: P3 values read as sRGB would be (204, 77, 51).
        #expect(!expectedRGB.isClose(to: RGB(r: 204, g: 77, b: 51), tolerance: 6))

        let (full, _) = try ImagePipeline.photoRenditions(
            of: .data(TestImages.encode(image, as: .png)), cropToAspect: nil)
        let decoded = try Inspect.image(full.data)
        #expect(try Inspect.pixel(decoded, x: 32, y: 32).isClose(to: expectedRGB, tolerance: 5))
    }

    @Test("bakes every EXIF orientation into the pixels", arguments: [
        (1, Inspect.Corner.topLeft, false),
        (2, Inspect.Corner.topRight, false),
        (3, Inspect.Corner.bottomRight, false),
        (4, Inspect.Corner.bottomLeft, false),
        (5, Inspect.Corner.topLeft, true),
        (6, Inspect.Corner.topRight, true),
        (7, Inspect.Corner.bottomRight, true),
        (8, Inspect.Corner.bottomLeft, true),
    ])
    func bakesOrientation(orientation: Int, corner: Inspect.Corner, transposed: Bool) throws {
        // Stored 2000×1500 with the marker in the stored top-left corner.
        let jpeg = try TestImages.jpeg(TestImages.marked(width: 2000, height: 1500), orientation: orientation)
        let (full, thumb) = try ImagePipeline.photoRenditions(of: .data(jpeg), cropToAspect: nil)

        #expect(full.size == (transposed ? PixelSize(width: 1050, height: 1400) : PixelSize(width: 1400, height: 1050)))
        #expect(thumb.size == (transposed ? PixelSize(width: 240, height: 320) : PixelSize(width: 320, height: 240)))
        for rendition in [full, thumb] {
            let decoded = try Inspect.image(rendition.data)
            #expect(try Inspect.redCorner(decoded) == corner)
            let properties = try Inspect.properties(rendition.data)
            #expect((properties[kCGImagePropertyOrientation as String] as? Int ?? 1) == 1)
        }
    }

    @Test("restored bytes get a thumbnail and keep their own size")
    func restoredThumbnail() throws {
        let jpeg = try TestImages.jpeg(TestImages.marked(width: 2000, height: 1500), orientation: 8)
        let (thumb, sourceSize) = try ImagePipeline.thumbnail(of: jpeg)

        #expect(sourceSize == PixelSize(width: 1500, height: 2000))
        #expect(thumb.size == PixelSize(width: 240, height: 320))
        #expect(try Inspect.redCorner(Inspect.image(thumb.data)) == .bottomLeft)
    }
}

@Suite("Image decoder")
struct ImageDecoderTests {
    @Test("decodes WebP photos and legacy JPEG photos alike")
    func decodesWebPAndJPEG() throws {
        let image = try TestImages.marked(width: 640, height: 480)
        let webp = try WebPEncoder.encode(WebPEncoderTests.bitmap(image), quality: 0.8)
        let jpeg = try TestImages.jpeg(image)

        for data in [webp, jpeg] {
            let decoded = try ImageDecoder.decode(data)
            #expect(decoded.width == 640 && decoded.height == 480)
            #expect(try Inspect.redCorner(decoded) == .topLeft)
        }
    }

    @Test("sniffs the bytes and ignores the file extension")
    func sniffsContent() throws {
        let container = try PhotoContainer()
        // A pre-WebP photo restored under a .webp name (03 §7.4).
        let url = try container.write(TestImages.jpeg(TestImages.marked(width: 300, height: 200)), to: "x.webp")
        let decoded = try ImageDecoder.decode(contentsOf: url)
        #expect(decoded.width == 300 && decoded.height == 200)
    }

    @Test("downsamples to a longest edge but never enlarges")
    func downsamples() throws {
        let jpeg = try TestImages.jpeg(TestImages.marked(width: 2000, height: 1000))
        let small = try ImageDecoder.decode(jpeg, maxPixelSize: 500)
        #expect(max(small.width, small.height) == 500)
        let same = try ImageDecoder.decode(jpeg, maxPixelSize: 5000)
        #expect(same.width == 2000 && same.height == 1000)
    }

    @Test("reads the upright size from the header")
    func uprightSize() throws {
        let image = try TestImages.marked(width: 400, height: 300)
        #expect(ImageDecoder.uprightSize(of: try TestImages.jpeg(image, orientation: 1)) == PixelSize(width: 400, height: 300))
        #expect(ImageDecoder.uprightSize(of: try TestImages.jpeg(image, orientation: 6)) == PixelSize(width: 300, height: 400))
        #expect(ImageDecoder.uprightSize(of: Data("not an image".utf8)) == nil)
    }

    @Test("rejects bytes that are not an image, and remote URLs")
    func rejectsGarbage() throws {
        #expect(throws: ImageStoreError.undecodable) { try ImageDecoder.decode(Data("not an image".utf8)) }
        #expect(throws: ImageStoreError.undecodable) { try ImageDecoder.decode(Data()) }
        let remote = try #require(URL(string: "https://example.com/photo.webp"))
        #expect(throws: ImageStoreError.undecodable) { try ImageDecoder.decode(contentsOf: remote) }
    }
}

/// A small deterministic generator for test noise.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
