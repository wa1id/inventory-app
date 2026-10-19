import CoreGraphics
import Foundation

/// The photo-file operations the rest of the app depends on: capture and Quick Snap, photo sync
/// (upload, rehydrate after a restore), household upload and import, the Add draft and the delete
/// flows. ``ImageStore`` is the real one; tests swap in a fake, as the RN tests mock
/// `src/services/capture/imageStore` (for example `photoSync.test.ts`, whose fake keeps files as
/// a URI-to-bytes map).
///
/// The requirements mirror the RN module: `storeItemPhoto`, `writeStoredPhoto` and
/// `readStoredPhoto` are asynchronous there, `deleteStoredPhotos` and `hasRoomForPhoto` are not.
// RN: src/services/capture/imageStore.ts
public protocol PhotoStoring: Sendable {
    /// Normalises and stores a new photo with its thumbnail (RN `storeItemPhoto`).
    func storeItemPhoto(_ source: ImageSource, cropToAspect aspect: CGSize?) async throws -> StoredImage
    /// Writes restored bytes verbatim under a known id and rebuilds the thumbnail
    /// (RN `writeStoredPhoto`).
    func writeStoredPhoto(photoId: String, bytes: Data) async throws -> StoredImage
    /// A stored photo's bytes, or nil when the file is gone or the URI is not a local file
    /// (RN `readStoredPhoto`). An empty file is empty data, not nil.
    func readStoredPhoto(_ uri: String) async -> Data?
    /// Best-effort deletes; nil, empty and non-local URIs are skipped (RN `deleteStoredPhotos`).
    func deleteStoredPhotos(_ uris: [String?])
    /// Whether more than twice `estimatedBytes` is free (RN `hasRoomForPhoto`).
    func hasRoomForPhoto(estimatedBytes: Int64) -> Bool
}

extension PhotoStoring {
    /// ``storeItemPhoto(_:cropToAspect:)`` keeping the whole image, as RN always did.
    public func storeItemPhoto(_ source: ImageSource) async throws -> StoredImage {
        try await storeItemPhoto(source, cropToAspect: nil)
    }

    /// ``hasRoomForPhoto(estimatedBytes:)`` with RN's default estimate of one megabyte.
    // RN: src/services/capture/imageStore.ts:201
    public func hasRoomForPhoto() -> Bool {
        hasRoomForPhoto(estimatedBytes: 1_000_000)
    }
}

extension ImageStore: PhotoStoring {}
