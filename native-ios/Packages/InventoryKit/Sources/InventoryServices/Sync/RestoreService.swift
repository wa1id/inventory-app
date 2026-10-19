import Foundation
import InventoryCore
import InventoryNetwork
import InventoryStorage

// RN: src/services/sync/backup.ts:108-159 (`restoreBackup`), 03 §6.1-6.2.

/// What a restore came to.
public enum RestoreRunOutcome: Sendable, Equatable {
    /// The snapshot replaced the local database and was migrated forward. `schemaVersion` is the
    /// version the snapshot was written with (RN returns the header's).
    case restored(schemaVersion: Int)
    /// Nothing was restored (RN `{status: 'failed', reason}`).
    ///
    /// `localDataReplaced` is false for every failure but one: migrating the restored snapshot
    /// failed **and** copying the previous contents back failed too (a full disk). Only then has
    /// local data changed, and the screens must re-read it (03 B11).
    case failed(SyncFailureReason, localDataReplaced: Bool)
}

/// Replaces the local database with the account's newest snapshot (RN `restoreBackup`).
///
/// Refuses, without touching local data, a download that is not a usable snapshot (03 B10):
/// a schema header that is missing (0), not a whole number, or newer than this build's 7, and
/// bytes that are not an SQLite file (a captive portal answers 200 with HTML). The database's
/// own restore then re-checks the file's `user_version` and integrity, swaps it in with SQLite's
/// backup API and migrates it; a failed migration is rolled back (03 B11, ``DatabaseStore``).
public struct RestoreService: Sendable {
    private let store: DatabaseStore
    private let telemetry: TelemetryReporter

    public init(store: DatabaseStore, telemetry: TelemetryReporter = .shared) {
        self.store = store
        self.telemetry = telemetry
    }

    /// Downloads `latest` with `client` and restores it. Every screen must re-read afterwards.
    public func restore(using client: SyncClient) async -> RestoreRunOutcome {
        let startedAt = ContinuousClock.now
        let download: BackupDownload
        switch await client.downloadBackup(id: "latest") {
        case .failure(let reason):
            // Local data is untouched.
            return .failed(reason, localDataReplaced: false)
        case .success(let value):
            download = value
        }

        // RN restored a snapshot whose header was missing (0) or not a number (NaN > 7 is false).
        guard let schemaVersion = download.schemaVersion, schemaVersion >= 1 else {
            return reject(schemaVersion: download.schemaVersion, outcome: "invalid_schema")
        }
        if schemaVersion > Migration.latestSchemaVersion {
            return reject(schemaVersion: schemaVersion, outcome: "newer_schema")
        }
        guard download.bytes.starts(with: DatabaseStore.sqliteHeader) else {
            return reject(schemaVersion: schemaVersion, outcome: "not_a_database")
        }

        do {
            try await store.restore(from: download.bytes)
        } catch SnapshotError.newerSchema(let fileVersion) {
            // The header said otherwise, but the file is what would be opened.
            return reject(schemaVersion: fileVersion, outcome: "newer_schema")
        } catch {
            telemetry.error("restore_failed", [
                "durationMs": .int(SyncTiming.elapsedMilliseconds(since: startedAt)),
                "errorClass": .string(errorClass(of: error)),
            ])
            let replaced = if case SnapshotError.rollbackFailed = error { true } else { false }
            return .failed(.corrupted, localDataReplaced: replaced)
        }

        telemetry.event("restore_succeeded", [
            "durationMs": .int(SyncTiming.elapsedMilliseconds(since: startedAt)),
            "byteSize": .int(download.bytes.count),
            "schemaVersion": .int(schemaVersion),
        ])
        return .restored(schemaVersion: schemaVersion)
    }

    /// RN `restore_rejected {schemaVersion, outcome: 'newer_schema'}` and `corrupted`. The native
    /// refusals RN did not have use the same event with their own `outcome`.
    private func reject(schemaVersion: Int?, outcome: String) -> RestoreRunOutcome {
        telemetry.error("restore_rejected", [
            "schemaVersion": schemaVersion.map(TelemetryValue.int) ?? .null,
            "outcome": .string(outcome),
        ])
        return .failed(.corrupted, localDataReplaced: false)
    }
}
