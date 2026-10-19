import CoreGraphics
import Foundation

/// A photo stored in `Documents/item-photos/`, as the repositories record it in `item_photos`
/// (05 §9.2, §9.4).
// RN: src/services/capture/imageStore.ts:30-37
public struct StoredImage: Sendable, Hashable, Codable {
    /// Absolute `file://` URI of the full image, the shape RN writes and every platform reads
    /// (02 §3.2 shape 1). Resolve it with `PhotoPathResolver` before reading.
    public var uri: String
    /// Small copy for list rows. Always written alongside the full image.
    public var thumbUri: String
    /// Pixel width of the stored full image.
    public var width: Int
    /// Pixel height of the stored full image.
    public var height: Int
    /// Bytes of the stored full image. RN allows nil when the size could not be read.
    public var byteSize: Int?

    public init(uri: String, thumbUri: String, width: Int, height: Int, byteSize: Int?) {
        self.uri = uri
        self.thumbUri = thumbUri
        self.width = width
        self.height = height
        self.byteSize = byteSize
    }
}

/// Where a photo to store comes from.
public enum ImageSource: Sendable {
    /// Encoded bytes in any format ImageIO reads (HEIC, JPEG, PNG, WebP, …), for example
    /// `AVCapturePhoto.fileDataRepresentation()` or a photo-library import. The EXIF orientation
    /// is baked into the pixels.
    case data(Data)
    /// An encoded image file. The content is sniffed, never the extension. The caller keeps
    /// ownership of the file; the store does not delete it.
    case file(URL)
    /// Decoded pixels, already upright (no orientation is applied).
    case image(CGImage)
}

/// Why the image store could not do what was asked.
public enum ImageStoreError: Error, Sendable, Equatable {
    /// `storeItemPhoto` failed. Every cause maps to this one error, as in RN, whose message
    /// ("That photo could not be processed. Try again or continue without a photo.") is never
    /// shown: callers map the failure to their own copy.
    // RN: src/services/capture/imageStore.ts:127-133
    case couldNotProcess
    /// ImageIO could not read the bytes as an image.
    case undecodable
    /// The image has no pixels, or is larger than WebP allows (16 383 px a side).
    case unsupportedSize
    /// CoreGraphics could not draw the image.
    case renderingFailed
    /// libwebp refused to encode the pixels (`WebPEncodingError` raw value).
    case encodingFailed(code: Int)
    /// A photo id that is not a plain file name (it would write outside `item-photos`).
    case invalidPhotoId
}
