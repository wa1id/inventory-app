import Foundation

/// Finds the file behind a photo URI stored in SQLite (DECISIONS D-4, 02 §3.3).
///
/// `item_photos.uri` and `thumb_uri` hold absolute `file://` URIs that include the app's data
/// container path, and that path changes on restore, device migration and possibly updates.
/// Rows restored from an Android backup carry Android paths. Every stored URI is therefore
/// resolved by file name under the current `Documents/item-photos/` (or
/// `Caches/household-photos/`) before anything checks, reads, shows or deletes it.
/// `r2:` and `http(s):` URIs are not local files.
public struct PhotoPathResolver: Sendable {
    /// The container's `Documents` directory.
    public let documents: URL
    /// The container's `Library/Caches` directory.
    public let caches: URL

    /// Directory of item photos: `Documents/item-photos` (RN: src/services/capture/imageStore.ts:28).
    public static let itemPhotosDirectoryName = "item-photos"
    /// Directory of the household photo cache: `Caches/household-photos`
    /// (RN: src/services/household/photoCache.ts:19).
    public static let householdPhotosDirectoryName = "household-photos"

    public init(documents: URL = .documentsDirectory, caches: URL = .cachesDirectory) {
        self.documents = documents
        self.caches = caches
    }

    /// `Documents/item-photos` in the current container.
    public var itemPhotosDirectory: URL {
        documents.appending(path: Self.itemPhotosDirectoryName, directoryHint: .isDirectory)
    }

    /// `Caches/household-photos` in the current container.
    public var householdPhotosDirectory: URL {
        caches.appending(path: Self.householdPhotosDirectoryName, directoryHint: .isDirectory)
    }

    /// A URL that exists on disk now, or nil when the URI is not a local file or the bytes are
    /// gone.
    ///
    /// The stored path is tried first (the common case, same container). Otherwise a file in an
    /// `item-photos` or `household-photos` directory is looked up by name in the current
    /// container's directory of that name, which covers a moved container, an Android path and
    /// the MVP-era `.jpg` files alike.
    public func resolve(_ stored: String?) -> URL? {
        // URL(string:) also decodes percent-escaped simulator paths into `.path`.
        guard let stored, let url = URL(string: stored), url.isFileURL else { return nil }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) { return url }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }
        let candidate: URL
        switch url.deletingLastPathComponent().lastPathComponent {
        case Self.itemPhotosDirectoryName:
            candidate = itemPhotosDirectory.appending(path: name, directoryHint: .notDirectory)
        case Self.householdPhotosDirectoryName:
            candidate = householdPhotosDirectory.appending(path: name, directoryHint: .notDirectory)
        default:
            return nil
        }
        return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// The URI to store for an item photo in the current container: the absolute `file://` URI
    /// RN wrote (shape 1, 02 §3.2), which Android and RN TestFlight builds also read.
    public func storedURI(forPhotoNamed name: String) -> String {
        itemPhotosDirectory.appending(path: name, directoryHint: .notDirectory).absoluteString
    }
}
