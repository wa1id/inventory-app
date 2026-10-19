import Foundation
import InventoryCore

/// HTTP client for the photo and backup Worker, contract v1 (RN: src/services/sync/client.ts).
///
/// Nothing here throws: every method resolves to a ``SyncResult``, because sync
/// is never what the user is doing and losing the network mid-backup must stay
/// invisible. The recovery code goes in the `Authorization` header and nowhere
/// else: never a URL, a log line or a telemetry payload, and not this type's
/// description either.
public struct SyncClient: Sendable {
    /// RN `EXPO_PUBLIC_SYNC_TIMEOUT_MS` default, applied to every call (03 Q6: parity).
    public static let defaultTimeout: Duration = .seconds(60)

    /// The Worker origin with no trailing slash; nil or empty means not configured.
    public let endpoint: String?
    private let recoveryCode: String
    private let key: String?
    public let timeout: Duration
    private let transport: any HTTPTransport
    private let clock: any Clock<Duration>
    private let telemetry: NetworkTelemetry

    /// - Parameters:
    ///   - recoveryCode: the stored 26-character code, sent as the bearer credential.
    ///   - key: the public app key sent as `x-inventory-key`; omitted when nil or empty.
    public init(
        recoveryCode: String,
        endpoint: String?,
        key: String?,
        timeout: Duration = SyncClient.defaultTimeout,
        transport: any HTTPTransport = URLSessionTransport.shared,
        clock: any Clock<Duration> = ContinuousClock(),
        telemetry: NetworkTelemetry = .standard
    ) {
        self.recoveryCode = recoveryCode
        self.endpoint = endpoint
        self.key = key
        self.timeout = timeout
        self.transport = transport
        self.clock = clock
        self.telemetry = telemetry
    }

    /// RN `configured`.
    public var isConfigured: Bool { !(endpoint ?? "").isEmpty }

    // MARK: - Endpoints

    /// `GET /v1/health`, which needs no credentials; the recovery code is not sent.
    public func health() async -> SyncResult<SyncHealth> {
        let result = await send("/v1/health", authorized: false)
        return result.flatMap { response in
            guard let health = try? JSONDecoder().decode(SyncHealth.self, from: response.body) else {
                return .failure(.malformedResponse)
            }
            return .success(health)
        }
    }

    /// `PUT /v1/photos/{id}` with the file bytes, labelled with their sniffed type (U6, 03 B5).
    ///
    /// - Parameter id: a lowercase UUID; the Worker answers 400 to anything else.
    public func uploadPhoto(id: String, bytes: Data) async -> SyncResult<Void> {
        let startedAt = ContinuousClock.now
        let result = await send(
            "/v1/photos/\(id)",
            method: "PUT",
            headers: ["Content-Type": ImageMediaType.sniff(bytes)],
            body: bytes
        )
        switch result {
        case .failure(let reason):
            telemetry.error("photo_upload_failed", [
                "outcome": .string(reason.rawValue),
                "latencyMs": .int(elapsedMilliseconds(since: startedAt)),
                "byteSize": .int(bytes.count),
            ])
            return .failure(reason)
        case .success:
            telemetry.event("photo_uploaded", [
                "latencyMs": .int(elapsedMilliseconds(since: startedAt)),
                "byteSize": .int(bytes.count),
            ])
            return .success(())
        }
    }

    /// `GET /v1/photos/{id}`: the stored bytes.
    public func downloadPhoto(id: String) async -> SyncResult<Data> {
        await send("/v1/photos/\(id)").map(\.body)
    }

    /// `DELETE /v1/photos/{id}`: 204 whether or not it existed.
    public func deletePhoto(id: String) async -> SyncResult<Void> {
        await send("/v1/photos/\(id)", method: "DELETE").map { _ in () }
    }

    /// `PUT /v1/backups` with a whole-database snapshot.
    ///
    /// The 201 body is decoded strictly; a body that is not a ``BackupSummary``
    /// is `malformed_response` (00-index §5, 03 B9) even though the bytes were stored.
    ///
    /// - Parameter checksum: 64 lowercase hex characters of SHA-256; the Worker has R2 verify it.
    public func uploadBackup(_ snapshot: Data, schemaVersion: Int, checksum: String?) async -> SyncResult<BackupSummary> {
        let startedAt = ContinuousClock.now
        var headers = [
            "Content-Type": "application/vnd.sqlite3",
            "x-snapshot-schema-version": String(schemaVersion),
        ]
        if let checksum, !checksum.isEmpty { headers["x-snapshot-sha256"] = checksum }
        let result = await send("/v1/backups", method: "PUT", headers: headers, body: snapshot)

        switch result {
        case .failure(let reason):
            telemetry.error("backup_upload_failed", [
                "outcome": .string(reason.rawValue),
                "latencyMs": .int(elapsedMilliseconds(since: startedAt)),
                "byteSize": .int(snapshot.count),
                "schemaVersion": .int(schemaVersion),
            ])
            return .failure(reason)
        case .success(let response):
            // RN logs nothing when the body does not parse.
            guard let summary = try? JSONDecoder().decode(BackupSummary.self, from: response.body) else {
                return .failure(.malformedResponse)
            }
            telemetry.event("backup_uploaded", [
                "latencyMs": .int(elapsedMilliseconds(since: startedAt)),
                "byteSize": .int(snapshot.count),
                "schemaVersion": .int(schemaVersion),
            ])
            return .success(summary)
        }
    }

    /// `GET /v1/backups`: the account's snapshots, newest first.
    public func listBackups() async -> SyncResult<[BackupSummary]> {
        await send("/v1/backups").flatMap { response in
            guard let backups = parseBackupList(response.body) else { return .failure(.malformedResponse) }
            return .success(backups)
        }
    }

    /// `GET /v1/backups/{id}`: a snapshot's bytes and the schema version it was written with.
    ///
    /// The version travels with the bytes so the restore can refuse a snapshot
    /// from a newer build instead of migrating backwards out of it.
    public func downloadBackup(id: String = "latest") async -> SyncResult<BackupDownload> {
        await send("/v1/backups/\(id)").map { response in
            BackupDownload(
                bytes: response.body,
                schemaVersion: Self.schemaVersion(header: response.header("x-snapshot-schema-version"))
            )
        }
    }

    /// `GET /v1/usage`: bytes and objects held against the account limit.
    public func usage() async -> SyncResult<SyncUsage> {
        await send("/v1/usage").flatMap { response in
            guard let body = try? JSONDecoder().decode(UsageBody.self, from: response.body),
                  body.contractVersion == syncContractVersion
            else { return .failure(.malformedResponse) }
            return .success(SyncUsage(bytes: body.bytes, objects: body.objects, limitBytes: body.limitBytes))
        }
    }

    // MARK: - Transport

    /// RN `send()`: common headers, the total deadline, status classification.
    /// Path parameters are interpolated without percent-encoding, as in RN.
    private func send(
        _ path: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        authorized: Bool = true
    ) async -> SyncResult<HTTPResponse> {
        guard let endpoint, !endpoint.isEmpty else { return .failure(.notConfigured) }
        do {
            let response = try await withTotalTimeout(timeout, clock: clock) { [self] in
                guard let url = URL(string: endpoint + path) else { throw URLError(.badURL) }
                var request = URLRequest(url: url, method: method, deadline: timeout)
                if authorized {
                    request.setValue("Bearer \(recoveryCode)", forHTTPHeaderField: "Authorization")
                }
                request.setValue(String(syncContractVersion), forHTTPHeaderField: "X-Contract-Version")
                if let key, !key.isEmpty {
                    request.setValue(key, forHTTPHeaderField: "x-inventory-key")
                }
                // Per-call headers are merged last, so they win.
                for (name, value) in headers {
                    request.setValue(value, forHTTPHeaderField: name)
                }
                request.httpBody = body
                return try await transport.send(request)
            }
            guard response.isSuccess else { return .failure(Self.classify(status: response.status)) }
            return .success(response)
        } catch {
            return .failure(Self.classify(error))
        }
    }

    /// RN `classifyStatus`.
    static func classify(status: Int) -> SyncFailureReason {
        switch status {
        case 401, 403: .unauthorized
        case 404: .notFound
        case 413: .tooLarge
        case 422: .corrupted
        case 507: .quotaExceeded
        default: .serverError
        }
    }

    /// RN `classifyError`: our deadline is `timeout`, a transport failure is `offline`, anything else `server_error`.
    static func classify(_ error: any Error) -> SyncFailureReason {
        switch TransportFailure.classify(error) {
        case .deadline: .timeout
        case .offline: .offline
        case .cancelled, .other: .serverError
        }
    }

    /// RN `Number(header ?? '0')`, kept only when it is an integer.
    static func schemaVersion(header: String?) -> Int? {
        guard let header else { return 0 }
        guard let value = jsNumber(header.jsTrimmed()), value.isFinite, value.rounded(.towardZero) == value else {
            return nil
        }
        return Int(exactly: value)
    }
}

extension SyncClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Leaves the recovery code out of `print`, `dump` and string interpolation.
    public var description: String { "SyncClient(endpoint: \(endpoint ?? "nil"))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["endpoint": endpoint as Any, "timeout": timeout], displayStyle: .struct)
    }
}
