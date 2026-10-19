import CoreImage
import Foundation
import InventoryAppModels
import InventoryCore
import SwiftUI
import Testing
import UIKit
@testable import Inventory

/// Decodes every QR code in `image` with CoreImage's detector.
private func mediaDecodeQR(_ image: CGImage) -> [String] {
    let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
    let features = detector?.features(in: CIImage(cgImage: image)) ?? []
    return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
}

/// Tokens with mixed, all-letter, all-digit and hashed hex.
private let mediaQrTokens = [
    "0123456789abcdef0123456789abcdef",
    "ffffffffffffffffffffffffffffffff",
    "00000000000000000000000000000000",
    "9f86d081884c7d659a2feaa0c55ad015",
]

/// The two error-correction bits of a QR symbol's format information (ISO/IEC 18004 §7.9: the
/// first copy around the top-left finder, XOR-masked with 0x5412), from a one-pixel-per-module image.
private func mediaCorrectionLevelBits(_ modules: CGImage) throws -> Int {
    let pixels = try #require(QrCodeRenderer.grayPixels(of: modules))
    func dark(column: Int, row: Int) -> Int { pixels[row * modules.width + column] < 128 ? 1 : 0 }
    var bits = 0
    for i in 0...5 { bits |= dark(column: 8, row: i) << i }
    bits |= dark(column: 8, row: 7) << 6
    bits |= dark(column: 8, row: 8) << 7
    bits |= dark(column: 7, row: 8) << 8
    for i in 9..<15 { bits |= dark(column: 14 - i, row: 8) << i }
    return ((bits ^ 0x5412) >> 13) & 0b11
}

@Suite("QR label rendering (07 §5)")
@MainActor
struct MediaQrRenderingTests {

    @Test("the share picture decodes to exactly inventory://c/<token>", arguments: mediaQrTokens)
    func pictureRoundTrip(token: String) throws {
        let payload = formatQrPayload(token)
        let picture = try #require(QrLabelPicture.render(payload: payload, cardSize: 252))
        #expect(mediaDecodeQR(picture) == [payload])
    }

    @Test("the on-screen code decodes too, at the narrowest card", arguments: mediaQrTokens)
    func cardRoundTrip(token: String) throws {
        let payload = formatQrPayload(token)
        let renderer = ImageRenderer(content: QrCodeImage(payload: payload, side: 152, quietZone: 16))
        renderer.scale = 3
        let image = try #require(renderer.cgImage)
        #expect(mediaDecodeQR(image) == [payload])
    }

    @Test("the symbol is encoded at error correction M (read back from its format bits)", arguments: mediaQrTokens)
    func correctionLevelM(token: String) throws {
        let modules = try #require(QrCodeRenderer.modules(for: formatQrPayload(token)))
        // Version 4 (33 modules) in byte mode; a token with long digit runs can fit version 3,
        // as RN's segment-optimising encoder also did (07 §5.1).
        #expect([29, 33].contains(modules.width))
        #expect(modules.height == modules.width)
        #expect(try mediaCorrectionLevelBits(modules) == 0b00, "M is 00 (L 01, Q 11, H 10)")
        #expect(QrCodeRenderer.correctionLevel == "M")
    }

    @Test("a token with no digit runs is version 4, 33 × 33 modules, as RN drew it")
    func versionFour() throws {
        let modules = try #require(QrCodeRenderer.modules(for: formatQrPayload("ffffffffffffffffffffffffffffffff")))
        #expect(modules.width == 33)
    }

    @Test("the generator's own margin is cut away: dark modules touch every edge")
    func trimmed() throws {
        let modules = try #require(QrCodeRenderer.modules(for: formatQrPayload(mediaQrTokens[0])))
        let box = try #require(QrCodeRenderer.darkBounds(of: modules))
        #expect(box == CGRect(x: 0, y: 0, width: modules.width, height: modules.height))
    }

    @Test(
        "the picture keeps the card's quiet zone: 16/size of 1024 px on each side",
        arguments: [252.0, 238.0, 152.0]
    )
    func pictureQuietZone(cardSize: Double) throws {
        let picture = try #require(QrLabelPicture.render(payload: formatQrPayload(mediaQrTokens[0]), cardSize: cardSize))
        #expect(picture.width == 1024)
        #expect(picture.height == 1024)
        let box = try #require(QrCodeRenderer.darkBounds(of: picture))
        let margin = Double(QrLabelGeometry.pictureMargin(cardSize: cardSize))
        #expect(abs(Double(box.minX) - margin) <= 1)
        #expect(abs(Double(box.minY) - margin) <= 1)
        #expect(abs(Double(1024 - box.maxX) - margin) <= 1)
        #expect(abs(Double(1024 - box.maxY) - margin) <= 1)
    }

    @Test("the card's code has a 16 pt white quiet zone around its modules")
    func cardQuietZone() throws {
        let renderer = ImageRenderer(content: QrCodeImage(payload: formatQrPayload(mediaQrTokens[0]), side: 252, quietZone: 16))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        #expect(image.width == 252)
        let box = try #require(QrCodeRenderer.darkBounds(of: image))
        #expect(abs(box.minX - 16) <= 1)
        #expect(abs(box.minY - 16) <= 1)
        #expect(abs(252 - box.maxX - 16) <= 1)
        #expect(abs(252 - box.maxY - 16) <= 1)
    }

    @Test("the share picture is a 1024 px PNG named label-<code>.png, replaced on every share")
    func pictureFile() throws {
        let directory = try mediaTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = formatQrPayload(mediaQrTokens[0])

        let url = try QrLabelPicture.write(payload: payload, shortCode: "CAB-J92R", cardSize: 252, in: directory)
        #expect(url.lastPathComponent == "label-CAB-J92R.png")
        let data = try Data(contentsOf: url)
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let image = try #require(UIImage(data: data)?.cgImage)
        #expect(image.width == 1024 && image.height == 1024)
        #expect(mediaDecodeQR(image) == [payload])

        let other = formatQrPayload(mediaQrTokens[1])
        let again = try QrLabelPicture.write(payload: other, shortCode: "CAB-J92R", cardSize: 252, in: directory)
        #expect(again == url)
        let replaced = try #require(UIImage(contentsOfFile: again.path(percentEncoded: false))?.cgImage)
        #expect(mediaDecodeQR(replaced) == [other])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) == ["label-CAB-J92R.png"])

        let blank = try QrLabelPicture.write(payload: payload, shortCode: "/ .", cardSize: 252, in: directory)
        #expect(blank.lastPathComponent == "label-label.png")
    }
}
