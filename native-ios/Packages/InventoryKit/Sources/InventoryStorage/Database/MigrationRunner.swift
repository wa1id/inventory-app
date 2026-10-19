import GRDB

// RN: src/db/migrations.ts:265-313. The schema version lives in
// `PRAGMA user_version`, as in the RN app, the Android build and the home server,
// which all run the same list. GRDB's `DatabaseMigrator` is never used: its
// `grdb_migrations` table would travel inside every backup and household dump
// (DECISIONS D-2).

/// One schema migration (RN `Migration`).
public struct Migration: Sendable, Hashable {
    /// Equals the migration's position in ``all`` plus one.
    public let version: Int
    public let name: String
    /// A multi-statement script, run verbatim.
    public let up: String
    /// A table rebuild that drops a table others reference: it runs with foreign keys off,
    /// or `DROP TABLE` would cascade-delete the child rows.
    public let rebuild: Bool

    public init(version: Int, name: String, up: String, rebuild: Bool = false) {
        self.version = version
        self.name = name
        self.up = up
        self.rebuild = rebuild
    }
}

/// Why the migration runner refused to start.
public enum MigrationRunnerError: Error, Sendable, Equatable {
    /// Called inside a transaction, where SQLite silently ignores `PRAGMA foreign_keys`:
    /// the v7 rebuild would then delete every photo and tag row (02 §2.3 rule 6).
    case insideTransaction
}

/// Applies the migrations a database has not seen yet (RN `migrate`).
public enum MigrationRunner {
    /// Brings the database up to the last of `migrations` and returns its `user_version`.
    ///
    /// - Migrations whose version is at or below the current `user_version` are skipped; a file
    ///   from a newer build (`user_version` > 7) therefore opens silently with nothing applied.
    /// - Each migration runs in its own deferred transaction together with its version bump, so
    ///   an interruption leaves the file at the last fully applied version.
    /// - A `rebuild` migration turns foreign keys off outside that transaction and turns them
    ///   back on afterwards, also when it fails, if they were on.
    /// - The first migration that throws stops the run and its error propagates.
    ///
    /// Must run outside any transaction: use `writeWithoutTransaction`.
    @discardableResult
    public static func migrate(_ db: Database, migrations: [Migration] = Migration.all) throws -> Int {
        guard !db.isInsideTransaction else { throw MigrationRunnerError.insideTransaction }
        let current = try userVersion(db)

        for migration in migrations where migration.version > current {
            let restoreForeignKeys = migration.rebuild ? try foreignKeysOn(db) : false
            if migration.rebuild {
                try db.execute(sql: "PRAGMA foreign_keys = OFF")
            }

            do {
                try db.inTransaction(.deferred) {
                    try db.execute(sql: migration.up)
                    // PRAGMA takes no bound parameters; the version is a trusted integer.
                    try db.execute(sql: "PRAGMA user_version = \(migration.version)")
                    return .commit
                }
            } catch {
                if restoreForeignKeys { try? db.execute(sql: "PRAGMA foreign_keys = ON") }
                throw error
            }
            if restoreForeignKeys {
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }
        }

        return try userVersion(db)
    }

    /// `PRAGMA user_version`; 0 for a new file.
    public static func userVersion(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
    }

    private static func foreignKeysOn(_ db: Database) throws -> Bool {
        (try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? 0) != 0
    }
}
