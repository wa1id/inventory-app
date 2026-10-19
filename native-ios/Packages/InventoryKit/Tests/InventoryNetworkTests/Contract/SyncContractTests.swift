import Foundation
import InventoryCore
import Testing
@testable import InventoryNetwork

// Every SyncClient call against answers recorded from worker/src/index.ts
// (Fixtures/generator/sync-contract.mts), with the requests checked against the
// headers src/services/sync/client.ts sends.

private func client(_ server: StubServer, contract: SyncContract, code: String? = nil, key: String?? = nil) -> SyncClient {
    SyncClient(
        recoveryCode: code ?? contract.code,
        endpoint: contract.origin,
        key: key ?? contract.appKey,
        transport: server.transport,
        telemetry: TelemetryRecorder().telemetry
    )
}

/// Runs `call` against a replay of the named exchanges; checks the requests unless told not to.
private func exchange<T>(
    _ names: String...,
    code: String? = nil,
    key: String?? = nil,
    checkRequests: Bool = true,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ call: (SyncClient) async throws -> T
) async throws -> T {
    let contract = try SyncContract.load()
    let recorded = try names.map(contract.exchange)
    let server = replay(recorded)
    let result = try await call(client(server, contract: contract, code: code, key: key))
    let sent = server.requests
    #expect(sent.count == recorded.count, "requests sent", sourceLocation: sourceLocation)
    if checkRequests {
        for (request, expected) in zip(sent, recorded) {
            expectRequest(request, matches: expected, sourceLocation: sourceLocation)
        }
    }
    return result
}

private func requestBody(_ name: String) throws -> Data {
    let base64 = try #require(try SyncContract.load().exchange(name).request.base64)
    return try #require(Data(base64Encoded: base64))
}

@Suite("Sync contract")
struct SyncContractTests {
    @Test("health needs no recovery code")
    func health() async throws {
        let health = try await exchange("health") { try await $0.health().get() }
        #expect(health == SyncHealth(ok: true, contractVersion: 1))
    }

    @Test("a missing or wrong app key, a missing or short code: all unauthorized")
    func credentialFailures() async throws {
        let contract = try SyncContract.load()
        let missingKey = try await exchange("missingKey", key: .some(nil)) { await $0.downloadPhoto(id: contract.photoId) }
        #expect(missingKey.failureReason == .unauthorized)
        let wrongKey = try await exchange("wrongKey", key: "nope") { await $0.downloadPhoto(id: contract.photoId) }
        #expect(wrongKey.failureReason == .unauthorized)
        let shortCodeHeader = try #require(try contract.exchange("shortCode").request.headers["Authorization"])
        let shortCode = String(shortCodeHeader.dropFirst("Bearer ".count))
        let short = try await exchange("shortCode", code: shortCode) { await $0.downloadPhoto(id: contract.photoId) }
        #expect(short.failureReason == .unauthorized)
        // The client always sends a code, so this one is checked for its answer only.
        let missingCode = try await exchange("missingCode", code: "", checkRequests: false) { await $0.downloadPhoto(id: contract.photoId) }
        #expect(missingCode.failureReason == .unauthorized)
    }

    @Test("stores a photo with its real type and reads the same bytes back")
    func photoRoundTrip() async throws {
        let contract = try SyncContract.load()
        let bytes = try requestBody("uploadPhoto")
        let (upload, download, missing) = try await exchange("uploadPhoto", "downloadPhoto", "downloadPhotoMissing") { sync in
            (
                await sync.uploadPhoto(id: contract.photoId, bytes: bytes),
                await sync.downloadPhoto(id: contract.photoId),
                await sync.downloadPhoto(id: "99999999-8888-4777-8666-555555555555")
            )
        }
        #expect(upload.failureReason == nil)
        #expect(try download.get() == bytes)
        #expect(missing.failureReason == .notFound)
        #expect(try contract.exchange("downloadPhoto").response.allHeaders["content-type"] == "image/webp")
    }

    @Test("an uppercase id and an empty body are server errors; an oversized photo is too large")
    func photoRefusals() async throws {
        let bytes = try requestBody("uploadPhoto")
        let upper = try await exchange("uploadPhotoUppercaseId") {
            await $0.uploadPhoto(id: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", bytes: bytes)
        }
        #expect(upper.failureReason == .serverError)
        let empty = try await exchange("uploadPhotoEmpty") {
            await $0.uploadPhoto(id: "99999999-8888-4777-8666-555555555555", bytes: Data())
        }
        #expect(empty.failureReason == .serverError)
        let oversized = Data(repeating: 0xFF, count: SyncLimits.maxPhotoBytes + 1)
        let large = try await exchange("uploadPhotoTooLarge", checkRequests: false) {
            await $0.uploadPhoto(id: "99999999-8888-4777-8666-555555555555", bytes: oversized)
        }
        #expect(large.failureReason == .tooLarge)
    }

    @Test("deleting a photo succeeds whether or not it is there")
    func deletePhoto() async throws {
        let contract = try SyncContract.load()
        let (first, second) = try await exchange("deletePhoto", "deletePhotoAgain") { sync in
            (await sync.deletePhoto(id: contract.photoId), await sync.deletePhoto(id: contract.photoId))
        }
        #expect(first.failureReason == nil)
        #expect(second.failureReason == nil)
    }

    @Test("a fresh account has no latest backup and an empty list")
    func noBackupsYet() async throws {
        let (latest, list) = try await exchange("latestWithoutBackups", "listWithoutBackups") { sync in
            (await sync.downloadBackup(), await sync.listBackups())
        }
        #expect(latest.failureReason == .notFound)
        #expect(try list.get() == [])
    }

    @Test("uploads snapshots, lists them newest first, and downloads them with their schema version")
    func backupRoundTrip() async throws {
        let contract = try SyncContract.load()
        let snapshot = try requestBody("uploadBackup")
        let checksum = try #require(try contract.exchange("uploadBackup").request.headers["x-snapshot-sha256"])
        let results = try await exchange("uploadBackup", "uploadOlderBackup", "listBackups", "downloadLatest", "downloadById") { sync in
            let first = try await sync.uploadBackup(snapshot, schemaVersion: 7, checksum: checksum).get()
            let second = try await sync.uploadBackup(snapshot, schemaVersion: 6, checksum: nil).get()
            let list = try await sync.listBackups().get()
            let latest = try await sync.downloadBackup().get()
            let byId = try await sync.downloadBackup(id: first.id).get()
            return (first, second, list, latest, byId)
        }
        let (first, second, list, latest, byId) = results
        #expect(first.schemaVersion == 7)
        #expect(first.size == snapshot.count)
        #expect(first.id == String(first.capturedAt))
        #expect(second.schemaVersion == 6)
        #expect(list == [second, first])
        #expect(latest == BackupDownload(bytes: snapshot, schemaVersion: 6))
        #expect(byId == BackupDownload(bytes: snapshot, schemaVersion: 7))
    }

    @Test("a checksum the bytes do not match is corrupted; a missing schema version is a server error")
    func backupRefusals() async throws {
        let snapshot = try requestBody("uploadBackup")
        let corrupted = try await exchange("uploadBackupBadChecksum") {
            await $0.uploadBackup(snapshot, schemaVersion: 7, checksum: String(repeating: "0", count: 64))
        }
        #expect(corrupted.failureReason == .corrupted)
        let noSchema = try await exchange("uploadBackupWithoutSchema", checkRequests: false) {
            await $0.uploadBackup(snapshot, schemaVersion: 7, checksum: nil)
        }
        #expect(noSchema.failureReason == .serverError)
    }

    @Test("a malformed backup id is a server error; an unknown one is not found")
    func backupIds() async throws {
        let (invalid, missing) = try await exchange("downloadInvalidId", "downloadMissingId") { sync in
            (await sync.downloadBackup(id: "yesterday"), await sync.downloadBackup(id: "1000000000000"))
        }
        #expect(invalid.failureReason == .serverError)
        #expect(missing.failureReason == .notFound)
    }

    @Test("reads usage, and a full account refuses with quota_exceeded")
    func usageAndQuota() async throws {
        let contract = try SyncContract.load()
        let usage = try await exchange("usage") { try await $0.usage().get() }
        #expect(usage == SyncUsage(bytes: 60, objects: 2, limitBytes: SyncLimits.maxAccountBytes))
        let fullHeader = try #require(try contract.exchange("quotaExceeded").request.headers["Authorization"])
        let fullCode = String(fullHeader.dropFirst("Bearer ".count))
        let bytes = try requestBody("uploadPhoto")
        let refused = try await exchange("quotaExceeded", code: fullCode) {
            await $0.uploadPhoto(id: contract.photoId, bytes: bytes)
        }
        #expect(refused.failureReason == .quotaExceeded)
    }

    @Test("statuses the client never provokes still classify as RN does")
    func otherStatuses() throws {
        let contract = try SyncContract.load()
        for name in ["photoMethodNotAllowed", "backupsMethodNotAllowed", "unknownRoute"] {
            let status = try contract.exchange(name).response.status
            #expect(SyncClient.classify(status: status) == (status == 404 ? .notFound : .serverError), "\(name)")
        }
    }
}
