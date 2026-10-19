import GRDB
import InventoryCore

// RN: src/repositories/spaces.ts. Every statement is the TS text (01 §7.1).
//
// Each operation has a core that takes a `Database`, so other writers (the
// household shadow, import) can compose several in one transaction; the async
// methods wrap one core in one GRDB access. Atomic blocks use `inSavepoint`,
// which is a transaction at top level and a savepoint when nested.

/// Spaces over the local SQLite database.
public struct LocalSpacesRepository: SpacesRepository {
    public let queue: DatabaseQueue
    public let environment: RepositoryEnvironment

    public init(queue: DatabaseQueue, environment: RepositoryEnvironment = .live) {
        self.queue = queue
        self.environment = environment
    }

    /// RN `assertNotDropZone`: nobody renames or deletes the drop zone's space, not even the home server.
    private func assertNotDropZone(_ id: String) throws {
        if id == DropZone.spaceId { throw InventoryError.systemRecord }
    }

    // MARK: Async API

    public func listWithCounts() async throws -> [SpaceWithCounts] {
        try await queue.read { db in try listWithCounts(in: db) }
    }

    public func getById(_ id: String) async throws -> Space? {
        try await queue.read { db in try getById(id, in: db) }
    }

    public func create(_ input: CreateSpaceInput) async throws -> Space {
        try await queue.write { db in try create(input, in: db) }
    }

    public func update(_ id: String, _ input: UpdateSpaceInput) async throws -> Space? {
        try await queue.write { db in try update(id, input, in: db) }
    }

    public func deletionImpact(_ id: String) async throws -> SpaceDeletionImpact {
        try await queue.read { db in try deletionImpact(id, in: db) }
    }

    public func delete(_ id: String) async throws -> DeletionResult {
        try await queue.write { db in try delete(id, in: db) }
    }

    // MARK: Cores

    /// User spaces with counts; quantity-0 items count. `COLLATE NOCASE` folds ASCII only.
    public func listWithCounts(in db: Database) throws -> [SpaceWithCounts] {
        let rows = try Row.fetchAll(db, sql: """

            SELECT s.*,
                   (SELECT COUNT(*) FROM containers c WHERE c.space_id = s.id)
                     AS container_count,
                   (SELECT COUNT(*) FROM items i
                      JOIN containers c ON c.id = i.container_id
                     WHERE c.space_id = s.id)
                     AS item_count
              FROM spaces s
             WHERE s.kind = 'normal'
             ORDER BY s.name COLLATE NOCASE ASC

            """)
        return try rows.map { row in
            SpaceWithCounts(
                space: try RowMapping.space(row),
                containerCount: try row.decode(forColumn: "container_count"),
                itemCount: try row.decode(forColumn: "item_count")
            )
        }
    }

    public func getById(_ id: String, in db: Database) throws -> Space? {
        try Row.fetchOne(db, sql: "SELECT * FROM spaces WHERE id = ?", arguments: [id]).map(RowMapping.space)
    }

    /// Trims the name but does not validate it (the form does); `kind` takes its default `normal`.
    public func create(_ input: CreateSpaceInput, in db: Database) throws -> Space {
        let now = environment.now()
        let space = Space(
            id: environment.makeId(),
            name: input.name.jsTrimmed(),
            icon: input.icon,
            color: input.color,
            createdAt: now,
            updatedAt: now
        )
        try db.execute(
            sql: """
                INSERT INTO spaces (id, name, icon, color, created_at, updated_at)
                         VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [space.id, space.name, space.icon, space.color, space.createdAt, space.updatedAt]
        )
        return space
    }

    /// The merged space (not re-read), or `nil` when missing. `id` and `createdAt` never change.
    public func update(_ id: String, _ input: UpdateSpaceInput, in db: Database) throws -> Space? {
        try assertNotDropZone(id)
        guard var next = try getById(id, in: db) else { return nil }
        if let name = input.name { next.name = name.jsTrimmed() }
        if let icon = input.icon { next.icon = icon }
        if let color = input.color { next.color = color }
        next.updatedAt = environment.now()
        try db.execute(
            sql: "UPDATE spaces SET name = ?, icon = ?, color = ?, updated_at = ? WHERE id = ?",
            arguments: [next.name, next.icon, next.color, next.updatedAt, id]
        )
        return next
    }

    public func deletionImpact(_ id: String, in db: Database) throws -> SpaceDeletionImpact {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT
                  (SELECT COUNT(*) FROM containers WHERE space_id = ?1) AS container_count,
                  (SELECT COUNT(*) FROM items i JOIN containers c ON c.id = i.container_id
                    WHERE c.space_id = ?1) AS item_count,
                  (SELECT COUNT(*) FROM item_photos p
                     JOIN items i ON i.id = p.item_id
                     JOIN containers c ON c.id = i.container_id
                    WHERE c.space_id = ?1) AS photo_count,
                  (SELECT COUNT(*) FROM qr_bindings q
                     JOIN containers c ON c.id = q.container_id
                    WHERE c.space_id = ?1) AS qr_count
                """,
            arguments: [id]
        )
        return SpaceDeletionImpact(
            containerCount: try row?.decode(forColumn: "container_count") ?? 0,
            itemCount: try row?.decode(forColumn: "item_count") ?? 0,
            photoCount: try row?.decode(forColumn: "photo_count") ?? 0,
            qrBindingCount: try row?.decode(forColumn: "qr_count") ?? 0
        )
    }

    /// Deletes the space; cascades remove its containers, items, photos (the trigger tombstones
    /// synced ones), tag links and labels. Returns the photo URIs whose files the caller deletes.
    public func delete(_ id: String, in db: Database) throws -> DeletionResult {
        try assertNotDropZone(id)
        var result = DeletionResult.notDeleted
        try db.inSavepoint {
            let photos = try Row.fetchAll(
                db,
                sql: """
                    SELECT p.uri, p.thumb_uri FROM item_photos p
                      JOIN items i ON i.id = p.item_id
                      JOIN containers c ON c.id = i.container_id
                     WHERE c.space_id = ?
                    """,
                arguments: [id]
            )
            let orphaned = try RowMapping.photoUris(photos)
            try db.execute(sql: "DELETE FROM spaces WHERE id = ?", arguments: [id])
            result = DeletionResult(deleted: db.changesCount > 0, orphanedPhotoUris: orphaned)
            return .commit
        }
        return result
    }
}
