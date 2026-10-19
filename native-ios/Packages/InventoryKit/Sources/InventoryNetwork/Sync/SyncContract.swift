import Foundation

// RN: src/services/sync/contract.ts, kept byte-compatible with worker/src/contract.ts.

/// RN `SYNC_CONTRACT_VERSION`.
public let syncContractVersion = 1

/// The Worker's limits and retention (worker/src/contract.ts).
public enum SyncLimits {
    /// Largest photo body the Worker stores (`MAX_PHOTO_BYTES`); checked server-side only.
    public static let maxPhotoBytes = 4 * 1024 * 1024
    /// Largest snapshot (`MAX_BACKUP_BYTES`); the backup service refuses a larger one before uploading.
    public static let maxBackupBytes = 32 * 1024 * 1024
    /// Total bytes an account may hold (`MAX_ACCOUNT_BYTES`).
    public static let maxAccountBytes: Int64 = 2 * 1024 * 1024 * 1024
    /// Snapshots kept per account, newest first (`BACKUP_RETENTION`).
    public static let backupRetention = 5
}

/// Why a sync call failed (RN `SyncFailureReason`). Every call resolves to a value; none throws.
public enum SyncFailureReason: String, Error, Sendable, Hashable, CaseIterable {
    case notConfigured = "not_configured"
    /// Part of the RN vocabulary; no code path produces it.
    case noAccount = "no_account"
    case offline
    case timeout
    case unauthorized
    case quotaExceeded = "quota_exceeded"
    case tooLarge = "too_large"
    case notFound = "not_found"
    case corrupted
    case serverError = "server_error"
    case malformedResponse = "malformed_response"
}

/// RN `SyncResult<T>`: `.success(value)` or `.failure(reason)`.
public typealias SyncResult<Value> = Result<Value, SyncFailureReason>

/// One stored snapshot (RN `BackupSummary`). `id` and `capturedAt` are server
/// time in epoch milliseconds, so a wrong phone clock cannot reorder backups.
public struct BackupSummary: Sendable, Hashable, Codable {
    public var id: String
    public var size: Int
    public var capturedAt: Int64
    /// The snapshot's `user_version`.
    public var schemaVersion: Int

    public init(id: String, size: Int, capturedAt: Int64, schemaVersion: Int) {
        self.id = id
        self.size = size
        self.capturedAt = capturedAt
        self.schemaVersion = schemaVersion
    }
}

/// A downloaded snapshot and the schema version it was written with.
public struct BackupDownload: Sendable, Equatable {
    public var bytes: Data
    /// RN `Number(header ?? '0')`: 0 when `x-snapshot-schema-version` is absent;
    /// nil where JS would get NaN or a fraction, which the restore must refuse (03 B10).
    public var schemaVersion: Int?

    public init(bytes: Data, schemaVersion: Int?) {
        self.bytes = bytes
        self.schemaVersion = schemaVersion
    }
}

/// `GET /v1/usage`: what the account holds against its limit.
public struct SyncUsage: Sendable, Hashable {
    public var bytes: Int64
    public var objects: Int
    public var limitBytes: Int64

    public init(bytes: Int64, objects: Int, limitBytes: Int64) {
        self.bytes = bytes
        self.objects = objects
        self.limitBytes = limitBytes
    }
}

/// `GET /v1/health`: `{ ok, contractVersion }`.
public struct SyncHealth: Sendable, Hashable, Decodable {
    public var ok: Bool
    public var contractVersion: Int

    public init(ok: Bool, contractVersion: Int) {
        self.ok = ok
        self.contractVersion = contractVersion
    }
}

/// RN `parseBackupList`: nil unless the body is `{ contractVersion: 1, backups: [BackupSummary] }`
/// with every element well typed.
public func parseBackupList(_ body: Data) -> [BackupSummary]? {
    guard let list = try? JSONDecoder().decode(BackupListBody.self, from: body),
          list.contractVersion == syncContractVersion
    else { return nil }
    return list.backups
}

private struct BackupListBody: Decodable {
    let contractVersion: Int
    let backups: [BackupSummary]
}

struct UsageBody: Decodable {
    let contractVersion: Int
    let bytes: Int64
    let objects: Int
    let limitBytes: Int64
}
