import Foundation
import InventoryCore
import InventoryTestSupport
import Testing
@testable import InventoryNetwork

// The sync Worker contract v1 (03 §4) as src/services/sync/client.ts speaks it.
// RN has no client-level tests (backup.test.ts and photoSync.test.ts use a fake
// client); these pin client.ts and worker/src/index.ts behaviour instead.

private let endpoint = "https://sync.example"
private let code = "MMWKYM2H78ABCDEFGHJKMNPQRS"
private let photoId = "11111111-2222-4333-8444-555555555555"
private let webp = Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 bytes".utf8)

/// The deadline runs on `clock`: by default one that never moves, so no exchange times out
/// because the test process was slow; the deadline tests move their own.
private func client(
    _ server: StubServer,
    endpoint: String? = endpoint,
    key: String? = nil,
    timeout: Duration = .seconds(5),
    clock: ManualClock = ManualClock(),
    telemetry: RecordingTelemetry = RecordingTelemetry()
) -> SyncClient {
    SyncClient(
        recoveryCode: code, endpoint: endpoint, key: key, timeout: timeout,
        transport: server.transport, clock: clock, telemetry: telemetry.telemetry
    )
}

@Suite("SyncClient requests")
struct SyncClientRequestTests {
    @Test("every request carries the bearer code and contract version, and the app key when set")
    func commonHeaders() async throws {
        let server = StubServer(reply: .status(204))
        _ = await client(server, key: "app-key").deletePhoto(id: photoId)
        let request = try #require(server.lastRequest)
        #expect(request.line == "DELETE https://sync.example/v1/photos/\(photoId)")
        #expect(request.header("authorization") == "Bearer \(code)")
        #expect(request.header("x-contract-version") == "1")
        #expect(request.header("x-inventory-key") == "app-key")
    }

    @Test("the app key is left out when it is missing or empty", arguments: [nil, ""] as [String?])
    func noKeyWhenUnset(key: String?) async throws {
        let server = StubServer(reply: .status(204))
        _ = await client(server, key: key).deletePhoto(id: photoId)
        #expect(try #require(server.lastRequest).header("x-inventory-key") == nil)
    }

    @Test("the code appears only in Authorization: never in the URL or the description")
    func codeStaysInTheHeader() async throws {
        let server = StubServer(reply: .bytes(200, Data([1])))
        let sync = client(server)
        _ = await sync.downloadPhoto(id: photoId)
        let request = try #require(server.lastRequest)
        #expect(!request.url.contains(code))
        #expect(!String(describing: sync).contains(code))
        #expect(!String(reflecting: sync).contains(code))
        var dumped = ""
        dump(sync, to: &dumped)
        #expect(!dumped.contains(code))
    }

    @Test("not configured: no request at all", arguments: [nil, ""] as [String?])
    func notConfigured(endpoint: String?) async {
        let server = StubServer(reply: .status(204))
        let sync = client(server, endpoint: endpoint)
        #expect(!sync.isConfigured)
        #expect(await sync.deletePhoto(id: photoId).failureReason == .notConfigured)
        #expect(await sync.downloadBackup().failureReason == .notConfigured)
        #expect(server.requests.isEmpty)
    }

    @Test("uploads a photo with its sniffed type and the raw bytes")
    func uploadsAPhoto() async throws {
        let server = StubServer(reply: .json(201, #"{"id":"\#(photoId)","size":21}"#))
        let telemetry = RecordingTelemetry()
        let result = await client(server, telemetry: telemetry).uploadPhoto(id: photoId, bytes: webp)
        #expect(result.failureReason == nil)
        let request = try #require(server.lastRequest)
        #expect(request.line == "PUT https://sync.example/v1/photos/\(photoId)")
        #expect(request.header("content-type") == "image/webp")
        #expect(request.body == webp)
        #expect(telemetry.entries.map(\.name) == ["photo_uploaded"])
        #expect(Set(telemetry.entries[0].payload.keys) == ["latencyMs", "byteSize"])
        #expect(telemetry.entries[0].payload["byteSize"] == .int(webp.count))
    }

    @Test("labels bytes it cannot recognise as image/jpeg, as RN always did")
    func unknownBytesAreJPEG() async throws {
        let server = StubServer(reply: .json(201, "{}"))
        _ = await client(server).uploadPhoto(id: photoId, bytes: Data([1, 2, 3]))
        #expect(try #require(server.lastRequest).header("content-type") == "image/jpeg")
    }

    @Test("a failed photo upload is logged with its reason")
    func failedUploadIsLogged() async throws {
        let server = StubServer(reply: .json(507, #"{"error":"Storage limit reached for this account."}"#))
        let telemetry = RecordingTelemetry()
        #expect(await client(server, telemetry: telemetry).uploadPhoto(id: photoId, bytes: webp).failureReason == .quotaExceeded)
        let entry = try #require(telemetry.entries.first)
        #expect(entry.level == "error" && entry.name == "photo_upload_failed")
        #expect(entry.payload["outcome"] == .string("quota_exceeded"))
        #expect(Set(entry.payload.keys) == ["outcome", "latencyMs", "byteSize"])
    }

    @Test("downloads a photo's bytes")
    func downloadsAPhoto() async throws {
        let server = StubServer(reply: .bytes(200, webp, headers: ["Content-Type": "image/webp"]))
        #expect(await client(server).downloadPhoto(id: photoId) == .success(webp))
        #expect(try #require(server.lastRequest).line == "GET https://sync.example/v1/photos/\(photoId)")
    }

    @Test("uploads a snapshot with its schema version and checksum, and decodes the summary")
    func uploadsABackup() async throws {
        let summary = #"{"id":"1767225600000","size":4,"capturedAt":1767225600000,"schemaVersion":7}"#
        let server = StubServer(reply: .json(201, summary))
        let telemetry = RecordingTelemetry()
        let checksum = String(repeating: "ab", count: 32)
        let result = await client(server, telemetry: telemetry).uploadBackup(Data([1, 2, 3, 4]), schemaVersion: 7, checksum: checksum)
        #expect(result == .success(BackupSummary(id: "1767225600000", size: 4, capturedAt: 1_767_225_600_000, schemaVersion: 7)))
        let request = try #require(server.lastRequest)
        #expect(request.line == "PUT https://sync.example/v1/backups")
        #expect(request.header("content-type") == "application/vnd.sqlite3")
        #expect(request.header("x-snapshot-schema-version") == "7")
        #expect(request.header("x-snapshot-sha256") == checksum)
        #expect(request.body == Data([1, 2, 3, 4]))
        #expect(telemetry.entries.map(\.name) == ["backup_uploaded"])
        #expect(Set(telemetry.entries[0].payload.keys) == ["latencyMs", "byteSize", "schemaVersion"])
    }

    @Test("leaves the checksum header out when there is none", arguments: [nil, ""] as [String?])
    func noChecksum(checksum: String?) async throws {
        let server = StubServer(reply: .json(201, #"{"id":"1","size":1,"capturedAt":1,"schemaVersion":7}"#))
        _ = await client(server).uploadBackup(Data([1]), schemaVersion: 7, checksum: checksum)
        #expect(try #require(server.lastRequest).header("x-snapshot-sha256") == nil)
    }

    @Test("a 201 body that is not a backup summary is malformed (B9), and is not logged as uploaded", arguments: [
        "{}", #"{"id":"1","size":4,"schemaVersion":7}"#, #"{"id":1,"size":4,"capturedAt":1,"schemaVersion":7}"#,
        #"{"id":"1","size":4,"capturedAt":"1","schemaVersion":7}"#, "not json", "",
    ])
    func malformedSummary(body: String) async {
        let server = StubServer(reply: .json(201, body))
        let telemetry = RecordingTelemetry()
        #expect(await client(server, telemetry: telemetry).uploadBackup(Data([1]), schemaVersion: 7, checksum: nil) == .failure(.malformedResponse))
        #expect(telemetry.entries.isEmpty)
    }

    @Test("a failed snapshot upload is logged with its schema version")
    func failedBackupIsLogged() async throws {
        let server = StubServer(reply: .json(422, #"{"error":"Snapshot failed its integrity check."}"#))
        let telemetry = RecordingTelemetry()
        #expect(await client(server, telemetry: telemetry).uploadBackup(Data([1]), schemaVersion: 7, checksum: nil) == .failure(.corrupted))
        let entry = try #require(telemetry.entries.first)
        #expect(entry.name == "backup_upload_failed")
        #expect(entry.payload["schemaVersion"] == .int(7))
        #expect(entry.payload["outcome"] == .string("corrupted"))
    }

    @Test("downloads the latest snapshot with the schema version it was written with")
    func downloadsTheLatestBackup() async throws {
        let server = StubServer(reply: .bytes(200, Data([9, 9]), headers: [
            "Content-Type": "application/vnd.sqlite3", "x-snapshot-schema-version": "6",
        ]))
        #expect(await client(server).downloadBackup() == .success(BackupDownload(bytes: Data([9, 9]), schemaVersion: 6)))
        #expect(try #require(server.lastRequest).line == "GET https://sync.example/v1/backups/latest")
    }

    @Test("reads the schema version header as JS Number() does", arguments: [
        (nil, 0), ("7", 7), (" 7 ", 7), ("", 0), ("0", 0), ("abc", nil), ("3.5", nil), ("7.0", 7),
    ] as [(String?, Int?)])
    func schemaVersionHeader(header: String?, expected: Int?) {
        #expect(SyncClient.schemaVersion(header: header) == expected)
    }

    @Test("downloads a snapshot by id")
    func downloadsByID() async throws {
        let server = StubServer(reply: .bytes(200, Data([1])))
        _ = await client(server).downloadBackup(id: "1767225600000")
        #expect(try #require(server.lastRequest).path == "/v1/backups/1767225600000")
    }

    @Test("lists backups when the body is a valid v1 list")
    func listsBackups() async throws {
        let body = #"{"contractVersion":1,"backups":[{"id":"2","size":2,"capturedAt":2,"schemaVersion":7},{"id":"1","size":1,"capturedAt":1,"schemaVersion":6}]}"#
        let server = StubServer(reply: .json(200, body))
        #expect(await client(server).listBackups() == .success([
            BackupSummary(id: "2", size: 2, capturedAt: 2, schemaVersion: 7),
            BackupSummary(id: "1", size: 1, capturedAt: 1, schemaVersion: 6),
        ]))
        #expect(try #require(server.lastRequest).line == "GET https://sync.example/v1/backups")
    }

    @Test("rejects a list it does not understand (parseBackupList)", arguments: [
        #"{"contractVersion":2,"backups":[]}"#,
        #"{"backups":[]}"#,
        #"{"contractVersion":1}"#,
        #"{"contractVersion":1,"backups":{}}"#,
        #"{"contractVersion":1,"backups":[{"id":"1","size":1,"capturedAt":1}]}"#,
        #"{"contractVersion":1,"backups":[{"id":1,"size":1,"capturedAt":1,"schemaVersion":1}]}"#,
        #"{"contractVersion":true,"backups":[]}"#,
        "[]", "null",
    ])
    func rejectsBadLists(body: String) async {
        #expect(parseBackupList(Data(body.utf8)) == nil)
        let server = StubServer(reply: .json(200, body))
        #expect(await client(server).listBackups() == .failure(.malformedResponse))
    }

    @Test("an empty list is a list")
    func emptyList() {
        #expect(parseBackupList(Data(#"{"contractVersion":1,"backups":[]}"#.utf8)) == [])
    }

    @Test("reads usage against the account limit")
    func readsUsage() async throws {
        let server = StubServer(reply: .json(200, #"{"contractVersion":1,"bytes":60,"objects":3,"limitBytes":2147483648}"#))
        #expect(await client(server).usage() == .success(SyncUsage(bytes: 60, objects: 3, limitBytes: SyncLimits.maxAccountBytes)))
        #expect(try #require(server.lastRequest).line == "GET https://sync.example/v1/usage")
    }

    @Test("checks health without sending the recovery code")
    func checksHealth() async throws {
        let server = StubServer(reply: .json(200, #"{"ok":true,"contractVersion":1}"#))
        #expect(await client(server, key: "k").health() == .success(SyncHealth(ok: true, contractVersion: 1)))
        let request = try #require(server.lastRequest)
        #expect(request.line == "GET https://sync.example/v1/health")
        #expect(request.header("authorization") == nil)
        #expect(request.header("x-inventory-key") == "k")
    }

    @Test("interpolates path ids without percent-encoding, as RN does")
    func pathsAreNotEncoded() async throws {
        let server = StubServer(reply: .status(204))
        _ = await client(server).deletePhoto(id: "a-b_c")
        #expect(try #require(server.lastRequest).path == "/v1/photos/a-b_c")
    }
}

@Suite("SyncClient failure classification")
struct SyncClientFailureTests {
    @Test("classifies statuses as RN classifyStatus does", arguments: [
        (401, SyncFailureReason.unauthorized), (403, .unauthorized), (404, .notFound), (413, .tooLarge),
        (422, .corrupted), (507, .quotaExceeded), (400, .serverError), (405, .serverError), (500, .serverError),
        (503, .serverError), (429, .serverError), (302, .serverError),
    ])
    func classifiesStatuses(status: Int, reason: SyncFailureReason) async {
        #expect(SyncClient.classify(status: status) == reason)
        if status != 302 {
            let server = StubServer(reply: .json(status, #"{"error":"x"}"#))
            #expect(await client(server).deletePhoto(id: photoId).failureReason == reason)
        }
    }

    @Test("the total deadline reads as timeout")
    func deadlineIsTimeout() async throws {
        let clock = ManualClock()
        // The Worker holds its answer for an hour: only the deadline ends the exchange.
        let server = StubServer(reply: .status(204, delay: .seconds(3600)))
        let sync = client(server, timeout: .milliseconds(100), clock: clock)
        let call = Task { await sync.deletePhoto(id: photoId) }
        try await clock.waitForSleepers(1, timeout: networkPatience)
        await server.waitForRequests(1)
        await clock.advance(by: .milliseconds(99))
        #expect(clock.pendingSleeperCount == 1)
        await clock.advance(by: .milliseconds(1))
        let outcome = try #require(await networkResult(of: call))
        #expect(outcome.get().failureReason == .timeout)
    }

    @Test("the deadline covers the whole body, not just the first byte")
    func deadlineCoversBody() async throws {
        // The 200 and its headers arrive at once; only the body is late (a slow 32 MiB snapshot download).
        let clock = ManualClock()
        let server = StubServer(reply: .slowBody(status: 200, headers: ["Content-Type": "application/octet-stream", "x-snapshot-schema-version": "7"], body: Data(count: 1024), bodyDelay: .seconds(3600)))
        let sync = client(server, timeout: .milliseconds(200), clock: clock)
        let call = Task { await sync.downloadBackup() }
        try await clock.waitForSleepers(1, timeout: networkPatience)
        await server.waitForHead()
        await clock.advance(by: .milliseconds(200))
        let outcome = try #require(await networkResult(of: call))
        #expect(outcome.get() == .failure(.timeout))
        // The same body in time is a download (the deadline's clock never moves here).
        let prompt = StubServer(reply: .slowBody(status: 200, headers: ["x-snapshot-schema-version": "7"], body: Data(count: 1024), bodyDelay: .milliseconds(10)))
        #expect(await client(prompt).downloadBackup() == .success(BackupDownload(bytes: Data(count: 1024), schemaVersion: 7)))
    }

    @Test("transport failures read as offline, URLSession's own timeout included (03 Q7)", arguments: [
        URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
        .dnsLookupFailed, .timedOut, .secureConnectionFailed, .serverCertificateUntrusted,
    ])
    func transportFailuresAreOffline(code: URLError.Code) async {
        let server = StubServer(reply: .failure(code, delay: nil))
        #expect(await client(server).deletePhoto(id: photoId).failureReason == .offline)
    }

    @Test("anything else thrown reads as server_error")
    func otherErrorsAreServerErrors() async {
        for error in [URLError(.badServerResponse), URLError(.cannotParseResponse)] as [any Error & Sendable] {
            let sync = SyncClient(
                recoveryCode: code, endpoint: endpoint, key: nil,
                transport: ThrowingTransport(error: error), telemetry: RecordingTelemetry().telemetry
            )
            #expect(await sync.deletePhoto(id: photoId).failureReason == .serverError)
        }
    }

    @Test("a cancelled caller reads as server_error, never as offline or timeout")
    func cancellationIsServerError() async {
        let server = StubServer(reply: .status(204, delay: .seconds(3600)))
        let sync = client(server)
        let task = Task { await sync.deletePhoto(id: photoId) }
        // Cancelled mid-exchange: the Worker has the request and holds its answer.
        await server.waitForRequests(1)
        task.cancel()
        #expect(await task.value.failureReason == .serverError)
    }
}

extension Result where Failure == SyncFailureReason {
    var failureReason: SyncFailureReason? {
        if case .failure(let reason) = self { return reason }
        return nil
    }
}

