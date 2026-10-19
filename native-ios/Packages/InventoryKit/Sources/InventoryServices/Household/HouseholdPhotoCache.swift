import Foundation
import InventoryNetwork
import InventoryStorage

/// Household photo bytes as local files (RN: src/services/household/photoCache.ts; 04 §8, 02 §3.4).
///
/// Household photos live in R2 behind the home server; screens want a `file://` URI. Files sit
/// in `Library/Caches/household-photos/` as `<photoId>.webp` and `<photoId>-thumb.webp`
/// whatever the bytes are, the directory and names the RN build used, so its cache is reused
/// as is. A photo id always names the same bytes (the server answers `immutable`), so a file on
/// disk is trusted without a network check, there is no eviction, and iOS may purge the
/// directory at any time.
///
/// Native differences, all harmless: files are written atomically (RN could leave a zero-byte
/// file behind and serve it forever), an empty file counts as missing, concurrent requests for
/// the same photo share one download, and a photo id that is not a plain file name is refused
/// rather than written outside the directory.
public actor HouseholdPhotoCache {
    /// Which of a photo's two files.
    public enum Kind: Sendable, Hashable {
        /// `<photoId>.webp`, the 1400 px image (`GET /v1/photos/:id`).
        case full
        /// `<photoId>-thumb.webp`, the 320 px list thumbnail (`GET /v1/photos/:id?thumb=1`).
        case thumb
    }

    private struct Key: Hashable {
        let photoId: String
        let kind: Kind
    }

    /// `Library/Caches/household-photos`.
    public nonisolated let directory: URL
    private let resolver: PhotoPathResolver
    private var inFlight: [Key: Task<String?, Never>] = [:]

    /// - Parameter resolver: where `Library/Caches` is (the cache directory) and how a local
    ///   capture's stored URI is found on disk (``remember(photoId:sourceURI:thumbURI:)``).
    public init(resolver: PhotoPathResolver = PhotoPathResolver()) {
        self.resolver = resolver
        directory = resolver.householdPhotosDirectory
    }

    /// The cache file for one of a photo's files, or nil when the id is not a plain file name.
    public nonisolated func fileURL(photoId: String, kind: Kind) -> URL? {
        guard Self.isPlainFileName(photoId) else { return nil }
        let name = switch kind {
        case .full: "\(photoId).webp"
        case .thumb: "\(photoId)-thumb.webp"
        }
        return directory.appending(path: name, directoryHint: .notDirectory)
    }

    /// The photo's local `file://` URI, downloading it first if needed; nil when it cannot be had
    /// (RN `resolveHouseholdPhoto`, photoCache.ts:11-41).
    ///
    /// A file already in the cache is returned without asking the server. Otherwise
    /// `GET /v1/photos/<photoId>` (`?thumb=1` for the thumbnail) with the session token and the
    /// default 20 s deadline, through `householdFetch`, so it reports reachability like any other
    /// request. Any non-2xx answer, a transport failure or a file error gives nil, and the caller
    /// keeps the server's `r2:` URI (the row shows its placeholder).
    ///
    /// The download is not tied to the caller's task: a list that goes away mid-download still
    /// leaves the file for next time.
    ///
    /// - Parameter client: a client for the current session (``HouseholdClient/forSession(_:)``).
    public func resolve(_ photoId: String, kind: Kind, client: HouseholdClient) async -> String? {
        guard let file = fileURL(photoId: photoId, kind: kind) else { return nil }
        if Self.hasBytes(at: file) { return file.absoluteString }
        let key = Key(photoId: photoId, kind: kind)
        if let running = inFlight[key] { return await running.value }
        let directory = directory
        let task = Task<String?, Never> {
            await Self.download(photoId: photoId, kind: kind, to: file, in: directory, client: client)
        }
        inFlight[key] = task
        let uri = await task.value
        inFlight[key] = nil
        return uri
    }

    /// After a local capture was posted to the household, keeps copies of its files under the
    /// server's photo id, so the item shows at once instead of downloading what this phone
    /// already has (RN `rememberHouseholdPhoto`, photoCache.ts:44-69).
    ///
    /// Each source is a stored photo URI, found through ``PhotoPathResolver``. A missing source
    /// is skipped, an existing cache file is replaced, and every error is ignored: display falls
    /// back to downloading. RN copied without waiting; this copies before returning.
    public func remember(photoId: String, sourceURI: String, thumbURI: String?) {
        guard let full = fileURL(photoId: photoId, kind: .full) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return
        }
        copyIfPresent(sourceURI, to: full)
        // RN `if (thumbUri)`: an empty string is no thumbnail.
        if let thumbURI, !thumbURI.isEmpty, let thumb = fileURL(photoId: photoId, kind: .thumb) {
            copyIfPresent(thumbURI, to: thumb)
        }
    }

    // MARK: - Helpers

    private func copyIfPresent(_ stored: String, to destination: URL) {
        guard let source = resolver.resolve(stored), let bytes = try? Data(contentsOf: source) else { return }
        try? bytes.write(to: destination, options: .atomic)
    }

    private static func download(
        photoId: String,
        kind: Kind,
        to file: URL,
        in directory: URL,
        client: HouseholdClient
    ) async -> String? {
        do {
            guard let bytes = try await client.photo(id: photoId, thumbnail: kind == .thumb) else { return nil }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bytes.write(to: file, options: .atomic)
            return file.absoluteString
        } catch {
            return nil
        }
    }

    /// A regular, non-empty file.
    private static func hasBytes(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber
        else { return false }
        return size.int64Value > 0
    }

    /// A single path component that cannot climb out of the directory.
    private static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}
