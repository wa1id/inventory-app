import GRDB
import InventoryCore

// RN: src/repositories/qr.ts. Every statement is the TS text (01 §7.4). The
// payload format (`inventory://c/<token>`) lives in InventoryCore.

/// QR label bindings over the local SQLite database.
public struct LocalQrRepository: QrRepository {
    public let queue: DatabaseQueue
    public let environment: RepositoryEnvironment

    public init(queue: DatabaseQueue, environment: RepositoryEnvironment = .live) {
        self.queue = queue
        self.environment = environment
    }

    // MARK: Async API

    public func resolveScan(_ raw: String) async throws -> ScanOutcome {
        try await queue.read { db in try resolveScan(raw, in: db) }
    }

    public func getByContainer(_ containerId: String) async throws -> QrBinding? {
        try await queue.read { db in try getByContainer(containerId, in: db) }
    }

    public func getByToken(_ token: String) async throws -> QrBinding? {
        try await queue.read { db in try getByToken(token, in: db) }
    }

    public func bind(token: String, containerId: String) async throws -> QrBinding {
        try await queue.write { db in try bind(token: token, containerId: containerId, in: db) }
    }

    public func createAndBind(_ containerId: String) async throws -> QrBinding {
        try await queue.write { db in try createAndBind(containerId, in: db) }
    }

    public func unbind(_ containerId: String) async throws -> Bool {
        try await queue.write { db in try unbind(containerId, in: db) }
    }

    // MARK: Cores

    /// Our token (deep-link form or bare, 32 hex digits, lowercased) and what it is bound to.
    public func resolveScan(_ raw: String, in db: Database) throws -> ScanOutcome {
        guard let token = parseQrPayload(raw) else { return .invalid(raw: raw) }
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT c.* FROM containers c
                  JOIN qr_bindings q ON q.container_id = c.id
                 WHERE q.token = ?
                """,
            arguments: [token]
        )
        guard let row else { return .unknown(token: token) }
        return .bound(container: try RowMapping.container(row), token: token)
    }

    public func getByContainer(_ containerId: String, in db: Database) throws -> QrBinding? {
        try Row.fetchOne(
            db,
            sql: "SELECT * FROM qr_bindings WHERE container_id = ? ORDER BY created_at DESC LIMIT 1",
            arguments: [containerId]
        ).map(RowMapping.qrBinding)
    }

    /// Exact match; the token is not lowercased.
    public func getByToken(_ token: String, in db: Database) throws -> QrBinding? {
        try Row.fetchOne(db, sql: "SELECT * FROM qr_bindings WHERE token = ?", arguments: [token])
            .map(RowMapping.qrBinding)
    }

    /// Binds a token to a container, clearing any binding on either side in the same transaction.
    ///
    /// The drop zone throws ``InventoryError/systemRecord``. The token format and the container
    /// are not checked: an unknown container fails the insert's foreign key and rolls the
    /// deletes back, so the old bindings survive.
    public func bind(token: String, containerId: String, in db: Database) throws -> QrBinding {
        if containerId == DropZone.containerId { throw InventoryError.systemRecord }
        let now = environment.now()
        let binding = QrBinding(id: environment.makeId(), token: token, containerId: containerId, createdAt: now, updatedAt: now)

        try db.inSavepoint {
            try db.execute(sql: "DELETE FROM qr_bindings WHERE token = ?", arguments: [token])
            try db.execute(sql: "DELETE FROM qr_bindings WHERE container_id = ?", arguments: [containerId])
            try db.execute(
                sql: """
                    INSERT INTO qr_bindings (id, token, container_id, created_at, updated_at)
                           VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [binding.id, binding.token, binding.containerId, binding.createdAt, binding.updatedAt]
            )
            return .commit
        }
        return binding
    }

    /// Binds a fresh token (the on-screen label).
    public func createAndBind(_ containerId: String, in db: Database) throws -> QrBinding {
        try bind(token: environment.makeQrToken(), containerId: containerId, in: db)
    }

    /// Removes the label only; the container and its items stay. No drop-zone guard.
    public func unbind(_ containerId: String, in db: Database) throws -> Bool {
        try db.execute(sql: "DELETE FROM qr_bindings WHERE container_id = ?", arguments: [containerId])
        return db.changesCount > 0
    }
}
