import Foundation
import GRDB

// RN: src/db/expoDatabase.ts:62-77 (open + pragmas) and src/db/repositories.ts:31-34
// (migrate, then build the repositories). The Expo build opened
// `<Documents>/SQLite/inventory.db` with one connection; the native app opens the
// same file in place, with its -wal and -shm sidecars, through one GRDB
// `DatabaseQueue` (DECISIONS D-1, 02 §2.3).

/// The inventory database: one SQLite connection behind one GRDB `DatabaseQueue`.
///
/// Repositories, backup, restore and photo sync all go through ``queue``. GRDB
/// serialises every access, so a repository write is one isolated transaction.
public final class DatabaseStore: Sendable {
    /// `SQLite`, the directory expo-sqlite keeps databases in (capitalised).
    public static let directoryName = "SQLite"
    /// `inventory.db` (RN `DATABASE_NAME`).
    public static let fileName = "inventory.db"

    /// `<Documents>/SQLite/inventory.db`, where the Expo build left the database.
    public static func liveURL(documents: URL = .documentsDirectory) -> URL {
        documents
            .appending(path: directoryName, directoryHint: .isDirectory)
            .appending(path: fileName, directoryHint: .notDirectory)
    }

    /// The one connection.
    public let queue: DatabaseQueue
    /// The database file, or `nil` for an in-memory database.
    public let path: String?
    /// A scratch directory deleted with the store (temporary stores only).
    private let scratchDirectory: URL?

    /// Opens (creating if needed) the database file at `path` with the app's pragmas.
    ///
    /// Does not migrate. The file is opened in place: never copy, move or delete it or its
    /// sidecars, because the last committed transactions may exist only in the -wal file.
    public convenience init(path: String) throws {
        try self.init(queue: DatabaseQueue(path: path, configuration: Self.configuration()), path: path)
    }

    private init(queue: DatabaseQueue, path: String?, scratchDirectory: URL? = nil) {
        self.queue = queue
        self.path = path
        self.scratchDirectory = scratchDirectory
    }

    deinit {
        if let scratchDirectory {
            try? queue.close()
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
    }

    /// Opens the live database at `<Documents>/SQLite/inventory.db` and migrates it (boot).
    ///
    /// Creates `Documents/SQLite/` first on a fresh install, like expo-sqlite. A thrown error
    /// leaves nothing open; the boot screen offers Retry, which calls this again.
    public static func openLive(documents: URL = .documentsDirectory) throws -> DatabaseStore {
        let url = liveURL(documents: documents)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = try DatabaseStore(path: url.path)
        try store.migrate()
        return store
    }

    /// A private in-memory database with the app's pragmas, not migrated (tests and previews).
    public static func inMemory() throws -> DatabaseStore {
        DatabaseStore(queue: try DatabaseQueue(configuration: configuration()), path: nil)
    }

    /// A database file in a fresh temporary directory, deleted with the store; not migrated.
    public static func temporary() throws -> DatabaseStore {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "inventory-db-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: fileName, directoryHint: .notDirectory).path
        do {
            let queue = try DatabaseQueue(path: path, configuration: configuration())
            return DatabaseStore(queue: queue, path: path, scratchDirectory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// The connection setup: RN `openExpoDatabase` plus `synchronous = FULL`.
    ///
    /// `journal_mode = WAL` is already persistent in an RN-written file; `foreign_keys = ON`
    /// (GRDB's default) enforces every `ON DELETE CASCADE`; `synchronous = FULL` keeps the
    /// durability the Expo build had (its vendored SQLite defaulted to FULL in WAL mode).
    /// Nothing else is changed: no page size, auto-vacuum or encoding, and no extra tables.
    static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.label = "Inventory"
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        return configuration
    }

    // MARK: - Schema

    /// Applies the migrations this file has not seen and returns its `user_version` (RN `migrate`).
    @discardableResult
    public func migrate(_ migrations: [Migration] = Migration.all) throws -> Int {
        try queue.writeWithoutTransaction { db in
            try MigrationRunner.migrate(db, migrations: migrations)
        }
    }

    /// Applies the migrations this file has not seen and returns its `user_version` (RN `migrate`).
    @discardableResult
    public func migrate(_ migrations: [Migration] = Migration.all) async throws -> Int {
        try await queue.writeWithoutTransaction { db in
            try MigrationRunner.migrate(db, migrations: migrations)
        }
    }

    /// `PRAGMA user_version` of the live database (RN `readSchemaVersion`), sent as
    /// `x-snapshot-schema-version` with a backup.
    public func schemaVersion() throws -> Int {
        try queue.read { db in try MigrationRunner.userVersion(db) }
    }

    /// `PRAGMA user_version` of the live database (RN `readSchemaVersion`).
    public func schemaVersion() async throws -> Int {
        try await queue.read { db in try MigrationRunner.userVersion(db) }
    }

    /// Closes the connection; later accesses throw.
    public func close() throws {
        try queue.close()
    }
}
