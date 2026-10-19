import Foundation
import GRDB
import InventoryCore
import InventoryNetwork
import InventoryStorage

// RN: src/services/sync/photoSync.ts, 03 §7, with the U6 fixes for 03 B1-B4 and B13.
//
// The device stays authoritative for reading: a photo on disk is shown from disk, always.
// Remote copies exist to still be there when the disk is not. The queue state lives in the
// schema (`item_photos.remote_synced_at`, `sync_deletions` and its trigger); this service keeps
// only a per-process memory of photos it gave up on, so that none of them can block the rest.

/// One photo pass (RN `PhotoSyncOutcome`).
public struct PhotoSyncOutcome: Sendable, Equatable {
    public var uploaded: Int
    public var deleted: Int
    public var restored: Int
    /// True when a direction stopped early: offline, a timeout, quota, an unauthorized code.
    public var interrupted: Bool

    public init(uploaded: Int, deleted: Int, restored: Int, interrupted: Bool) {
        self.uploaded = uploaded
        self.deleted = deleted
        self.restored = restored
        self.interrupted = interrupted
    }
}

/// Moves photos between this device and the Worker: uploads, remote deletes and rehydration
/// after a restore (RN photoSync.ts).
///
/// Every step is bounded (10 per direction per pass, RN `BATCH_SIZE`), sequential, and holds no
/// transaction across a network call; a photo is marked synced only after the Worker confirmed
/// its bytes, so an interrupted pass repeats work rather than losing it. Nothing here throws.
///
/// Departures from RN, all of which RN would lose data or stall on (DECISIONS U6):
/// - **B1** Rehydration looks at every synced row whose file is missing, newest first, not at the
///   10 newest synced rows whatever their state; with the per-process memory below, every
///   missing photo is eventually fetched.
/// - **B2** A photo the Worker refuses on every try (empty, over 4 MiB, an id that is not a
///   lowercase UUID, or answered 413) is parked for the rest of the process and the pass moves
///   on; only transient failures stop the uploads. A 0-byte file is parked without a request
///   (RN uploaded it and got "Empty upload." forever).
/// - **B3** A download that cannot be decoded, or is not an image at all (B10), is skipped for
///   the rest of the process instead of aborting the pass and the backup behind it.
/// - **B4** Stored URIs go through ``PhotoPathResolver`` (via the photo store, and directly for
///   presence checks), and an unsynced row is deleted only when no file is found under the
///   current container either; a file that exists but cannot be read is left alone.
/// - **B13** A row deleted while its upload was in flight gets a tombstone, so the orphaned
///   remote copy is deleted on the next pass.
public actor PhotoSyncService {
    /// RN `BATCH_SIZE`: photos per direction per pass.
    public static let batchSize = 10

    /// RN `uploadPendingPhotos` result.
    public struct Uploads: Sendable, Equatable {
        public var uploaded: Int
        public var interrupted: Bool
        public init(uploaded: Int, interrupted: Bool) {
            self.uploaded = uploaded
            self.interrupted = interrupted
        }
    }

    /// RN `processPhotoDeletions` result.
    public struct Deletions: Sendable, Equatable {
        public var deleted: Int
        public var interrupted: Bool
        public init(deleted: Int, interrupted: Bool) {
            self.deleted = deleted
            self.interrupted = interrupted
        }
    }

    /// RN `rehydrateMissingPhotos` result.
    public struct Rehydrations: Sendable, Equatable {
        public var restored: Int
        public var interrupted: Bool
        public init(restored: Int, interrupted: Bool) {
            self.restored = restored
            self.interrupted = interrupted
        }
    }

    private struct PhotoRow: Sendable {
        let id: String
        let uri: String
        let thumbUri: String?
    }

    private let store: DatabaseStore
    private let photos: any PhotoStoring
    private let resolver: PhotoPathResolver?
    private let telemetry: TelemetryReporter
    private let now: @Sendable () -> Int64

    /// Unsynced photos the Worker will never accept, skipped until the process ends (B2).
    private var parkedUploads: Set<String> = []
    /// Synced photos that are gone remotely or could not be written back, skipped until the
    /// process ends (B1, B3).
    private var skippedRehydrations: Set<String> = []
    /// The account the memory above belongs to.
    private var memoryAccountID: String?

    /// - Parameters:
    ///   - store: the live database.
    ///   - photos: the photo files (``ImageStore`` in the app, a fake in tests).
    ///   - resolver: finds a stored URI's file in the current container; pass the image store's.
    ///     With it, presence checks stat the file instead of reading its bytes. Without it (tests
    ///     with an in-memory photo store), presence means `readStoredPhoto` returned bytes.
    ///   - telemetry: where `photo_sync_pass` goes.
    ///   - now: epoch milliseconds for `remote_synced_at`.
    public init(
        store: DatabaseStore,
        photos: any PhotoStoring,
        resolver: PhotoPathResolver? = nil,
        telemetry: TelemetryReporter = .shared,
        now: @escaping @Sendable () -> Int64 = { epochMillis() }
    ) {
        self.store = store
        self.photos = photos
        self.resolver = resolver
        self.telemetry = telemetry
        self.now = now
    }

    /// Forgets the parked and skipped photos when the account changes: another account may
    /// hold what this one did not.
    public func prepare(forAccount accountID: String) {
        guard memoryAccountID != accountID else { return }
        memoryAccountID = accountID
        forgetSkippedPhotos()
    }

    /// Forgets the parked and skipped photos (after a restore replaced the rows).
    public func forgetSkippedPhotos() {
        parkedUploads.removeAll()
        skippedRehydrations.removeAll()
    }

    /// Ids parked by the uploader in this process (B2).
    public var parkedUploadIds: Set<String> { parkedUploads }

    /// Ids the rehydration skips in this process (B1, B3).
    public var skippedRehydrationIds: Set<String> { skippedRehydrations }

    // MARK: Uploads

    /// RN `uploadPendingPhotos`: uploads up to `limit` photos with no confirmed remote copy,
    /// oldest first, skipping parked ones.
    ///
    /// A row whose file is gone (and not under the current container either) is deleted with
    /// its thumbnail and counts toward the limit, as in RN; no tombstone is created, because it
    /// was never uploaded. The first transient failure stops the step with the photo still pending.
    public func uploadPendingPhotos(client: SyncClient, limit: Int = PhotoSyncService.batchSize) async -> Uploads {
        let pending: [PhotoRow]
        do {
            pending = try await store.queue.read { db in
                try Self.rows(db, sql: """
                    SELECT id, uri, thumb_uri FROM item_photos
                     WHERE remote_synced_at IS NULL
                     ORDER BY created_at
                    """)
            }
        } catch {
            logDatabaseFailure(error)
            return Uploads(uploaded: 0, interrupted: true)
        }

        var uploaded = 0
        let batch = pending.filter { !parkedUploads.contains($0.id) }.prefix(limit)
        for photo in batch {
            guard let bytes = await photos.readStoredPhoto(photo.uri) else {
                if let resolver, resolver.resolve(photo.uri) != nil {
                    // The file is there but could not be read (B4): never delete its row.
                    park(photo.id, because: "unreadable")
                    continue
                }
                // The thumbnail is derived from bytes that no longer exist, so it goes with the row.
                photos.deleteStoredPhotos([photo.thumbUri])
                do {
                    try await store.queue.write { db in
                        try db.execute(sql: "DELETE FROM item_photos WHERE id = ?", arguments: [photo.id])
                    }
                } catch {
                    logDatabaseFailure(error)
                    return Uploads(uploaded: uploaded, interrupted: true)
                }
                continue
            }

            // Refusals the Worker would repeat on every pass (worker/src/index.ts:74-79, 436-451).
            if bytes.isEmpty {
                park(photo.id, because: "empty")
                continue
            }
            if bytes.count > SyncLimits.maxPhotoBytes {
                park(photo.id, because: "too_large")
                continue
            }
            if !SyncWorkerRules.isPhotoId(photo.id) {
                park(photo.id, because: "invalid_id")
                continue
            }

            switch await client.uploadPhoto(id: photo.id, bytes: bytes) {
            case .failure(.tooLarge):
                park(photo.id, because: "too_large")
                continue
            case .failure:
                // Offline, out of quota, or a code the Worker rejects: every remaining photo
                // would fail the same way, so stop rather than burn the battery.
                return Uploads(uploaded: uploaded, interrupted: true)
            case .success:
                break
            }

            let syncedAt = now()
            do {
                try await store.queue.write { db in
                    try db.execute(
                        sql: "UPDATE item_photos SET remote_synced_at = ? WHERE id = ?",
                        arguments: [syncedAt, photo.id])
                    if db.changesCount == 0 {
                        // Deleted while the upload was in flight (B13): the trigger saw an unsynced
                        // row and left no tombstone, so leave one for the copy just stored.
                        try db.execute(
                            sql: "INSERT OR REPLACE INTO sync_deletions (photo_id, deleted_at) VALUES (?, ?)",
                            arguments: [photo.id, syncedAt])
                    }
                }
            } catch {
                logDatabaseFailure(error)
                return Uploads(uploaded: uploaded, interrupted: true)
            }
            uploaded += 1
        }
        return Uploads(uploaded: uploaded, interrupted: false)
    }

    // MARK: Deletions

    /// RN `processPhotoDeletions`: deletes up to `limit` remote copies whose rows are gone,
    /// oldest tombstone first. A tombstone is removed only once the Worker confirmed the delete.
    public func processPhotoDeletions(client: SyncClient, limit: Int = PhotoSyncService.batchSize) async -> Deletions {
        let tombstones: [String]
        do {
            tombstones = try await store.queue.read { db in
                try String.fetchAll(
                    db, sql: "SELECT photo_id FROM sync_deletions ORDER BY deleted_at LIMIT ?", arguments: [limit])
            }
        } catch {
            logDatabaseFailure(error)
            return Deletions(deleted: 0, interrupted: true)
        }

        var deleted = 0
        for photoId in tombstones {
            guard case .success = await client.deletePhoto(id: photoId) else {
                return Deletions(deleted: deleted, interrupted: true)
            }
            do {
                try await store.queue.write { db in
                    try db.execute(sql: "DELETE FROM sync_deletions WHERE photo_id = ?", arguments: [photoId])
                }
            } catch {
                logDatabaseFailure(error)
                return Deletions(deleted: deleted, interrupted: true)
            }
            deleted += 1
        }
        return Deletions(deleted: deleted, interrupted: false)
    }

    // MARK: Rehydration

    /// RN `rehydrateMissingPhotos`: fetches back up to `limit` synced photos whose files are
    /// missing, newest first, and re-points each row at the file written in the current container.
    ///
    /// A photo the Worker does not have (404), bytes that are not an image, and bytes that cannot
    /// be decoded are skipped for the rest of the process; any other failure stops the step.
    public func rehydrateMissingPhotos(client: SyncClient, limit: Int = PhotoSyncService.batchSize) async -> Rehydrations {
        let synced: [PhotoRow]
        do {
            synced = try await store.queue.read { db in
                try Self.rows(db, sql: """
                    SELECT id, uri, thumb_uri FROM item_photos
                     WHERE remote_synced_at IS NOT NULL
                     ORDER BY created_at DESC
                    """)
            }
        } catch {
            logDatabaseFailure(error)
            return Rehydrations(restored: 0, interrupted: true)
        }

        var candidates: [PhotoRow] = []
        for photo in synced where !skippedRehydrations.contains(photo.id) {
            if candidates.count == limit { break }
            let present = await isPresent(photo.uri)
            if !present { candidates.append(photo) }
        }

        var restored = 0
        for photo in candidates {
            let bytes: Data
            switch await client.downloadPhoto(id: photo.id) {
            case .failure(.notFound):
                // Missing remotely: not recoverable, and not worth asking again this session.
                skippedRehydrations.insert(photo.id)
                continue
            case .failure:
                return Rehydrations(restored: restored, interrupted: true)
            case .success(let data):
                bytes = data
            }

            guard SyncWorkerRules.looksLikeImage(bytes) else {
                skippedRehydrations.insert(photo.id)
                InventoryLog.sync.info("Rehydration skipped a download that is not an image")
                continue
            }

            let stored: StoredImage
            do {
                stored = try await photos.writeStoredPhoto(photoId: photo.id, bytes: bytes)
            } catch {
                skippedRehydrations.insert(photo.id)
                InventoryLog.sync.info("Rehydration skipped a photo: \(errorClass(of: error), privacy: .public)")
                continue
            }

            do {
                try await store.queue.write { db in
                    try db.execute(
                        sql: "UPDATE item_photos SET uri = ?, thumb_uri = ?, byte_size = ? WHERE id = ?",
                        arguments: [stored.uri, stored.thumbUri, stored.byteSize, photo.id])
                }
            } catch {
                logDatabaseFailure(error)
                return Rehydrations(restored: restored, interrupted: true)
            }
            restored += 1
        }
        return Rehydrations(restored: restored, interrupted: false)
    }

    // MARK: Pass

    /// RN `syncPhotos`: uploads, then deletions, then rehydration, each even if an earlier one
    /// was interrupted. Logs `photo_sync_pass {durationMs, itemCount, outcome}`.
    public func syncPhotos(client: SyncClient) async -> PhotoSyncOutcome {
        let startedAt = ContinuousClock.now
        let uploads = await uploadPendingPhotos(client: client)
        let deletions = await processPhotoDeletions(client: client)
        let rehydrations = await rehydrateMissingPhotos(client: client)

        let outcome = PhotoSyncOutcome(
            uploaded: uploads.uploaded,
            deleted: deletions.deleted,
            restored: rehydrations.restored,
            interrupted: uploads.interrupted || deletions.interrupted || rehydrations.interrupted
        )
        telemetry.event("photo_sync_pass", [
            "durationMs": .int(SyncTiming.elapsedMilliseconds(since: startedAt)),
            "itemCount": .int(outcome.uploaded + outcome.deleted + outcome.restored),
            "outcome": .string(outcome.interrupted ? "interrupted" : "complete"),
        ])
        return outcome
    }

    // MARK: Internals

    /// Whether a stored URI's file is on disk now. A 0-byte file counts as present, as in RN.
    private func isPresent(_ uri: String) async -> Bool {
        if let resolver { return resolver.resolve(uri) != nil }
        return await photos.readStoredPhoto(uri) != nil
    }

    private func park(_ photoId: String, because reason: String) {
        parkedUploads.insert(photoId)
        InventoryLog.sync.info("Photo upload parked: \(reason, privacy: .public)")
    }

    private func logDatabaseFailure(_ error: any Error) {
        InventoryLog.sync.error("Photo sync stopped on a database error: \(errorClass(of: error), privacy: .public)")
    }

    private static func rows(_ db: Database, sql: String) throws -> [PhotoRow] {
        try Row.fetchAll(db, sql: sql).map { row in
            PhotoRow(id: row["id"], uri: row["uri"], thumbUri: row["thumb_uri"])
        }
    }
}
