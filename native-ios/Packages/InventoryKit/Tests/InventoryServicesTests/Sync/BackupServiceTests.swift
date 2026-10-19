import Foundation
import GRDB
import InventoryCore
import InventoryNetwork
import InventoryStorage
import InventoryTestSupport
import Testing
@testable import InventoryServices

// Ports src/services/sync/__tests__/backup.test.ts against the real snapshot and restore of a
// temporary GRDB database and a fake Worker behind a real SyncClient, plus the U6 fixes:
// B10 (refuse a download that is not a usable snapshot), B11 (a failed migration changes
// nothing) and B12 (never back up an empty inventory over existing backups).

/// A backup service over `store` with an in-memory marker and a recording sink.
private struct SyncBackupHarness {
    let store: DatabaseStore
    let worker = SyncFakeWorker()
    let preferences = InMemoryPreferences()
    let telemetry = RecordingTelemetry()

    var lastBackup: LastBackupPreference { LastBackupPreference(preferences: preferences) }

    func service(now: Int64 = 0) -> BackupService {
        BackupService(store: store, lastBackup: lastBackup, telemetry: telemetry.syncReporter, now: { now })
    }

    func service(source: BackupService.Source) -> BackupService {
        BackupService(source: source, lastBackup: lastBackup, telemetry: telemetry.syncReporter)
    }

    func restoreService() -> RestoreService {
        RestoreService(store: store, telemetry: telemetry.syncReporter)
    }

    func itemNames() async throws -> [String] {
        try await store.queue.read { db in try String.fetchAll(db, sql: "SELECT name FROM items") }
    }
}

private func seededHarness() async throws -> SyncBackupHarness {
    SyncBackupHarness(store: try await SyncTestInventory.seeded(itemName: "Cordless Drill").store)
}

@Suite("backup runBackup")
struct SyncRunBackupTests {
    @Test("uploads a snapshot tagged with the current schema version")
    func uploadsTaggedSnapshot() async throws {
        let harness = try await seededHarness()
        let outcome = await harness.service().runBackup(client: harness.worker.client())

        guard case .uploaded(let summary) = outcome else {
            Issue.record("expected an upload, got \(outcome)")
            return
        }
        let stored = harness.worker.state.backups
        #expect(stored.count == 1)
        #expect(stored.first?.schemaVersion == String(Migration.latestSchemaVersion))
        #expect(summary.capturedAt == 1000)
        #expect(stored.first?.bytes.starts(with: DatabaseStore.sqliteHeader) == true)
    }

    @Test("sends a checksum so the service can reject a corrupted upload")
    func sendsChecksum() async throws {
        let harness = try await seededHarness()
        _ = await harness.service().runBackup(client: harness.worker.client())
        let checksum = try #require(harness.worker.state.backups.first?.checksum)
        #expect(checksum.count == 64)
        #expect(checksum.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test("reports failure without recording a backup time")
    func failureRecordsNothing() async throws {
        let harness = try await seededHarness()
        harness.worker.update { $0.failBackupUploads = .offline }

        let outcome = await harness.service().runBackup(client: harness.worker.client())

        #expect(outcome == .failed(.offline))
        #expect(harness.preferences.values.isEmpty)
    }

    @Test("degrades cleanly on a backend that cannot snapshot itself")
    func backendWithoutSnapshot() async throws {
        let harness = try await seededHarness()
        let source = BackupService.Source(snapshot: nil, schemaVersion: { 7 }, hasUserRows: { true })

        let outcome = await harness.service(source: source).runBackup(client: harness.worker.client())

        #expect(outcome == .failed(.notConfigured))
        #expect(harness.worker.server.requests.isEmpty)
    }

    @Test("refuses a snapshot larger than the service accepts")
    func refusesOversizedSnapshot() async throws {
        let harness = try await seededHarness()
        let source = BackupService.Source(
            snapshot: { Data(count: SyncLimits.maxBackupBytes + 1) }, schemaVersion: { 7 }, hasUserRows: { true })

        let outcome = await harness.service(source: source).runBackup(client: harness.worker.client())

        #expect(outcome == .failed(.tooLarge))
        // Refused locally: nothing went over a possibly metered connection.
        #expect(harness.worker.server.requests.isEmpty)
        #expect(harness.telemetry.errors == [
            .init(level: "error", name: "backup_too_large", payload: ["byteSize": .int(SyncLimits.maxBackupBytes + 1)]),
        ])
    }

    @Test("a snapshot that throws is a server error with backup_snapshot_failed, and no upload")
    func snapshotFailure() async throws {
        let harness = try await seededHarness()
        try harness.store.close()

        let outcome = await harness.service().runBackup(client: harness.worker.client())

        #expect(outcome == .failed(.serverError))
        #expect(harness.worker.server.requests.isEmpty)
        let entry = try #require(harness.telemetry.errors.first)
        #expect(entry.name == "backup_snapshot_failed")
        #expect(Set(entry.payload.keys) == ["durationMs", "errorClass"])
    }

    @Test("a stored backup records the server's capturedAt as an integer string")
    func recordsServerTime() async throws {
        let harness = try await seededHarness()
        _ = await harness.service().runBackup(client: harness.worker.client())
        #expect(harness.preferences.values == [PreferenceKey.lastBackupAt: "1000"])
        #expect(harness.service().lastBackupAt == 1000)
    }
}

@Suite("backup maybeBackup")
struct SyncMaybeBackupTests {
    @Test("backs up when nothing has been backed up yet")
    func backsUpFirstTime() async throws {
        let harness = try await seededHarness()
        let outcome = await harness.service().maybeBackup(client: harness.worker.client())
        #expect(outcome != nil)
        #expect(harness.worker.state.backups.count == 1)
    }

    @Test("skips a backup taken too recently")
    func skipsRecentBackup() async throws {
        let harness = try await seededHarness()
        let client = harness.worker.client()
        _ = await harness.service().runBackup(client: client)

        let skipped = await harness.service().maybeBackup(client: client, now: 1000 + BackupService.minimumInterval - 1)

        #expect(skipped == nil)
        #expect(harness.worker.state.backups.count == 1)
    }

    @Test("backs up again once the interval has passed")
    func backsUpAfterInterval() async throws {
        let harness = try await seededHarness()
        let client = harness.worker.client()
        _ = await harness.service().runBackup(client: client)

        _ = await harness.service().maybeBackup(client: client, now: 1000 + BackupService.minimumInterval + 1)

        #expect(harness.worker.state.backups.count == 2)
    }

    @Test("the gate reads the device clock it was given")
    func gateUsesInjectedClock() async throws {
        let harness = try await seededHarness()
        let client = harness.worker.client()
        _ = await harness.service().runBackup(client: client)
        #expect(await harness.service(now: 1000 + BackupService.minimumInterval - 1).maybeBackup(client: client) == nil)
        #expect(await harness.service(now: 1000 + BackupService.minimumInterval).maybeBackup(client: client) != nil)
    }
}

@Suite("backup restoreBackup")
struct SyncRestoreBackupTests {
    @Test("brings back data that was deleted after the snapshot")
    func bringsBackDeletedData() async throws {
        let harness = try await seededHarness()
        let client = harness.worker.client()
        _ = await harness.service().runBackup(client: client)

        try await harness.store.queue.write { db in try db.execute(sql: "DELETE FROM items") }
        #expect(try await harness.itemNames().isEmpty)

        let outcome = await harness.restoreService().restore(using: client)

        #expect(outcome == .restored(schemaVersion: Migration.latestSchemaVersion))
        #expect(try await harness.itemNames() == ["Cordless Drill"])
        let succeeded = try #require(harness.telemetry.events.first { $0.name == "restore_succeeded" })
        #expect(Set(succeeded.payload.keys) == ["durationMs", "byteSize", "schemaVersion"])
    }

    @Test("migrates a snapshot from an older build forward")
    func migratesOlderSnapshot() async throws {
        // A database that only ever saw migration 1, snapshotted by an old build.
        let old = try DatabaseStore.temporary()
        try await old.migrate(Array(Migration.all.prefix(1)))
        let oldHarness = SyncBackupHarness(store: old)
        let worker = oldHarness.worker
        _ = await BackupService(store: old, lastBackup: oldHarness.lastBackup, telemetry: oldHarness.telemetry.syncReporter)
            .runBackup(client: worker.client())
        #expect(worker.state.backups.first?.schemaVersion == "1")

        let harness = try await seededHarness()
        let outcome = await harness.restoreService().restore(using: worker.client())

        #expect(outcome == .restored(schemaVersion: 1))
        // Restored at v1, then carried forward.
        #expect(try await harness.store.schemaVersion() == Migration.latestSchemaVersion)
    }

    @Test("refuses a snapshot written by a newer build")
    func refusesNewerSnapshot() async throws {
        let harness = try await seededHarness()
        let client = harness.worker.client()
        _ = await harness.service().runBackup(client: client)
        harness.worker.update { $0.servedSchemaHeader = .some(String(Migration.latestSchemaVersion + 1)) }

        let outcome = await harness.restoreService().restore(using: client)

        #expect(outcome == .failed(.corrupted, localDataReplaced: false))
        #expect(harness.telemetry.errors.last == .init(level: "error", name: "restore_rejected", payload: [
            "schemaVersion": .int(Migration.latestSchemaVersion + 1), "outcome": .string("newer_schema"),
        ]))
    }

    @Test("passes through a download failure without touching local data")
    func passesThroughDownloadFailure() async throws {
        let harness = try await seededHarness()
        harness.worker.update { $0.failBackupDownloads = .offline }

        let outcome = await harness.restoreService().restore(using: harness.worker.client())

        #expect(outcome == .failed(.offline, localDataReplaced: false))
        #expect(try await harness.itemNames() == ["Cordless Drill"])
    }
}

@Suite("backup: refusing a download that is not a usable snapshot (03 B10)")
struct SyncRestoreRefusalTests {
    /// A seeded harness whose Worker holds one snapshot of an emptied copy, so a wrongly
    /// accepted restore would visibly delete the item.
    private func harnessWithEmptySnapshot() async throws -> SyncBackupHarness {
        let harness = try await seededHarness()
        let other = try await SyncTestInventory.empty()
        let snapshot = try await other.snapshot()
        harness.worker.update {
            $0.backups = [SyncFakeWorker.StoredBackup(bytes: snapshot, schemaVersion: "7", checksum: nil, capturedAt: 1000)]
        }
        return harness
    }

    @Test("a missing schema header is refused (RN restored it as version 0)")
    func missingHeader() async throws {
        let harness = try await harnessWithEmptySnapshot()
        harness.worker.update { $0.servedSchemaHeader = .some(nil) }

        let outcome = await harness.restoreService().restore(using: harness.worker.client())

        #expect(outcome == .failed(.corrupted, localDataReplaced: false))
        #expect(try await harness.itemNames() == ["Cordless Drill"])
        #expect(harness.telemetry.errors.last == .init(level: "error", name: "restore_rejected", payload: [
            "schemaVersion": .int(0), "outcome": .string("invalid_schema"),
        ]))
    }

    @Test("a schema header that is not a whole number is refused (RN: NaN > 7 is false)", arguments: ["abc", "6.5", "", "-1"])
    func invalidHeader(header: String) async throws {
        let harness = try await harnessWithEmptySnapshot()
        harness.worker.update { $0.servedSchemaHeader = .some(header) }

        let outcome = await harness.restoreService().restore(using: harness.worker.client())

        #expect(outcome == .failed(.corrupted, localDataReplaced: false))
        #expect(try await harness.itemNames() == ["Cordless Drill"])
        #expect(harness.telemetry.errors.last?.name == "restore_rejected")
    }

    @Test("an HTML page answered with 200 (a captive portal) is refused before anything is touched")
    func captivePortal() async throws {
        let harness = try await harnessWithEmptySnapshot()
        harness.worker.update { $0.servedBackupBody = Data("<html><body>Sign in to the Wi-Fi</body></html>".utf8) }

        let outcome = await harness.restoreService().restore(using: harness.worker.client())

        #expect(outcome == .failed(.corrupted, localDataReplaced: false))
        #expect(try await harness.itemNames() == ["Cordless Drill"])
        #expect(harness.telemetry.errors.last == .init(level: "error", name: "restore_rejected", payload: [
            "schemaVersion": .int(7), "outcome": .string("not_a_database"),
        ]))
    }

    @Test("a file newer than its header claims is refused as newer_schema")
    func fileNewerThanHeader() async throws {
        let harness = try await seededHarness()
        let newer = try await SyncTestInventory.empty()
        try await newer.queue.write { db in try db.execute(sql: "PRAGMA user_version = 8") }
        let snapshot = try await newer.snapshot()
        harness.worker.update {
            $0.backups = [SyncFakeWorker.StoredBackup(bytes: snapshot, schemaVersion: "7", checksum: nil, capturedAt: 1000)]
        }

        let outcome = await harness.restoreService().restore(using: harness.worker.client())

        #expect(outcome == .failed(.corrupted, localDataReplaced: false))
        #expect(try await harness.itemNames() == ["Cordless Drill"])
        #expect(harness.telemetry.errors.last == .init(level: "error", name: "restore_rejected", payload: [
            "schemaVersion": .int(8), "outcome": .string("newer_schema"),
        ]))
    }

    @Test("SQLite bytes that are damaged fail as corrupted with restore_failed, and nothing changes")
    func damagedFile() async throws {
        let harness = try await harnessWithEmptySnapshot()
        var damaged = DatabaseStore.sqliteHeader
        damaged.append(Data(repeating: 0xAB, count: 8192))
        harness.worker.update { $0.servedBackupBody = damaged }

        let outcome = await harness.restoreService().restore(using: harness.worker.client())

        #expect(outcome == .failed(.corrupted, localDataReplaced: false))
        #expect(try await harness.itemNames() == ["Cordless Drill"])
        let entry = try #require(harness.telemetry.errors.last)
        #expect(entry.name == "restore_failed")
        #expect(Set(entry.payload.keys) == ["durationMs", "errorClass"])
    }
}

@Suite("backup: a failed migration after the swap changes nothing (03 B11)")
struct SyncRestoreRollbackTests {
    @Test("a snapshot whose migration fails is rolled back and reported as corrupted")
    func migrationFailureRollsBack() async throws {
        // At version 3 with a table migration 4 creates, so migrating it forward fails.
        let broken = try DatabaseStore.temporary()
        try await broken.migrate(Array(Migration.all.prefix(3)))
        try await broken.queue.write { db in
            try db.execute(sql: "CREATE TABLE sync_deletions (photo_id TEXT PRIMARY KEY NOT NULL, deleted_at INTEGER NOT NULL)")
        }
        let snapshot = try await broken.snapshot()

        let harness = try await seededHarness()
        harness.worker.update {
            $0.backups = [SyncFakeWorker.StoredBackup(bytes: snapshot, schemaVersion: "3", checksum: nil, capturedAt: 1000)]
        }

        let outcome = await harness.restoreService().restore(using: harness.worker.client())

        #expect(outcome == .failed(.corrupted, localDataReplaced: false))
        // "Nothing on this phone was changed" is true again.
        #expect(try await harness.itemNames() == ["Cordless Drill"])
        #expect(try await harness.store.schemaVersion() == Migration.latestSchemaVersion)
        #expect(harness.telemetry.errors.last?.name == "restore_failed")
    }
}

@Suite("backup: never an empty inventory over existing backups (03 B12)")
struct SyncEmptyInventoryGuardTests {
    @Test("an empty inventory is held back when the account already has backups")
    func heldBackWhenBackupsExist() async throws {
        let harness = SyncBackupHarness(store: try await SyncTestInventory.empty())
        let real = try await SyncTestInventory.seeded().store.snapshot()
        harness.worker.update {
            $0.backups = [SyncFakeWorker.StoredBackup(bytes: real, schemaVersion: "7", checksum: nil, capturedAt: 1000)]
        }

        let outcome = await harness.service().runBackup(client: harness.worker.client())

        #expect(outcome == .heldBack)
        #expect(harness.worker.state.backups.count == 1)
        #expect(harness.worker.state.backupListings == 1)
        #expect(harness.preferences.values.isEmpty)
    }

    @Test("an empty inventory is backed up when the account has no backups yet")
    func uploadsWhenNoBackups() async throws {
        let harness = SyncBackupHarness(store: try await SyncTestInventory.empty())

        let outcome = await harness.service().runBackup(client: harness.worker.client())

        guard case .uploaded = outcome else {
            Issue.record("expected an upload, got \(outcome)")
            return
        }
        #expect(harness.worker.state.backups.count == 1)
    }

    @Test("an inventory with rows is backed up without listing")
    func doesNotListWithRows() async throws {
        let harness = try await seededHarness()
        harness.worker.update {
            $0.backups = [SyncFakeWorker.StoredBackup(bytes: Data(), schemaVersion: "7", checksum: nil, capturedAt: 1)]
        }

        _ = await harness.service().runBackup(client: harness.worker.client())

        #expect(harness.worker.state.backupListings == 0)
        #expect(harness.worker.state.backups.count == 2)
    }

    @Test("a failed listing uploads nothing and reports why")
    func listingFailure() async throws {
        let harness = SyncBackupHarness(store: try await SyncTestInventory.empty())
        harness.worker.update { $0.failBackupList = .offline }

        let outcome = await harness.service().runBackup(client: harness.worker.client())

        #expect(outcome == .failed(.offline))
        #expect(harness.worker.state.backups.isEmpty)
    }

    @Test("what counts as a user row", arguments: [
        ("an item", "item"), ("a space", "space"), ("a container in the drop zone", "container"),
        ("a tag", "tag"), ("a QR binding", "qr"),
    ])
    func userRows(label: String, kind: String) async throws {
        let store = try await SyncTestInventory.empty()
        #expect(try await BackupService.hasUserRows(store) == false, "\(label)")
        let repos = LocalRepositories(store: store)
        switch kind {
        case "item": _ = try await repos.items.create(ItemDraft(containerId: DropZone.containerId, name: "Drill"))
        case "space": _ = try await repos.spaces.create(CreateSpaceInput(name: "Loft", icon: "home", color: "#E4572E"))
        case "container":
            try await store.queue.write { db in
                try db.execute(sql: """
                    INSERT INTO containers (id, space_id, name, visual_type, short_code, created_at, updated_at)
                    VALUES ('c', 'drop-zone-space', NULL, 'box', 'BOX-0001', 1, 1)
                    """)
            }
        case "tag":
            try await store.queue.write { db in
                try db.execute(sql: "INSERT INTO tags (id, name, normalized_name, created_at) VALUES ('t', 'Tools', 'tools', 1)")
            }
        default:
            try await store.queue.write { db in
                try db.execute(sql: """
                    INSERT INTO qr_bindings (id, token, container_id, created_at, updated_at)
                    VALUES ('q', '0123456789abcdef0123456789abcdef', 'drop-zone', 1, 1)
                    """)
            }
        }
        #expect(try await BackupService.hasUserRows(store), "\(label)")
    }
}
