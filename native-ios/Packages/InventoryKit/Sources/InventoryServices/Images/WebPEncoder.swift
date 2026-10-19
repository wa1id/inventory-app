import CoreGraphics
import Foundation
internal import libwebp

/// Lossy WebP encoding through libwebp, because ImageIO decodes WebP but cannot encode it
/// (05 C3).
///
/// This is the encode Expo ran through `SDImageWebPCoder` (05 §9.8 step 4): the default preset at
/// `quality × 100`, YUV (not ARGB) for the lossy bitstream, one pass, no target size, RGB import.
/// The output is a simple-format file holding one `VP8 ` chunk: no `VP8X` header, so no EXIF,
/// XMP, ICC profile or GPS, and no alpha.
// RN: node_modules/expo-image-manipulator/ios/ImageManipulatorUtils.swift:79-80
enum WebPEncoder {
    /// Encodes an opaque sRGB bitmap. `quality` is 0…1, as in RN (`compress`).
    static func encode(_ bitmap: OpaqueBitmap, quality: Double) throws -> Data {
        let context = bitmap.context
        let maxDimension = Int(WEBP_MAX_DIMENSION)
        guard bitmap.width > 0, bitmap.height > 0, bitmap.width <= maxDimension, bitmap.height <= maxDimension else {
            throw ImageStoreError.unsupportedSize
        }
        // RGBX: 8-bit red, green, blue, then an ignored byte, in memory order.
        guard context.bitsPerComponent == 8, context.bitsPerPixel == 32, context.alphaInfo == .noneSkipLast,
              context.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue == 0,
              let pixels = context.data
        else { throw ImageStoreError.renderingFailed }

        var config = WebPConfig()
        guard WebPConfigPreset(&config, WEBP_PRESET_DEFAULT, Float(quality * 100)) != 0,
              WebPValidateConfig(&config) != 0
        else { throw ImageStoreError.encodingFailed(code: Int(VP8_ENC_ERROR_INVALID_CONFIGURATION.rawValue)) }

        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else {
            throw ImageStoreError.encodingFailed(code: Int(VP8_ENC_ERROR_INVALID_CONFIGURATION.rawValue))
        }
        defer { WebPPictureFree(&picture) }
        picture.use_argb = 0
        picture.width = Int32(bitmap.width)
        picture.height = Int32(bitmap.height)
        guard WebPPictureImportRGBX(
            &picture, pixels.assumingMemoryBound(to: UInt8.self), Int32(context.bytesPerRow)) != 0
        else { throw ImageStoreError.encodingFailed(code: Int(picture.error_code.rawValue)) }

        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }
        let encoded = withUnsafeMutablePointer(to: &writer) { output -> Int32 in
            picture.writer = WebPMemoryWrite
            picture.custom_ptr = UnsafeMutableRawPointer(output)
            defer { picture.custom_ptr = nil }
            return WebPEncode(&config, &picture)
        }
        guard encoded != 0, let bytes = writer.mem, writer.size > 0 else {
            throw ImageStoreError.encodingFailed(code: Int(picture.error_code.rawValue))
        }
        return Data(bytes: bytes, count: writer.size)
    }
}
