import CoreGraphics
import Foundation

/// One encoded WebP rendition and its exact pixel size.
struct EncodedRendition: Sendable {
    let data: Data
    let size: PixelSize
}

/// The pixel work behind the image store: decode once, crop, scale, flatten to opaque 8-bit sRGB
/// and encode WebP. Stateless; ``ImageStore`` runs it one photo at a time.
enum ImagePipeline {
    /// The full image and the thumbnail of a new photo (RN `storeItemPhoto` steps 1, 3 and 4).
    ///
    /// The source is decoded once and both renditions come from that one decode, the thumbnail
    /// included (not from the encoded full image). Sizes follow ``ImageScaling/scaleToFit(_:maxEdge:)``
    /// on the upright, cropped source at full resolution, so they match RN's to the pixel even
    /// though a large capture is downsampled while it is decoded.
    // RN: src/services/capture/imageStore.ts:100-111
    static func photoRenditions(
        of source: ImageSource,
        cropToAspect aspect: CGSize?
    ) throws -> (full: EncodedRendition, thumb: EncodedRendition) {
        let decoded = try ImageDecoder.decodeUpright(source) { full in
            let crop = cropRect(for: full, aspect: aspect)
            let target = ImageScaling.scaleToFit(crop.pixelSize, maxEdge: ImageScaling.maxImageDimension)
                ?? crop.pixelSize
            return decodeEdge(full: full, crop: crop, target: target)
        }
        let crop = cropRect(for: decoded.fullSize, aspect: aspect)
        let full = try rendition(
            of: decoded, crop: crop, maxEdge: ImageScaling.maxImageDimension, quality: ImageScaling.imageQuality)
        let thumb = try rendition(
            of: decoded, crop: crop, maxEdge: ImageScaling.thumbnailDimension, quality: ImageScaling.thumbnailQuality)
        return (full, thumb)
    }

    /// The thumbnail regenerated for restored bytes, and the upright size of those bytes
    /// (RN `writeStoredPhoto` steps 2-3). The full image itself is never re-encoded.
    // RN: src/services/capture/imageStore.ts:167-176
    static func thumbnail(of bytes: Data) throws -> (thumb: EncodedRendition, sourceSize: PixelSize) {
        let decoded = try ImageDecoder.decodeUpright(bytes) { full in
            let target = ImageScaling.scaleToFit(full, maxEdge: ImageScaling.thumbnailDimension) ?? full
            return decodeEdge(full: full, crop: PixelRect(full), target: target)
        }
        let thumb = try rendition(
            of: decoded, crop: PixelRect(decoded.fullSize),
            maxEdge: ImageScaling.thumbnailDimension, quality: ImageScaling.thumbnailQuality)
        return (thumb, decoded.fullSize)
    }

    /// Scales the `crop` area of `decoded` to fit `maxEdge` (never enlarging) and encodes it.
    static func rendition(
        of decoded: DecodedImage,
        crop: PixelRect,
        maxEdge: Int,
        quality: Double
    ) throws -> EncodedRendition {
        let size = ImageScaling.scaleToFit(crop.pixelSize, maxEdge: maxEdge) ?? crop.pixelSize
        let bitmap = try OpaqueBitmap.render(decoded, crop: crop, size: size)
        return EncodedRendition(data: try WebPEncoder.encode(bitmap, quality: quality), size: size)
    }

    /// The centred area of `size` with the proportions of `aspect`, as large as fits, rounded out
    /// to whole pixels. Nil, empty or non-finite aspects keep the whole image.
    ///
    /// This is the camera's crop to the preview (DECISIONS U7, 05 C4): expo-camera takes
    /// `AVMakeRect(aspectRatio:insideRect:)` of the still and crops with `CGImage.cropping(to:)`,
    /// which rounds the rectangle out with `CGRectIntegral`. Pass the aspect as it appears on
    /// screen; the crop is measured on the upright image, which gives the same rectangle as
    /// expo's in sensor space.
    // RN: node_modules/expo-camera/ios/Current/CameraPhotoCapture.swift:187-190
    static func cropRect(for size: PixelSize, aspect: CGSize?) -> PixelRect {
        let whole = PixelRect(size)
        guard let aspect, aspect.width > 0, aspect.height > 0, aspect.width.isFinite, aspect.height.isFinite
        else { return whole }
        let width = Double(size.width)
        let height = Double(size.height)
        let ratio = Double(aspect.width) / Double(aspect.height)
        // The edge that fills stays exact; only the other one is computed.
        let fitted = ratio > width / height
            ? CGSize(width: width, height: width / ratio)
            : CGSize(width: height * ratio, height: height)
        let rect = CGRect(
            x: (width - fitted.width) / 2, y: (height - fitted.height) / 2,
            width: fitted.width, height: fitted.height
        ).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return whole }
        return PixelRect(x: Int(rect.minX), y: Int(rect.minY), width: Int(rect.width), height: Int(rect.height))
    }

    /// The longer edge to decode `full` at, so that `crop` still has at least `target` pixels
    /// after downsampling. Never more than the source has.
    static func decodeEdge(full: PixelSize, crop: PixelRect, target: PixelSize) -> Int {
        let scale = Double(target.longestEdge) / Double(crop.pixelSize.longestEdge)
        let edge = (Double(full.longestEdge) * scale).rounded(.up)
        return min(full.longestEdge, max(1, Int(edge)))
    }
}

/// A rectangle in whole pixels, measured from the top-left of an upright image.
struct PixelRect: Sendable, Hashable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The whole of an image of `size`.
    init(_ size: PixelSize) {
        self.init(x: 0, y: 0, width: size.width, height: size.height)
    }

    var pixelSize: PixelSize { PixelSize(width: width, height: height) }
}

/// An opaque, 8-bit-per-channel sRGB bitmap (RGBX in memory): what libwebp encodes.
///
/// Expo rendered with `opaque = false` and encoded whatever colour space the capture had.
/// Native flattens to opaque sRGB over white instead (05 §9.2), because libwebp writes no colour
/// profile and every reader assumes sRGB; a Display P3 capture is colour-matched on the way.
struct OpaqueBitmap {
    let context: CGContext

    var width: Int { context.width }
    var height: Int { context.height }

    /// Draws the `crop` area of `decoded` (in full-resolution upright pixels) into a bitmap of
    /// exactly `size`, over white.
    static func render(_ decoded: DecodedImage, crop: PixelRect, size: PixelSize) throws -> OpaqueBitmap {
        guard size.width > 0, size.height > 0, crop.width > 0, crop.height > 0 else {
            throw ImageStoreError.unsupportedSize
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ImageStoreError.renderingFailed }

        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.interpolationQuality = .high

        // Stretch the decoded pixels over the full-resolution frame scaled to the target, offset
        // so that `crop` lands on the bitmap. CoreGraphics puts the origin at the bottom-left.
        let scaleX = Double(size.width) / Double(crop.width)
        let scaleY = Double(size.height) / Double(crop.height)
        let full = decoded.fullSize
        let frame = CGRect(
            x: -Double(crop.x) * scaleX,
            y: -Double(full.height - crop.y - crop.height) * scaleY,
            width: Double(full.width) * scaleX,
            height: Double(full.height) * scaleY
        )
        context.draw(decoded.image, in: frame)
        return OpaqueBitmap(context: context)
    }
}
