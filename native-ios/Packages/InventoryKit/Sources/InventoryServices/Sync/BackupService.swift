import CryptoKit
import Foundation
import GRDB
import InventoryCore
import InventoryNetwork
import InventoryStorage

// RN: src/services/sync/backup.ts (runBackup, maybeBackup, lastBackupAt), 03 §5.

/// What one backup attempt came to.
public enum BackupRunOutcome: Sendable, Equatable {
    /// The Worker stored the snapshot; `capturedAt` (server time) is now the `lastBackupAt` marker.
    case uploaded(BackupSummary)
    /// Nothing was stored (RN `{status: 'failed', reason}`); the marker is unchanged.
    case failed(SyncFailureReason)
    /// Not uploaded on purpose: this phone's database holds nothing but the seeded drop zone,
    /// and the account already has backups on the server (03 B12, DECISIONS U6). Uploading
    /// would make an empty inventory the newest backup, and five of those would prune the real
    /// ones. Offer Restore instead.
    case heldBack
}

/// Snapshots the inventory database and uploads it (RN backup.ts).
///
/// The snapshot is taken completely before any network call, so the uploaded bytes are one
/// consistent moment. Nothing here throws: a failure is a ``BackupRunOutcome``.
public struct BackupService: Sendable {
    /// RN `MIN_BACKUP_INTERVAL_MS`: at most one automatic backup every 15 minutes.
    public static let minimumInterval: Int64 = 15 * 60 * 1000

    /// The pieces of the database a backup reads, injectable for tests.
    struct Source: Sendable {
        /// A consistent image of the whole database, or nil for a backend that cannot snapshot
        /// itself (RN `db.snapshotAsync` absent, backup.ts:65-67; kept for test doubles).
        var snapshot: (@Sendable () async throws -> Data)?
        /// `PRAGMA user_version` of the live database (RN `readSchemaVersion`).
        var schemaVersion: @Sendable () async throws -> Int
        /// Whether the database holds anything beyond the seeded drop zone (03 B12).
        var hasUserRows: @Sendable () async throws -> Bool

        init(
            snapshot: (@Sendable () async throws -> Data)?,
            schemaVersion: @escaping @Sendable () async throws -> Int,
            hasUserRows: @escaping @Sendable () async throws -> Bool
        ) {
            self.snapshot = snapshot
            self.schemaVersion = schemaVersion
            self.hasUserRows = hasUserRows
        }

        init(store: DatabaseStore) {
            self.init(
                snapshot: { try await store.snapshot() },
                schemaVersion: { try await store.schemaVersion() },
                hasUserRows: { try await BackupService.hasUserRows(store) }
            )
        }
    }

    private let source: Source
    /// The `sync.lastBackupAt.v1` marker: one global key, not per account (03 §5.3).
    public let lastBackup: LastBackupPreference
    private let telemetry: TelemetryReporter
    private let now: @Sendable () -> Int64

    /// - Parameters:
    ///   - store: the live database.
    ///   - lastBackup: the marker, in `UserDefaults` in the app.
    ///   - telemetry: where `backup_snapshot_failed` and `backup_too_large` go.
    ///   - now: the device clock in epoch milliseconds, for the 15-minute gate.
    public init(
        store: DatabaseStore,
        lastBackup: LastBackupPreference,
        telemetry: TelemetryReporter = .shared,
        now: @escaping @Sendable () -> Int64 = { epochMillis() }
    ) {
        self.init(source: Source(store: store), lastBackup: lastBackup, telemetry: telemetry, now: now)
    }

    init(
        source: Source,
        lastBackup: LastBackupPreference,
        telemetry: TelemetryReporter = .shared,
        now: @escaping @Sendable () -> Int64 = { epochMillis() }
    ) {
        self.source = source
        self.lastBackup = lastBackup
        self.telemetry = telemetry
        self.now = now
    }

    /// RN `lastBackupAt()` as whole milliseconds: the server time of the last backup this
    /// device recorded, or nil (03 §5.3; parsed with JS `Number` rules by the preference).
    public var lastBackupAt: Int64? {
        lastBackup.lastBackupAtMilliseconds
    }

    /// RN `runBackup(db, client)`: snapshot, size check, schema version, checksum, upload; on
    /// success the server's `capturedAt` becomes the marker.
    ///
    /// Before uploading a database that holds no user rows, the account's backups are listed;
    /// if there are any, the upload is held back (03 B12). A listing failure is returned as the
    /// outcome, and nothing is uploaded.
    public func runBackup(client: SyncClient) async -> BackupRunOutcome {
        guard let takeSnapshot = source.snapshot else { return .failed(.notConfigured) }

        let startedAt = ContinuousClock.now
        let snapshot: Data
        let schemaVersion: Int
        let empty: Bool
        do {
            // Checked before the snapshot: a row written in between can only make the snapshot
            // fuller than this says, never emptier.
            empty = try await !source.hasUserRows()
            snapshot = try await takeSnapshot()
            schemaVersion = try await source.schemaVersion()
        } catch {
            telemetry.error("backup_snapshot_failed", [
                "durationMs": .int(SyncTiming.elapsedMilliseconds(since: startedAt)),
                "errorClass": .string(errorClass(of: error)),
            ])
            return .failed(.serverError)
        }

        // Checked here as well as by the Worker: refusing locally saves uploading tens of
        // megabytes, on what may be a metered connection, only to be rejected.
        if snapshot.count > SyncLimits.maxBackupBytes {
            telemetry.error("backup_too_large", ["byteSize": .int(snapshot.count)])
            return .failed(.tooLarge)
        }

        if empty {
            switch await client.listBackups() {
            case .failure(let reason):
                return .failed(reason)
            case .success(let backups) where !backups.isEmpty:
                InventoryLog.sync.info("Backup held back: empty inventory, account has backups")
                return .heldBack
            case .success:
                break
            }
        }

        let checksum = toHex(SHA256.hash(data: snapshot))
        switch await client.uploadBackup(snapshot, schemaVersion: schemaVersion, checksum: checksum) {
        case .success(let summary):
            lastBackup.recordBackup(at: summary.capturedAt)
            return .uploaded(summary)
        case .failure(let reason):
            return .failed(reason)
        }
    }

    /// RN `maybeBackup(db, client, now)`: ``runBackup(client:)`` unless the last recorded backup
    /// is less than 15 minutes old; nil when skipped.
    ///
    /// `now` is the device clock and the marker is server time, so clock skew shifts the gate:
    /// a device clock behind the server suppresses automatic backups until it catches up, as in RN.
    public func maybeBackup(client: SyncClient, now: Int64? = nil) async -> BackupRunOutcome? {
        let current = now ?? self.now()
        if let last = lastBackup.lastBackupAt, Double(current) - last < Double(Self.minimumInterval) {
            return nil
        }
        return await runBackup(client: client)
    }

    /// Whether the database holds anything a person made: an item, a tag, a QR binding, or a
    /// space or container other than the drop zone that migration 3 seeds (03 B12).
    public static func hasUserRows(_ store: DatabaseStore) async throws -> Bool {
        try await store.queue.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS (SELECT 1 FROM items)
                    OR EXISTS (SELECT 1 FROM tags)
                    OR EXISTS (SELECT 1 FROM qr_bindings)
                    OR EXISTS (SELECT 1 FROM spaces WHERE id <> ?)
                    OR EXISTS (SELECT 1 FROM containers WHERE id <> ?)
                """,
                arguments: [DropZone.spaceId, DropZone.containerId]
            ) ?? false
        }
    }
}
