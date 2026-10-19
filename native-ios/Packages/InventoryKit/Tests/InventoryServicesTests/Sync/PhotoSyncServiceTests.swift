import Foundation
import GRDB
import InventoryCore
import InventoryNetwork
import InventoryStorage
import InventoryTestSupport
import Testing
@testable import InventoryServices

// Ports src/services/sync/__tests__/photoSync.test.ts (the image store faked as a URI-to-bytes
// map, as the RN test mocks it), plus the U6 fixes B1, B2, B3, B4, B10 (image bytes) and B13.
// Photo ids are lowercase UUIDs, the only ids the Worker accepts (RN's tests used "photo-a").

/// Bytes that start like a JPEG, so the rehydration's image check lets them through.
private func jpegLike(_ tail: UInt8...) -> Data {
    Data([0xFF, 0xD8, 0xFF] + tail)
}

private struct SyncPhotoHarness {
    let inventory: SyncTestInventory
    let files = SyncFakePhotoStore()
    let worker = SyncFakeWorker()
    let telemetry = RecordingTelemetry()
    let service: PhotoSyncService

    init() async throws {
        inventory = try await SyncTestInventory.seeded()
        service = PhotoSyncService(store: inventory.store, photos: files, telemetry: telemetry.syncReporter)
    }

    var client: SyncClient { worker.client() }

    @discardableResult
    func addPhoto(
        _ id: String, synced: Bool = false, bytes: Data = Data([1, 2, 3]), createdAt: Int64 = epochMillis()
    ) async throws -> (uri: String, thumbUri: String) {
        try await inventory.addPhoto(id, synced: synced, files: files, bytes: bytes, createdAt: createdAt)
    }

    func pendingIds() async throws -> [String] {
        try await inventory.strings("SELECT id FROM item_photos WHERE remote_synced_at IS NULL ORDER BY created_at")
    }

    func tombstones() async throws -> [String] {
        try await inventory.strings("SELECT photo_id FROM sync_deletions")
    }

    func photoRow(_ id: String) async throws -> SyncTestInventory.PhotoColumns? {
        try await inventory.photoColumns(id)
    }
}

private let photoA = syncPhotoId(1)
private let photoB = syncPhotoId(2)

@Suite("photoSync uploadPendingPhotos")
struct SyncUploadPendingPhotosTests {
    @Test("uploads unsynced photos and marks them synced")
    func uploadsAndMarks() async throws {
        let harness = try await SyncPhotoHarness()
        try await harness.addPhoto(photoA)
        try await harness.addPhoto(photoB)

        let result = await harness.service.uploadPendingPhotos(client: harness.client)

        #expect(result == .init(uploaded: 2, interrupted: false))
        #expect(harness.worker.state.uploads.sorted() == [photoA, photoB])
        #expect(try await harness.pendingIds().isEmpty)
    }

    @Test("does not re-upload a photo already synced")
    func doesNotReupload() async throws {
        let harness = try await SyncPhotoHarness()
        try await harness.addPhoto(photoA, synced: true)

        _ = await harness.service.uploadPendingPhotos(client: harness.client)

        #expect(harness.worker.state.uploads.isEmpty)
    }

    @Test("drops a row whose local file has vanished rather than retrying forever")
    func dropsVanishedRow() async throws {
        let harness = try await SyncPhotoHarness()
        try await harness.addPhoto(photoA)
        harness.files.removeAll()

        let result = await harness.service.uploadPendingPhotos(client: harness.client)

        #expect(result.uploaded == 0)
        #expect(try await harness.inventory.count("item_photos") == 0)
        // Never uploaded, so no tombstone.
        #expect(try await harness.tombstones().isEmpty)
    }

    @Test("stops the pass when the service is unreachable, leaving work pending")
    func stopsWhenUnreachable() async throws {
        let harness = try await SyncPhotoHarness()
        try await harness.addPhoto(photoA)
        try await harness.addPhoto(photoB)
        harness.worker.update { $0.failUploads = .offline }

        let result = await harness.service.uploadPendingPhotos(client: harness.client)

        #expect(result == .init(uploaded: 0, interrupted: true))
        // Still pending, so the next pass picks them up.
        #expect(try await harness.pendingIds().count == 2)
    }

    @Test("the thumbnail of a vanished photo goes with its row")
    func dropsThumbnailToo() async throws {
        let harness = try await SyncPhotoHarness()
        let (uri, thumbUri) = try await harness.addPhoto(photoA)
        harness.files.set(nil, at: uri)

        _ = await harness.service.uploadPendingPhotos(client: harness.client)

        #expect(harness.files.files[thumbUri] == nil)
    }
}

@Suite("photoSync deletion tombstones")
struct SyncDeletionTombstoneTests {
    @Test("records a tombstone when a synced photo is deleted by cascade")
    func tombstoneOnCascade() async throws {
        let harness = try await SyncPhotoHarness()
        try await harness.addPhoto(photoA, synced: true)

        // Deleting the item cascades to item_photos, the case no repository deletes a photo row for.
        _ = try await harness.inventory.repos.items.delete(harness.inventory.itemId)

        #expect(try await harness.tombstones() == [photoA])
    }

    @Test("records no tombstone for a photo that was never uploaded")
    func noTombstoneWhenUnsynced() async throws {
        let harness = try await SyncPhotoHarness()
        try await harness.addPhoto(photoA)

        _ = try await harness.inventory.repos.items.delete(harness.inventory.itemId)

        #expect(try await harness.tombstones().isEmpty)
    }

    @Test("deletes remotely and clears the tombstone")
    func deletesRemotely() async throws {
        let harness = try await SyncPhotoHarness()
        try await harness.addPhoto(photoA, synced: true)
        harness.worker.update { $0.photos[photoA] = Data([1]) }
        _ = try await harness.inventory.repos.items.delete(harness.inventory.itemId)

        let result = await harness.service.processPhotoDeletions(client: harness.client)

        #expect(result == .init(deleted: 1, interrupted: false))
        #expect(harness.worker.state.photos[photoA] == nil)
        #expect(try await harness.tombstones().isEmpty)
    }

    @Test("keeps the tombstone when the delete could not be confirmed")
    func keepsTombstoneOnFailure() async throws {
        let harness = try await SyncPhotoHarness()
        try await harness.addPhoto(photoA, synced: true)
        _ = try await harness.inventory.repos.items.delete(harness.inventory.itemId)
        harness.worker.update { $0.failDeletes = .offline }

        let result = await harness.service.processPhotoDeletions(client: harness.client)

        #expect(result.interrupted)
        // A photo the user deleted must not stay stored just because the network was down.
        #expect(try await harness.tombstones().count == 1)
    }
}

@Suite("photoSync rehydrateMissingPhotos")
struct SyncRehydrateMissingPhotosTests {
    @Test("pulls back files that a restore left behind, re-pointing the row")
    func pullsBackAndRepoints() async throws {
        let harness = try await SyncPhotoHarness()
        let (originalUri, thumbUri) = try await harness.addPhoto(photoA, synced: true)
        let remote = jpegLike(7)
        harness.worker.update { $0.photos[photoA] = remote }
        // A restored database on a fresh install: the row survives, the file does not.
        harness.files.removeAll()

        let result = await harness.service.rehydrateMissingPhotos(client: harness.client)

        #expect(result == .init(restored: 1, interrupted: false))
        let row = try #require(try await harness.photoRow(photoA))
        #expect(row.byteSize == 4)
        #expect(harness.files.files[row.uri] == remote)
        // The fake writes into its one "current container", so re-pointing shows as equality;
        // SyncPhotoPathTests checks a real move.
        #expect(row.uri == originalUri)
        // The thumbnail is re-derived locally rather than fetched.
        #expect(row.thumbUri == thumbUri)
        #expect(harness.files.files[thumbUri] != nil)
    }

    @Test("leaves photos alone when the local file is present")
    func leavesPresentPhotos() async throws {
        let harness = try await SyncPhotoHarness()
        try await harness.addPhoto(photoA, synced: true)

        let result = await harness.service.rehydrateMissingPhotos(client: harness.client)

        #expect(result.restored == 0)
        #expect(harness.worker.state.downloads.isEmpty)
    }

    @Test("skips a photo missing remotely instead of stalling the pass")
    func skipsMissingRemotely() async throws {
        let harness = try await SyncPhotoHarness()
        try await harness.addPhoto(photoA, synced: true)
        try await harness.addPhoto(photoB, synced: true)
        harness.worker.update { $0.photos[photoB] = jpegLike(5) }
        harness.files.removeAll()

        let result = await harness.service.rehydrateMissingPhotos(client: harness.client)

        #expect(result == .init(restored: 1, interrupted: false))
    }

    @Test("a transient download failure stops the step")
    func transientFailureStops() async throws {
        let harness = try await SyncPhotoHarness()
        try await harness.addPhoto(photoA, synced: true)
        harness.files.removeAll()
        harness.worker.update { $0.failDownloads = .offline }

        let result = await harness.service.rehydrateMissingPhotos(client: harness.client)

        #expect(result == .init(restored: 0, interrupted: true))
    }
}

@Suite("photoSync syncPhotos")
struct SyncPhotosPassTests {
    @Test("reports a complete pass across all three directions")
    func completePass() async throws {
        let harness = try await SyncPhotoHarness()
        try await harness.addPhoto(photoA)

        let outcome = await harness.service.syncPhotos(client: harness.client)

        #expect(outcome == PhotoSyncOutcome(uploaded: 1, deleted: 0, restored: 0, interrupted: false))
        let event = try #require(harness.telemetry.events.first { $0.name == "photo_sync_pass" })
        #expect(event.payload["itemCount"] == .int(1))
        #expect(event.payload["outcome"] == .string("complete"))
        #expect(Set(event.payload.keys) == ["durationMs", "itemCount", "outcome"])
    }

    @Test("reports interruption when any direction could not finish")
    func interruptedPass() async throws {
        let harness = try await SyncPhotoHarness()
        try await harness.addPhoto(photoA)
        harness.worker.update { $0.failUploads = .offline }

        let outcome = await harness.service.syncPhotos(client: harness.client)

        #expect(outcome.interrupted)
        #expect(harness.telemetry.events.last?.payload["outcome"] == .string("interrupted"))
    }
}

@Suite("photoSync: rehydration reaches every missing photo (03 B1)")
struct SyncRehydrationCoverageTests {
    @Test("15 missing photos all come back across passes, not only the 10 newest")
    func fifteenPhotos() async throws {
        let harness = try await SyncPhotoHarness()
        let ids = (1...15).map(syncPhotoId)
        for (index, id) in ids.enumerated() {
            try await harness.addPhoto(id, synced: true, createdAt: Int64(1_000 + index))
        }
        harness.worker.update { state in
            for id in ids { state.photos[id] = jpegLike(1) }
        }
        harness.files.removeAll()

        let first = await harness.service.rehydrateMissingPhotos(client: harness.client)
        #expect(first == .init(restored: 10, interrupted: false))
        #expect(Set(harness.worker.state.downloads) == Set(ids.suffix(10)))

        // RN selected the same 10 newest rows again, found them present and stopped here.
        let second = await harness.service.rehydrateMissingPhotos(client: harness.client)
        #expect(second == .init(restored: 5, interrupted: false))
        for id in ids {
            #expect(harness.files.files[SyncFakePhotoStore.uri(id)] != nil)
        }

        let third = await harness.service.rehydrateMissingPhotos(client: harness.client)
        #expect(third == .init(restored: 0, interrupted: false))
        #expect(harness.worker.state.downloads.count == 15)
    }

    @Test("photos missing remotely do not keep older ones waiting")
    func notFoundDoesNotStall() async throws {
        let harness = try await SyncPhotoHarness()
        let ids = (1...12).map(syncPhotoId)
        for (index, id) in ids.enumerated() {
            try await harness.addPhoto(id, synced: true, createdAt: Int64(1_000 + index))
        }
        // Only the two oldest are stored remotely.
        harness.worker.update { state in
            for id in ids.prefix(2) { state.photos[id] = jpegLike(1) }
        }
        harness.files.removeAll()

        let first = await harness.service.rehydrateMissingPhotos(client: harness.client)
        #expect(first == .init(restored: 0, interrupted: false))

        let second = await harness.service.rehydrateMissingPhotos(client: harness.client)
        #expect(second == .init(restored: 2, interrupted: false))
        #expect(await harness.service.skippedRehydrationIds == Set(ids.suffix(10)))
    }

    @Test("a new account starts with a clean memory")
    func memoryIsPerAccount() async throws {
        let harness = try await SyncPhotoHarness()
        try await harness.addPhoto(photoA, synced: true)
        harness.files.removeAll()
        _ = await harness.service.rehydrateMissingPhotos(client: harness.client)
        #expect(await harness.service.skippedRehydrationIds == [photoA])

        await harness.service.prepare(forAccount: "one")
        #expect(await harness.service.skippedRehydrationIds.isEmpty)
        await harness.service.prepare(forAccount: "one")
        harness.worker.update { $0.photos[photoA] = jpegLike(1) }
        #expect(await harness.service.rehydrateMissingPhotos(client: harness.client).restored == 1)
    }
}

@Suite("photoSync: one bad photo never blocks the queue (03 B2)")
struct SyncUploadParkingTests {
    @Test("a photo the Worker answers 413 is parked and the photos behind it upload")
    func tooLargeIsParked() async throws {
        let harness = try await SyncPhotoHarness()
        let ids = (1...3).map(syncPhotoId)
        for (index, id) in ids.enumerated() { try await harness.addPhoto(id, createdAt: Int64(1_000 + index)) }
        harness.worker.update { $0.photoUploadReplies[ids[0]] = .json(413, #"{"error":"Upload is too large."}"#) }

        let first = await harness.service.uploadPendingPhotos(client: harness.client)
        #expect(first == .init(uploaded: 2, interrupted: false))
        #expect(try await harness.pendingIds() == [ids[0]])

        // Not tried again this session.
        let requestsBefore = harness.worker.server.requests.count
        let second = await harness.service.uploadPendingPhotos(client: harness.client)
        #expect(second == .init(uploaded: 0, interrupted: false))
        #expect(harness.worker.server.requests.count == requestsBefore)
    }

    @Test("a 0-byte file is never uploaded, never deleted, and never blocks")
    func emptyFileIsParked() async throws {
        let harness = try await SyncPhotoHarness()
        try await harness.addPhoto(photoA, bytes: Data(), createdAt: 1_000)
        try await harness.addPhoto(photoB, createdAt: 2_000)

        let result = await harness.service.uploadPendingPhotos(client: harness.client)

        #expect(result == .init(uploaded: 1, interrupted: false))
        #expect(harness.worker.state.uploads == [photoB])
        #expect(!harness.worker.requestLines.contains("PUT /v1/photos/\(photoA)"))
        // RN uploaded it, got 400 "Empty upload." and stopped there on every pass.
        #expect(try await harness.pendingIds() == [photoA])
    }

    @Test("an oversized file is parked without being sent")
    func oversizedIsParked() async throws {
        let harness = try await SyncPhotoHarness()
        try await harness.addPhoto(photoA, bytes: Data(count: SyncLimits.maxPhotoBytes + 1), createdAt: 1_000)
        try await harness.addPhoto(photoB, createdAt: 2_000)

        let result = await harness.service.uploadPendingPhotos(client: harness.client)

        #expect(result == .init(uploaded: 1, interrupted: false))
        #expect(harness.worker.server.requests.count == 1)
    }

    @Test("an id the Worker would refuse is never sent")
    func invalidIdIsParked() async throws {
        let harness = try await SyncPhotoHarness()
        try await harness.addPhoto("photo-a", createdAt: 1_000)
        try await harness.addPhoto(photoB, createdAt: 2_000)

        let result = await harness.service.uploadPendingPhotos(client: harness.client)

        #expect(result == .init(uploaded: 1, interrupted: false))
        #expect(harness.worker.state.uploads == [photoB])
        #expect(await harness.service.parkedUploadIds == ["photo-a"])
    }

    @Test("ten bad photos at the head of the queue hold it up for one pass at most")
    func tenBadPhotos() async throws {
        let harness = try await SyncPhotoHarness()
        let bad = (1...10).map(syncPhotoId)
        for (index, id) in bad.enumerated() { try await harness.addPhoto(id, bytes: Data(), createdAt: Int64(1_000 + index)) }
        let good = syncPhotoId(11)
        try await harness.addPhoto(good, createdAt: 5_000)

        #expect(await harness.service.uploadPendingPhotos(client: harness.client) == .init(uploaded: 0, interrupted: false))
        #expect(await harness.service.uploadPendingPhotos(client: harness.client) == .init(uploaded: 1, interrupted: false))
        #expect(harness.worker.state.uploads == [good])
    }

    @Test("a transient failure still stops the uploads")
    func transientStillStops() async throws {
        let harness = try await SyncPhotoHarness()
        try await harness.addPhoto(photoA, createdAt: 1_000)
        try await harness.addPhoto(photoB, createdAt: 2_000)
        harness.worker.update { $0.photoUploadReplies[photoA] = .json(507, #"{"error":"Storage limit reached for this account."}"#) }

        let result = await harness.service.uploadPendingPhotos(client: harness.client)

        #expect(result == .init(uploaded: 0, interrupted: true))
        #expect(await harness.service.parkedUploadIds.isEmpty)
    }
}

@Suite("photoSync: an undecodable or foreign download never aborts the pass (03 B3, B10)")
struct SyncRehydrationFailureTests {
    @Test("a photo that cannot be written back is skipped and the pass goes on")
    func writeFailureIsSkipped() async throws {
        let harness = try await SyncPhotoHarness()
        try await harness.addPhoto(photoA, synced: true, createdAt: 1_000)
        try await harness.addPhoto(photoB, synced: true, createdAt: 2_000)
        harness.worker.update {
            $0.photos[photoA] = jpegLike(1)
            $0.photos[photoB] = jpegLike(2)
        }
        harness.files.removeAll()
        harness.files.failWrites(for: photoB)

        let outcome = await harness.service.syncPhotos(client: harness.client)

        #expect(outcome == PhotoSyncOutcome(uploaded: 0, deleted: 0, restored: 1, interrupted: false))
        #expect(harness.files.files[SyncFakePhotoStore.uri(photoA)] != nil)

        // Not downloaded again this session.
        _ = await harness.service.rehydrateMissingPhotos(client: harness.client)
        #expect(harness.worker.state.downloads.filter { $0 == photoB }.count == 1)
    }

    @Test("a download that is not an image is never written")
    func htmlIsNeverWritten() async throws {
        let harness = try await SyncPhotoHarness()
        let (uri, _) = try await harness.addPhoto(photoA, synced: true)
        harness.files.removeAll()
        harness.worker.update { $0.photoReplies[photoA] = .text(200, "<html>Sign in to the Wi-Fi</html>", contentType: "text/html") }

        let result = await harness.service.rehydrateMissingPhotos(client: harness.client)

        #expect(result == .init(restored: 0, interrupted: false))
        #expect(harness.files.files.isEmpty)
        #expect(try await harness.photoRow(photoA)?.uri == uri)
    }
}

@Suite("photoSync: a row deleted mid-transfer (03 B13)", .timeLimit(.minutes(1)))
struct SyncUploadRaceTests {
    @Test("the remote copy of a photo deleted during its upload is deleted on the next pass")
    func deletedDuringUpload() async throws {
        let harness = try await SyncPhotoHarness()
        try await harness.addPhoto(photoA)
        let hold = harness.worker.hold("PUT", "/v1/photos/\(photoA)")

        let upload = Task { await harness.service.uploadPendingPhotos(client: harness.client) }
        await hold.arrived()
        try await harness.inventory.store.queue.write { db in
            try db.execute(sql: "DELETE FROM item_photos WHERE id = ?", arguments: [photoA])
        }
        // Unsynced when deleted, so the trigger left nothing.
        #expect(try await harness.tombstones().isEmpty)
        hold.release()

        #expect(await upload.value == .init(uploaded: 1, interrupted: false))
        #expect(try await harness.tombstones() == [photoA])

        _ = await harness.service.processPhotoDeletions(client: harness.client)
        #expect(harness.worker.state.photos[photoA] == nil)
        #expect(try await harness.tombstones().isEmpty)
    }

    @Test("a row deleted while its file downloads leaves no files behind")
    func deletedDuringRehydration() async throws {
        let harness = try await SyncPhotoHarness()
        try await harness.addPhoto(photoA, synced: true)
        harness.worker.update { $0.photos[photoA] = jpegLike(1) }
        harness.files.removeAll()
        let hold = harness.worker.hold("GET", "/v1/photos/\(photoA)")

        let rehydrating = Task { await harness.service.rehydrateMissingPhotos(client: harness.client) }
        await hold.arrived()
        _ = try await harness.inventory.repos.items.delete(harness.inventory.itemId)
        hold.release()

        #expect(await rehydrating.value == .init(restored: 0, interrupted: false))
        // RN wrote <id>.webp and its thumbnail for a row that no longer existed, for good.
        #expect(harness.files.files.isEmpty)
        // Synced when deleted: the trigger queued the remote copy's deletion.
        #expect(try await harness.tombstones() == [photoA])
    }
}

@Suite("photoSync: stored paths resolve into the current container (03 B4)")
struct SyncPhotoPathTests {
    /// A real image store in a throwaway container, and a service that resolves through it.
    private struct RealStoreHarness {
        let container: PhotoContainer
        let images: ImageStore
        let inventory: SyncTestInventory
        let worker = SyncFakeWorker()
        let service: PhotoSyncService

        init() async throws {
            container = try PhotoContainer()
            images = container.store()
            inventory = try await SyncTestInventory.seeded()
            service = PhotoSyncService(
                store: inventory.store, photos: images, resolver: images.resolver,
                telemetry: RecordingTelemetry().syncReporter)
        }

        /// Writes `data` as `item-photos/<name>` in the current container.
        @discardableResult
        func writePhotoFile(_ name: String, _ data: Data) throws -> URL {
            try container.write(data, to: "Documents/item-photos/\(name)")
        }
    }

    @Test("an unsynced photo stored under an old container path is uploaded, not deleted", arguments: [
        "file:///var/mobile/Containers/Data/Application/0A1B2C3D-0000-4000-8000-000000000000/Documents/item-photos/f1.webp",
        "file:///data/user/0/com.wystudio.inventory/files/item-photos/f1.webp",
    ])
    func staleContainerPath(storedUri: String) async throws {
        let harness = try await RealStoreHarness()
        let bytes = Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 photo".utf8)
        try harness.writePhotoFile("f1.webp", bytes)
        try await harness.inventory.addPhoto(photoA, uri: storedUri)

        let result = await harness.service.uploadPendingPhotos(client: harness.worker.client())

        #expect(result == .init(uploaded: 1, interrupted: false))
        #expect(try await harness.inventory.count("item_photos") == 1)
        #expect(harness.worker.state.photos[photoA] == bytes)
    }

    @Test("a photo file that exists but cannot be read keeps its row")
    func unreadableFileKeepsRow() async throws {
        let harness = try await RealStoreHarness()
        let file = try harness.writePhotoFile("f1.webp", Data([1, 2, 3]))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        try await harness.inventory.addPhoto(photoA, uri: harness.images.resolver.storedURI(forPhotoNamed: "f1.webp"))

        let result = await harness.service.uploadPendingPhotos(client: harness.worker.client())

        #expect(result == .init(uploaded: 0, interrupted: false))
        #expect(try await harness.inventory.count("item_photos") == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(harness.worker.server.requests.isEmpty)
    }

    @Test("a synced photo present under the current container is not downloaded again")
    func presentUnderCurrentContainer() async throws {
        let harness = try await RealStoreHarness()
        try harness.writePhotoFile("f1.webp", Data([1, 2, 3]))
        try await harness.inventory.addPhoto(
            photoA, synced: true,
            uri: "file:///var/mobile/Containers/Data/Application/OLD/Documents/item-photos/f1.webp")

        let result = await harness.service.rehydrateMissingPhotos(client: harness.worker.client())

        #expect(result.restored == 0)
        #expect(harness.worker.state.downloads.isEmpty)
    }

    @Test("rehydration writes into the current container and re-points the row there")
    func rehydratesIntoCurrentContainer() async throws {
        let harness = try await RealStoreHarness()
        let jpeg = try TestImages.jpeg(TestImages.make(width: 64, height: 48))
        try await harness.inventory.addPhoto(
            photoA, synced: true,
            uri: "file:///var/mobile/Containers/Data/Application/OLD/Documents/item-photos/f1.webp")
        harness.worker.update { $0.photos[photoA] = jpeg }

        let result = await harness.service.rehydrateMissingPhotos(client: harness.worker.client())

        #expect(result == .init(restored: 1, interrupted: false))
        let row = try #require(try await harness.inventory.photoColumns(photoA))
        #expect(row.uri == harness.images.resolver.storedURI(forPhotoNamed: "\(photoA).webp"))
        #expect(row.thumbUri == harness.images.resolver.storedURI(forPhotoNamed: "\(photoA)-thumb.webp"))
        #expect(row.byteSize == jpeg.count)
        #expect(harness.container.photoFiles() == ["\(photoA)-thumb.webp", "\(photoA).webp"])
    }
}
