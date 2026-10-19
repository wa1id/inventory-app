import CoreGraphics
import Foundation
import ImageIO
import InventoryCore
import InventoryTestSupport
import Testing
import UniformTypeIdentifiers
@testable import InventoryServices
import InventoryStorage

/// Fixtures in `Fixtures/images` (see the README there).
enum ImageFixtures {
    static func url(_ name: String) throws -> URL {
        let directory = try #require(Bundle.module.url(forResource: "images", withExtension: nil, subdirectory: "Fixtures"))
        return directory.appending(path: name)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }
}

/// A throwaway app data container, so no test touches the real `Documents`.
final class PhotoContainer: Sendable {
    private let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory(prefix: "image-store")
    }

    var root: URL { directory.root }
    var documents: URL { directory.documents }
    var caches: URL { directory.caches }
    var resolver: PhotoPathResolver { PhotoPathResolver(documents: documents, caches: caches) }
    var photoDirectory: URL { resolver.itemPhotosDirectory }

    /// A store rooted in this container. Telemetry goes to `telemetry`, never to the shared
    /// `Telemetry` sink, which other suites replace while they run.
    func store(
        freeSpace: (@Sendable () throws -> Int64?)? = nil,
        makePhotoId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        telemetry: RecordingTelemetry = RecordingTelemetry()
    ) -> ImageStore {
        ImageStore(resolver: resolver, freeSpace: freeSpace, makePhotoId: makePhotoId, telemetry: telemetry)
    }

    /// File names in `Documents/item-photos`, sorted.
    func photoFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: photoDirectory.path)) ?? []).sorted()
    }

    /// Writes `data` at `relativePath` under the container root.
    @discardableResult
    func write(_ data: Data, to relativePath: String) throws -> URL {
        try directory.write(data, to: relativePath)
    }
}

/// An sRGB colour in 0…255.
struct RGB: Sendable, Equatable, CustomStringConvertible {
    var r: Int, g: Int, b: Int

    static let grey = RGB(r: 128, g: 128, b: 128)
    static let red = RGB(r: 220, g: 30, b: 30)
    static let blue = RGB(r: 30, g: 40, b: 220)
    static let white = RGB(r: 255, g: 255, b: 255)

    var description: String { "(\(r), \(g), \(b))" }

    func isClose(to other: RGB, tolerance: Int) -> Bool {
        abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance && abs(b - other.b) <= tolerance
    }

    var cgColor: CGColor {
        CGColor(srgbRed: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: 1)
    }
}

/// Synthetic pictures and encoders built on ImageIO, the way a camera or the photo library
/// would hand them over.
enum TestImages {
    /// A rectangle measured from the top-left, filled with a colour.
    struct Block {
        var x: Int, y: Int, width: Int, height: Int
        var color: RGB
    }

    /// Stored pixels: `background` with `blocks` on top (sRGB, opaque unless `transparent`).
    static func make(
        width: Int,
        height: Int,
        background: RGB? = .grey,
        blocks: [Block] = [],
        space: CGColorSpace? = nil
    ) throws -> CGImage {
        let colorSpace = try space ?? #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        if let background {
            context.setFillColor(background.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        for block in blocks {
            context.setFillColor(block.color.cgColor)
            context.fill(CGRect(x: block.x, y: height - block.y - block.height, width: block.width, height: block.height))
        }
        return try #require(context.makeImage())
    }

    /// A picture with a red block in its stored top-left corner, a quarter of each side.
    static func marked(width: Int, height: Int) throws -> CGImage {
        try make(width: width, height: height, blocks: [
            Block(x: 0, y: 0, width: width / 4, height: height / 4, color: .red),
        ])
    }

    /// Encodes with ImageIO. `properties` go in as image metadata (orientation, GPS, EXIF).
    static func encode(_ image: CGImage, as type: UTType, properties: [CFString: Any] = [:]) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        var options = properties
        options[kCGImageDestinationLossyCompressionQuality] = 0.92
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func jpeg(_ image: CGImage, orientation: Int = 1) throws -> Data {
        try encode(image, as: .jpeg, properties: [kCGImagePropertyOrientation: orientation])
    }

    static var canEncodeHEIC: Bool {
        ((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []).contains(UTType.heic.identifier)
    }
}

/// Reads back what the store wrote.
enum Inspect {
    /// Decodes with ImageIO, as every reader of the photo files does.
    static func image(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    static func image(at url: URL) throws -> CGImage {
        try image(Data(contentsOf: url))
    }

    static func properties(_ data: Data) throws -> [String: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    static func typeIdentifier(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceGetType(source) as String?
    }

    /// The RIFF chunk ids of a WebP file, in order.
    static func webPChunks(_ data: Data) throws -> [String] {
        let bytes = [UInt8](data)
        try #require(bytes.count >= 12)
        try #require(String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF")
        try #require(String(decoding: bytes[8..<12], as: UTF8.self) == "WEBP")
        let riffSize = Int(littleEndian32(bytes, at: 4))
        try #require(riffSize + 8 == bytes.count, "RIFF size \(riffSize) for \(bytes.count) bytes")
        var chunks: [String] = []
        var offset = 12
        while offset + 8 <= bytes.count {
            chunks.append(String(decoding: bytes[offset..<offset + 4], as: UTF8.self))
            let size = Int(littleEndian32(bytes, at: offset + 4))
            offset += 8 + size + (size & 1)
        }
        return chunks
    }

    /// Width and height from the lossy `VP8 ` frame header, independently of ImageIO.
    static func vp8Size(_ data: Data) throws -> PixelSize {
        let bytes = [UInt8](data)
        try #require(bytes.count >= 30)
        try #require(String(decoding: bytes[12..<16], as: UTF8.self) == "VP8 ")
        // Chunk payload: 3-byte frame tag, start code 9d 01 2a, then 14-bit width and height.
        try #require(bytes[23] == 0x9D && bytes[24] == 0x01 && bytes[25] == 0x2A)
        let width = (Int(bytes[26]) | Int(bytes[27]) << 8) & 0x3FFF
        let height = (Int(bytes[28]) | Int(bytes[29]) << 8) & 0x3FFF
        return PixelSize(width: width, height: height)
    }

    private static func littleEndian32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    /// The sRGB colour of the pixel at (`x`, `y`), measured from the top-left.
    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> RGB {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var buffer = [UInt8](repeating: 0, count: 4)
        try buffer.withUnsafeMutableBytes { raw in
            let context = try #require(CGContext(
                data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        }
        return RGB(r: Int(buffer[0]), g: Int(buffer[1]), b: Int(buffer[2]))
    }

    /// Mean absolute difference per sRGB channel (0…255) between two images of the same size.
    static func meanError(_ a: CGImage, _ b: CGImage) throws -> Double {
        try #require(a.width == b.width && a.height == b.height)
        let pa = try rgbx(a), pb = try rgbx(b)
        var total = 0
        var count = 0
        for index in stride(from: 0, to: pa.count, by: 4) {
            for channel in 0..<3 {
                total += abs(Int(pa[index + channel]) - Int(pb[index + channel]))
                count += 1
            }
        }
        return Double(total) / Double(count)
    }

    /// The image's pixels as tightly packed sRGB RGBX bytes.
    static func rgbx(_ image: CGImage) throws -> [UInt8] {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try buffer.withUnsafeMutableBytes { raw in
            let context = try #require(CGContext(
                data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return buffer
    }

    /// The pixel at fractions of the width and height.
    static func pixel(_ image: CGImage, fx: Double, fy: Double) throws -> RGB {
        try pixel(
            image,
            x: min(image.width - 1, Int(Double(image.width) * fx)),
            y: min(image.height - 1, Int(Double(image.height) * fy)))
    }

    /// Which corner holds the red marker, or nil when none or several do.
    static func redCorner(_ image: CGImage) throws -> Corner? {
        var found: [Corner] = []
        for corner in Corner.allCases {
            let (fx, fy) = corner.sample
            let color = try pixel(image, fx: fx, fy: fy)
            if color.isClose(to: .red, tolerance: 40) { found.append(corner) }
        }
        return found.count == 1 ? found[0] : nil
    }

    enum Corner: String, CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight

        var sample: (Double, Double) {
            switch self {
            case .topLeft: (0.08, 0.08)
            case .topRight: (0.92, 0.08)
            case .bottomLeft: (0.08, 0.92)
            case .bottomRight: (0.92, 0.92)
            }
        }
    }
}

/// A lowercase RFC 4122 v4 UUID, as `newId()` makes.
func isLowercaseV4UUID(_ value: String) -> Bool {
    value.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/) != nil
}
