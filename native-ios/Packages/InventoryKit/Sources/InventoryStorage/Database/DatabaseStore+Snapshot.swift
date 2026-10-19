import Foundation
import GRDB
#if canImport(SQLite3)
import SQLite3
#endif

// RN: src/db/expoDatabase.ts:22-60 (`snapshotAsync`, `restoreAsync`) and
// src/services/sync/backup.ts:24-27,134-143 (`readSchemaVersion`, the schema gate,
// restore then `migrate`). Specified in 01 §2.5 and 03 §5.1, §6.2.
//
// A snapshot is a plain SQLite file image: the sync Worker never parses it, and
// the Android RN build restores it with expo's deserialize + backup API, so it
// must carry exactly the app schema and nothing else.

/// Why a snapshot could not be read or restored.
public enum SnapshotError: Error, Sendable, Equatable {
    /// The bytes do not start with the SQLite header.
    case notADatabase
    /// SQLite could not open the file, or `PRAGMA quick_check` reported damage.
    case corrupt(String)
    /// The snapshot's `user_version` is newer than this build's schema (03 §6.1, B10).
    case newerSchema(Int)
}

extension DatabaseStore {
    /// The 16 bytes every SQLite database file starts with: `SQLite format 3\0`.
    public static let sqliteHeader = Data("SQLite format 3\u{0}".utf8)

    /// How ``snapshot()`` turns the live database into bytes.
    enum SnapshotMethod: Sendable {
        /// `sqlite3_serialize` of `main`, as expo-sqlite did.
        case serialize
        /// `VACUUM INTO` a temporary file, as the home server's Node adapter does.
        case vacuumInto
    }

    // MARK: Snapshot

    /// A consistent image of the whole database, for backup.
    ///
    /// Runs `PRAGMA wal_checkpoint(TRUNCATE)` first so the image cannot lag recent writes,
    /// then `sqlite3_serialize`; falls back to `VACUUM INTO` a temporary file if serialize
    /// returns nothing. Both give a valid SQLite file with the live `user_version`.
    public func snapshot() throws -> Data {
        try queue.writeWithoutTransaction { db in try Self.snapshot(db, method: .serialize) }
    }

    /// A consistent image of the whole database, for backup. See ``snapshot()``.
    public func snapshot() async throws -> Data {
        try await queue.writeWithoutTransaction { db in try Self.snapshot(db, method: .serialize) }
    }

    func snapshot(method: SnapshotMethod) throws -> Data {
        try queue.writeWithoutTransaction { db in try Self.snapshot(db, method: method) }
    }

    static func snapshot(_ db: Database, method: SnapshotMethod) throws -> Data {
        try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        if method == .serialize, let image = serialize(db) {
            return image
        }
        return try vacuumInto(db)
    }

    private static func serialize(_ db: Database) -> Data? {
        #if canImport(SQLite3)
        guard let connection = db.sqliteConnection else { return nil }
        var size: sqlite3_int64 = 0
        guard let bytes = sqlite3_serialize(connection, "main", &size, 0) else { return nil }
        defer { sqlite3_free(bytes) }
        return Data(bytes: bytes, count: Int(size))
        #else
        return nil
        #endif
    }

    private static func vacuumInto(_ db: Database) throws -> Data {
        let directory = try makeScratchDirectory("snapshot")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "snapshot.db", directoryHint: .notDirectory)
        // VACUUM cannot run inside a transaction; callers hold writeWithoutTransaction.
        try db.execute(sql: "VACUUM INTO ?", arguments: [file.path])
        return try Data(contentsOf: file)
    }

    // MARK: Restore

    /// Replaces the whole database with a snapshot, then migrates it; returns the resulting
    /// `user_version` (7).
    ///
    /// The snapshot is checked first: it must be an SQLite file, pass `PRAGMA quick_check`,
    /// and have a `user_version` no newer than this build's (``SnapshotError``). It is then
    /// copied into the open connection with SQLite's online backup API, so the file is never
    /// overwritten under the connection and the -wal/-shm sidecars stay consistent; page 1
    /// (with the snapshot's `user_version`) comes along. An older snapshot is migrated
    /// forward. If that migration throws, the previous contents are copied back before the
    /// error propagates, so a failed restore changes nothing (03 B11, fixed per DECISIONS U6).
    ///
    /// No row-level delete happens, so the photo tombstone trigger does not fire. Callers
    /// invalidate every screen afterwards.
    @discardableResult
    public func restore(from snapshot: Data) throws -> Int {
        try restore(from: snapshot, migrations: Migration.all)
    }

    /// Replaces the whole database with a snapshot, then migrates it. See ``restore(from:)``.
    @discardableResult
    public func restore(from snapshot: Data) async throws -> Int {
        try await queue.writeWithoutTransaction { live in
            try Self.restore(live, from: snapshot, migrations: Migration.all)
        }
    }

    func restore(from snapshot: Data, migrations: [Migration]) throws -> Int {
        try queue.writeWithoutTransaction { live in
            try Self.restore(live, from: snapshot, migrations: migrations)
        }
    }

    /// The `user_version` stored in a snapshot, read without touching the live database.
    public static func schemaVersion(ofSnapshot snapshot: Data) throws -> Int {
        let file = try SnapshotFile(snapshot)
        defer { file.remove() }
        return file.schemaVersion
    }

    private static func restore(_ live: Database, from snapshot: Data, migrations: [Migration]) throws -> Int {
        let source = try SnapshotFile(snapshot)
        defer { source.remove() }
        guard source.schemaVersion <= Migration.latestSchemaVersion else {
            throw SnapshotError.newerSchema(source.schemaVersion)
        }

        // What is about to be replaced, kept in memory until the migration has succeeded.
        let previous = try DatabaseQueue()
        try previous.writeWithoutTransaction { copy in try live.backup(to: copy) }

        // A failed backup step leaves the destination untouched.
        try source.queue.read { image in try image.backup(to: live) }

        do {
            try live.execute(sql: "PRAGMA journal_mode = WAL")
            try live.execute(sql: "PRAGMA foreign_keys = ON")
            return try MigrationRunner.migrate(live, migrations: migrations)
        } catch {
            try? previous.read { copy in try copy.backup(to: live) }
            throw error
        }
    }

    static func makeScratchDirectory(_ kind: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "inventory-\(kind)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// A snapshot written to a temporary file and opened read-write (its header may say WAL).
private final class SnapshotFile {
    let directory: URL
    let queue: DatabaseQueue
    let schemaVersion: Int

    init(_ snapshot: Data) throws {
        guard snapshot.count >= DatabaseStore.sqliteHeader.count,
              snapshot.prefix(DatabaseStore.sqliteHeader.count) == DatabaseStore.sqliteHeader
        else { throw SnapshotError.notADatabase }

        let directory = try DatabaseStore.makeScratchDirectory("restore")
        do {
            let file = directory.appending(path: "snapshot.db", directoryHint: .notDirectory)
            try snapshot.write(to: file)
            let queue: DatabaseQueue
            let inspection: (check: [String], version: Int)
            do {
                queue = try DatabaseQueue(path: file.path)
                inspection = try queue.read { db in
                    (try String.fetchAll(db, sql: "PRAGMA quick_check"), try MigrationRunner.userVersion(db))
                }
            } catch let error as DatabaseError {
                throw SnapshotError.corrupt(error.message ?? "\(error.resultCode)")
            }
            guard inspection.check == ["ok"] else {
                try? queue.close()
                throw SnapshotError.corrupt(inspection.check.joined(separator: "\n"))
            }
            self.directory = directory
            self.queue = queue
            self.schemaVersion = inspection.version
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func remove() {
        try? queue.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
