import GRDB
import InventoryCore

// RN: src/repositories/containers.ts. Every statement is the TS text (01 §7.2).

/// Containers over the local SQLite database.
public struct LocalContainersRepository: ContainersRepository {
    /// Bounded retry budget for a short-code collision (RN `SHORT_CODE_ATTEMPTS`).
    static let shortCodeAttempts = 10

    public let queue: DatabaseQueue
    public let environment: RepositoryEnvironment

    public init(queue: DatabaseQueue, environment: RepositoryEnvironment = .live) {
        self.queue = queue
        self.environment = environment
    }

    /// RN `assertNotDropZone`: the drop zone is not a container anyone can rename, move or delete.
    private func assertNotDropZone(_ id: String) throws {
        if id == DropZone.containerId { throw InventoryError.systemRecord }
    }

    // MARK: Async API

    public func listBySpace(_ spaceId: String) async throws -> [ContainerWithCounts] {
        try await queue.read { db in try listBySpace(spaceId, in: db) }
    }

    public func getById(_ id: String) async throws -> Container? {
        try await queue.read { db in try getById(id, in: db) }
    }

    public func getWithCounts(_ id: String) async throws -> ContainerWithCounts? {
        try await queue.read { db in try getWithCounts(id, in: db) }
    }

    public func create(_ input: CreateContainerInput) async throws -> Container {
        try await queue.write { db in try create(input, in: db) }
    }

    public func update(_ id: String, _ input: UpdateContainerInput) async throws -> Container? {
        try await queue.write { db in try update(id, input, in: db) }
    }

    public func deletionImpact(_ id: String) async throws -> ContainerDeletionImpact {
        try await queue.read { db in try deletionImpact(id, in: db) }
    }

    public func delete(_ id: String) async throws -> DeletionResult {
        try await queue.write { db in try delete(id, in: db) }
    }

    public func listAllWithSpace() async throws -> [ContainerWithSpace] {
        try await queue.read { db in try listAllWithSpace(in: db) }
    }

    // MARK: Cores

    /// A space's user containers, newest first.
    public func listBySpace(_ spaceId: String, in db: Database) throws -> [ContainerWithCounts] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT c.*,
                       (SELECT COUNT(*) FROM items i WHERE i.container_id = c.id) AS item_count,
                       (SELECT q.token FROM qr_bindings q WHERE q.container_id = c.id
                         ORDER BY q.created_at DESC LIMIT 1) AS qr_token
                  FROM containers c
                 WHERE c.space_id = ? AND c.kind = 'normal'
                 ORDER BY c.created_at DESC
                """,
            arguments: [spaceId]
        ).map(RowMapping.containerWithCounts)
    }

    /// Any container, the drop zone included.
    public func getById(_ id: String, in db: Database) throws -> Container? {
        try Row.fetchOne(db, sql: "SELECT * FROM containers WHERE id = ?", arguments: [id]).map(RowMapping.container)
    }

    /// Any container with its counts, the drop zone included.
    public func getWithCounts(_ id: String, in db: Database) throws -> ContainerWithCounts? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT c.*,
                       (SELECT COUNT(*) FROM items i WHERE i.container_id = c.id) AS item_count,
                       (SELECT q.token FROM qr_bindings q WHERE q.container_id = c.id
                         ORDER BY q.created_at DESC LIMIT 1) AS qr_token
                  FROM containers c
                 WHERE c.id = ?
                """,
            arguments: [id]
        ).map(RowMapping.containerWithCounts)
    }

    /// Creates a container with a unique short code.
    ///
    /// The `UNIQUE` index arbitrates: each attempt takes a new id and a new code, and any
    /// constraint failure retries, up to 10 times, before ``InventoryError/shortCodeExhausted``.
    /// RN matches `/UNIQUE|constraint/i` on the message, so an unknown space (a foreign-key
    /// failure) also retries and ends with that error (01 §7.2, Q5; parity with the home server).
    public func create(_ input: CreateContainerInput, in db: Database) throws -> Container {
        let now = environment.now()
        let name = input.name?.jsTrimmed().nilIfEmpty

        for _ in 0..<Self.shortCodeAttempts {
            let container = Container(
                id: environment.makeId(),
                spaceId: input.spaceId,
                name: name,
                visualType: input.visualType,
                shortCode: environment.shortCode(input.visualType),
                createdAt: now,
                updatedAt: now
            )
            do {
                try db.inSavepoint {
                    try db.execute(
                        sql: """
                            INSERT INTO containers
                                 (id, space_id, name, visual_type, short_code, created_at, updated_at)
                               VALUES (?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            container.id,
                            container.spaceId,
                            container.name,
                            container.visualType.rawValue,
                            container.shortCode,
                            container.createdAt,
                            container.updatedAt,
                        ]
                    )
                    return .commit
                }
                return container
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                // Short code collided (or a constraint failed); try another one.
                continue
            }
        }
        throw InventoryError.shortCodeExhausted
    }

    /// The merged container (not re-read), or `nil` when missing.
    ///
    /// The short code and `kind` never change. There is no guard on the target space: a
    /// container can be moved into the drop zone's space, and an unknown space throws a
    /// foreign-key error (01 §7.2, Q11; parity with the home server).
    public func update(_ id: String, _ input: UpdateContainerInput, in db: Database) throws -> Container? {
        try assertNotDropZone(id)
        guard var next = try getById(id, in: db) else { return nil }
        switch input.name {
        case .unchanged: break
        case .clear: next.name = nil
        case .set(let name): next.name = name.jsTrimmed().nilIfEmpty
        }
        if let visualType = input.visualType { next.visualType = visualType }
        if let spaceId = input.spaceId { next.spaceId = spaceId }
        next.updatedAt = environment.now()
        try db.execute(
            sql: """
                UPDATE containers
                   SET name = ?, visual_type = ?, space_id = ?, updated_at = ?
                 WHERE id = ?
                """,
            arguments: [next.name, next.visualType.rawValue, next.spaceId, next.updatedAt, id]
        )
        return next
    }

    public func deletionImpact(_ id: String, in db: Database) throws -> ContainerDeletionImpact {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT
                  (SELECT COUNT(*) FROM items WHERE container_id = ?1) AS item_count,
                  (SELECT COUNT(*) FROM item_photos p JOIN items i ON i.id = p.item_id
                    WHERE i.container_id = ?1) AS photo_count,
                  (SELECT COUNT(*) FROM qr_bindings WHERE container_id = ?1) AS qr_count
                """,
            arguments: [id]
        )
        let qrCount: Int = try row?.decode(forColumn: "qr_count") ?? 0
        return ContainerDeletionImpact(
            itemCount: try row?.decode(forColumn: "item_count") ?? 0,
            photoCount: try row?.decode(forColumn: "photo_count") ?? 0,
            hasQrBinding: qrCount > 0
        )
    }

    /// Deletes the container; cascades remove its items, photos, tag links and label.
    public func delete(_ id: String, in db: Database) throws -> DeletionResult {
        try assertNotDropZone(id)
        var result = DeletionResult.notDeleted
        try db.inSavepoint {
            let photos = try Row.fetchAll(
                db,
                sql: """
                    SELECT p.uri, p.thumb_uri FROM item_photos p
                      JOIN items i ON i.id = p.item_id
                     WHERE i.container_id = ?
                    """,
                arguments: [id]
            )
            let orphaned = try RowMapping.photoUris(photos)
            try db.execute(sql: "DELETE FROM containers WHERE id = ?", arguments: [id])
            result = DeletionResult(deleted: db.changesCount > 0, orphanedPhotoUris: orphaned)
            return .commit
        }
        return result
    }

    /// Every user container with its space name: by space name (ASCII case-insensitive), then newest first.
    public func listAllWithSpace(in db: Database) throws -> [ContainerWithSpace] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT c.*, s.name AS space_name,
                       (SELECT COUNT(*) FROM items i WHERE i.container_id = c.id) AS item_count
                  FROM containers c
                  JOIN spaces s ON s.id = c.space_id
                 WHERE c.kind = 'normal'
                 ORDER BY s.name COLLATE NOCASE ASC, c.created_at DESC
                """
        ).map { row in
            ContainerWithSpace(
                container: try RowMapping.container(row),
                spaceName: try row.decode(forColumn: "space_name"),
                itemCount: try row.decode(forColumn: "item_count")
            )
        }
    }
}
