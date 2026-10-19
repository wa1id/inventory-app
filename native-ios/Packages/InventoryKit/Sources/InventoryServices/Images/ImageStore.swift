import CoreGraphics
import Foundation
import InventoryCore
import InventoryStorage

/// Item photos on disk: `Documents/item-photos/<id>.webp` and `<id>-thumb.webp` (05 §9, 02 §3).
///
/// Encoding runs inside this actor, one photo at a time, so a Quick Snap burst cannot exhaust
/// memory (05 §9.8 step 6; expo-camera serialises still processing for the same reason). Reads,
/// deletes and the free-space check touch no pixels and are `nonisolated`, so the shutter never
/// waits behind an encode.
///
/// Every stored URI is resolved through ``PhotoPathResolver`` before it is read or deleted,
/// because the URIs are absolute container paths that move (05 C1, DECISIONS D-4). Pass a
/// resolver rooted in a temporary container to keep tests away from the real `Documents`.
// RN: src/services/capture/imageStore.ts
public actor ImageStore {
    /// Where photos live and how stored URIs are found again.
    public nonisolated let resolver: PhotoPathResolver
    private nonisolated let freeSpace: @Sendable () throws -> Int64?
    private nonisolated let makePhotoId: @Sendable () -> String
    private nonisolated let telemetry: TelemetryReporter

    /// Image format and extension of every file this store writes (RN `IMAGE_EXTENSION`).
    public static let fileExtension = "webp"

    /// - Parameters:
    ///   - resolver: The container directories; the default is the app's own.
    ///   - freeSpace: Free bytes on the photo volume, nil when unknown. The default reads
    ///     `systemFreeSize` of `Documents`, as expo-file-system did.
    ///   - makePhotoId: The file name stem of a new photo. The default is ``InventoryCore/newId()``,
    ///     a lowercase v4 UUID.
    ///   - telemetry: Where `photo_stored` and `photo_store_failed` go, after the same allowlist
    ///     redaction as ``InventoryCore/Telemetry``. Nil (the default) logs through `Telemetry`;
    ///     tests pass their own sink so they neither depend on nor disturb the shared one.
    public init(
        resolver: PhotoPathResolver = PhotoPathResolver(),
        freeSpace: (@Sendable () throws -> Int64?)? = nil,
        makePhotoId: @escaping @Sendable () -> String = { newId() },
        telemetry: (any TelemetrySink)? = nil
    ) {
        self.resolver = resolver
        self.freeSpace = freeSpace ?? { [documents = resolver.documents] in
            try Self.systemFreeSize(of: documents)
        }
        self.makePhotoId = makePhotoId
        self.telemetry = TelemetryReporter(sink: telemetry)
    }

    /// The `cropToAspect` that keeps exactly what the camera preview showed (DECISIONS U7, 05 C4):
    /// the preview's size on screen, turned a quarter when the photo is turned a quarter from the
    /// preview.
    ///
    /// expo-camera measured the preview in sensor space, swapping its width and height when the
    /// interface was portrait, and cropped the still there before turning it upright
    /// (`CameraPhotoCapture.swift:159-167`). The native store crops the upright photo, so the same
    /// rectangle comes from swapping the preview size whenever the capture and preview rotations
    /// differ by a quarter turn. That is the case for an iPhone held sideways: the interface stays
    /// portrait, the photo is landscape, and it is stored at about 1400 × 646, as in RN (05 C4).
    ///
    /// - Parameters:
    ///   - previewSize: The preview layer's size in interface points.
    ///   - previewRotationAngle: The preview connection's rotation in degrees
    ///     (`RotationCoordinator.videoRotationAngleForHorizonLevelPreview`).
    ///   - captureRotationAngle: The photo connection's rotation in degrees for this shot
    ///     (`RotationCoordinator.videoRotationAngleForHorizonLevelCapture`).
    // RN: node_modules/expo-camera/ios/Current/CameraPhotoCapture.swift:159-167
    public static func previewCropAspect(
        previewSize: CGSize,
        previewRotationAngle: Double,
        captureRotationAngle: Double
    ) -> CGSize {
        let turns = ((captureRotationAngle - previewRotationAngle) / 90).rounded()
        guard turns.isFinite, turns.truncatingRemainder(dividingBy: 2) != 0 else { return previewSize }
        return CGSize(width: previewSize.height, height: previewSize.width)
    }

    // MARK: Writing

    /// Normalises a captured or imported photo and stores it with its thumbnail
    /// (RN `storeItemPhoto`, 05 §9.2).
    ///
    /// The source is decoded once, upright (EXIF orientation baked in), optionally cropped to
    /// `aspect` (the camera's crop to the preview, DECISIONS U7), scaled to fit 1400 px (thumbnail
    /// 320 px) without ever enlarging, flattened to opaque 8-bit sRGB and encoded as WebP at
    /// quality 0.8 (thumbnail 0.7). No EXIF, GPS or other metadata is written, so library imports
    /// lose their location. Every input is re-encoded, even a small one.
    ///
    /// The files are named by a fresh id, which is **not** the `item_photos` row id (02 §3.1),
    /// and written straight into `item-photos`; a failure leaves neither file behind (RN's
    /// un-awaited move could leave a row pointing at nothing, 02 §3.1).
    ///
    /// Logs `photo_stored {durationMs, byteSize}`, or `photo_store_failed {durationMs,
    /// errorClass}` and throws ``ImageStoreError/couldNotProcess`` whatever went wrong.
    ///
    /// - Parameters:
    ///   - source: The photo. A file stays where it is; the caller owns it.
    ///   - aspect: Width-to-height proportions of the centred area to keep, measured on the
    ///     upright photo; nil keeps the whole image. For the camera's crop to the preview, pass
    ///     ``previewCropAspect(previewSize:previewRotationAngle:captureRotationAngle:)``, not the
    ///     raw preview size: a photo taken with the phone held sideways is landscape while the
    ///     preview stays portrait.
    // RN: src/services/capture/imageStore.ts:100-134
    public func storeItemPhoto(_ source: ImageSource, cropToAspect aspect: CGSize?) throws -> StoredImage {
        let startedAt = ContinuousClock.now
        do {
            let stored = try store(source, cropToAspect: aspect)
            logEvent("photo_stored", [
                "durationMs": .int(Self.milliseconds(since: startedAt)),
                "byteSize": stored.byteSize.map(TelemetryValue.int) ?? .null,
            ])
            return stored
        } catch {
            logError("photo_store_failed", [
                "durationMs": .int(Self.milliseconds(since: startedAt)),
                "errorClass": .string(String(describing: type(of: error))),
            ])
            throw ImageStoreError.couldNotProcess
        }
    }

    /// Writes a photo's bytes back under a known id and rebuilds its thumbnail: the restore
    /// counterpart of ``storeItemPhoto(_:cropToAspect:)`` (RN `writeStoredPhoto`, 03 §7.4, 05 §9.3).
    ///
    /// The bytes are written **verbatim** to `<photoId>.webp`, replacing any file there; they may
    /// really be a legacy JPEG, which the decoder sniffs. The thumbnail is regenerated at 320 px,
    /// quality 0.7. The full image is never resized, so the width and height returned are the
    /// upright size of the bytes. Naming by id makes a re-run overwrite the same files.
    ///
    /// Errors propagate. As in RN, a decode failure leaves the full file written and no thumbnail.
    // RN: src/services/capture/imageStore.ts:161-178
    public func writeStoredPhoto(photoId: String, bytes: Data) throws -> StoredImage {
        guard Self.isPlainFileName(photoId) else { throw ImageStoreError.invalidPhotoId }
        let fullName = Self.fullName(photoId)
        let thumbName = Self.thumbName(photoId)
        let directory = try photoDirectory()

        try bytes.write(to: directory.appending(path: fullName, directoryHint: .notDirectory), options: .atomic)
        let (thumb, sourceSize) = try ImagePipeline.thumbnail(of: bytes)
        try thumb.data.write(to: directory.appending(path: thumbName, directoryHint: .notDirectory), options: .atomic)

        return StoredImage(
            uri: resolver.storedURI(forPhotoNamed: fullName),
            thumbUri: resolver.storedURI(forPhotoNamed: thumbName),
            width: sourceSize.width,
            height: sourceSize.height,
            byteSize: bytes.count
        )
    }

    // MARK: Reading and deleting

    /// A stored photo's bytes, or nil when the file is gone, the URI is not a local file
    /// (`r2:`, http) or the read fails (RN `readStoredPhoto`). An empty file returns empty data,
    /// not nil, as in RN.
    // RN: src/services/capture/imageStore.ts:137-145
    public nonisolated func readStoredPhoto(_ uri: String) -> Data? {
        guard let url = resolver.resolve(uri) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// A stored photo decoded upright for display, its longer edge at most `maxPixelSize`
    /// (nil for full size), or nil when it cannot be found or read. WebP and legacy JPEG alike.
    /// Runs off the caller's actor and does not queue behind photos being stored.
    @concurrent
    public nonisolated func loadStoredPhoto(_ uri: String?, maxPixelSize: Int? = nil) async -> CGImage? {
        guard let url = resolver.resolve(uri) else { return nil }
        return try? ImageDecoder.decode(contentsOf: url, maxPixelSize: maxPixelSize)
    }

    /// Deletes photo files whose rows are already gone (RN `deleteStoredPhotos`). Best effort:
    /// nil and empty values are skipped, URIs that are not local files (`r2:` from a household)
    /// are ignored, and errors are swallowed, because the rows are the source of truth.
    // RN: src/services/capture/imageStore.ts:188-198
    public nonisolated func deleteStoredPhotos(_ uris: [String?]) {
        for uri in uris {
            guard let uri, !uri.isEmpty, let url = resolver.resolve(uri) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Free space

    /// Whether there is room to store a photo: more than twice `estimatedBytes` free
    /// (RN `hasRoomForPhoto`, called before capture; issue #8).
    ///
    /// An unknown free size means no room, as JS `null > n` is false; a probe that throws means
    /// room, as RN's `catch` returns true (02 §3.1, 05 §9.3). ``PhotoStoring/hasRoomForPhoto()``
    /// supplies RN's default estimate of 1 000 000 bytes.
    // RN: src/services/capture/imageStore.ts:200-207
    public nonisolated func hasRoomForPhoto(estimatedBytes: Int64) -> Bool {
        do {
            guard let available = try freeSpace() else { return false }
            // Compared as doubles, like the JS numbers, so a huge estimate cannot overflow.
            return Double(available) > Double(estimatedBytes) * 2
        } catch {
            return true
        }
    }

    /// `systemFreeSize` of the volume holding `directory` (expo-file-system `availableDiskSpace`,
    /// node_modules/expo-file-system/ios/FileSystemModule.swift:29-35). Needs privacy reason E174.1.
    static func systemFreeSize(of directory: URL) throws -> Int64? {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        return (attributes[.systemFreeSize] as? NSNumber)?.int64Value
    }

    // MARK: Internals

    private nonisolated func logEvent(_ name: String, _ payload: TelemetryPayload) {
        telemetry.event(name, payload)
    }

    private nonisolated func logError(_ name: String, _ payload: TelemetryPayload) {
        telemetry.error(name, payload)
    }

    private func store(_ source: ImageSource, cropToAspect aspect: CGSize?) throws -> StoredImage {
        let (full, thumb) = try ImagePipeline.photoRenditions(of: source, cropToAspect: aspect)
        let photoId = makePhotoId()
        guard Self.isPlainFileName(photoId) else { throw ImageStoreError.invalidPhotoId }
        let fullName = Self.fullName(photoId)
        let thumbName = Self.thumbName(photoId)
        let directory = try photoDirectory()
        let fullURL = directory.appending(path: fullName, directoryHint: .notDirectory)

        // Written straight into item-photos, synchronously: no temporary file to move (05 §9.8).
        try full.data.write(to: fullURL, options: .atomic)
        do {
            try thumb.data.write(to: directory.appending(path: thumbName, directoryHint: .notDirectory), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: fullURL)
            throw error
        }

        return StoredImage(
            uri: resolver.storedURI(forPhotoNamed: fullName),
            thumbUri: resolver.storedURI(forPhotoNamed: thumbName),
            width: full.size.width,
            height: full.size.height,
            byteSize: full.data.count
        )
    }

    /// `Documents/item-photos`, created with its intermediates when missing.
    private func photoDirectory() throws -> URL {
        let directory = resolver.itemPhotosDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // RN: src/services/capture/imageStore.ts:47-53
    static func fullName(_ photoId: String) -> String { "\(photoId).\(fileExtension)" }
    static func thumbName(_ photoId: String) -> String { "\(photoId)-thumb.\(fileExtension)" }

    /// A single path component, so a name can never reach outside `item-photos`.
    static func isPlainFileName(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." && !id.contains("/") && !id.contains("\0")
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: .now).components
        return Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
    }
}
