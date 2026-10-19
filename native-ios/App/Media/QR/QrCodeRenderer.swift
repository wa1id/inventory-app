import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// The QR symbol of a label payload, one pixel per module (07 §5.4).
///
/// CoreImage's generator with error correction **M**, the level RN's `react-native-qrcode-svg`
/// used by default; for the 46-byte `inventory://c/<token>` payload that is version 4, 33 × 33
/// modules. CoreImage draws its own white margin around the symbol, which is cut away here so the
/// views can add exactly RN's quiet zone (``QrLabelGeometry``, 07 Q6 parity).
enum QrCodeRenderer {
    /// RN `react-native-qrcode-svg` default `ecl` (`index.js:101`).
    static let correctionLevel = "M"

    private static let context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])

    /// The symbol's modules, dark on white, without any margin; nil if CoreImage cannot encode the
    /// payload.
    static func modules(for payload: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = correctionLevel
        guard let output = filter.outputImage,
              let image = context.createCGImage(output, from: output.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        else { return nil }
        return trimmed(image)
    }

    /// `image` cut to the box around its dark pixels. A QR symbol's finder patterns touch its top,
    /// left, right and bottom edges, so the box is the symbol, whatever margin was drawn around it.
    static func trimmed(_ image: CGImage) -> CGImage? {
        guard let box = darkBounds(of: image) else { return nil }
        return image.cropping(to: box)
    }

    /// The smallest rectangle holding every dark (below mid-grey) pixel, in pixel coordinates from
    /// the top-left; nil for an image with none.
    static func darkBounds(of image: CGImage) -> CGRect? {
        guard let pixels = grayPixels(of: image) else { return nil }
        let width = image.width
        let height = image.height
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] < 128 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The image drawn into an 8-bit grey buffer, row by row from the top.
    static func grayPixels(of image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
