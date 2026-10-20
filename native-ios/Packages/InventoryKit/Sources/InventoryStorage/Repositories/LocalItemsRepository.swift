import GRDB
import InventoryCore

// RN: src/repositories/items.ts. Every statement is the TS text (01 §7.3).
// `search_text` and `tags.normalized_name` use InventoryCore's JS-parity folds,
// the same ones the household shadow writes.

/// Items over the local SQLite database.
public struct LocalItemsRepository: ItemsRepository {
    public let queue: DatabaseQueue
    public let environment: RepositoryEnvironment

    public init(queue: DatabaseQueue, environment: RepositoryEnvironment = .live) {
        self.queue = queue
        self.environment = environment
    }

    /// RN `requireQuantity`: a whole number of 0 or more (no upper bound here; only the stepper clamps).
    private func requireQuantity(_ quantity: Int) throws -> Int {
        guard quantity >= 0 else { throw InventoryError.invalidQuantity }
        return quantity
    }

    // MARK: Async API

    public func listByContainer(_ containerId: String) async throws -> [ItemWithContext] {
        try await queue.read { db in try listByContainer(containerId, in: db) }
    }

    public func listUnsorted() async throws -> [ItemWithContext] {
        try await queue.read { db in try listUnsorted(in: db) }
    }

    public func listRecent(limit: Int) async throws -> [ItemWithContext] {
        try await queue.read { db in try listRecent(limit: limit, in: db) }
    }

    public func countUnsorted() async throws -> Int {
        try await queue.read { db in try countUnsorted(in: db) }
    }

    public func getById(_ id: String) async throws -> ItemWithContext? {
        try await queue.read { db in try getById(id, in: db) }
    }

    public func create(_ draft: ItemDraft) async throws -> Item {
        try await queue.write { db in try create(draft, in: db) }
    }

    public func update(_ id: String, _ input: UpdateItemInput) async throws -> Item? {
        try await queue.write { db in try update(id, input, in: db) }
    }

    public func getPhotos(_ itemId: String) async throws -> [ItemPhoto] {
        try await queue.read { db in try getPhotos(itemId, in: db) }
    }

    public func delete(_ id: String) async throws -> DeletionResult {
        try await queue.write { db in try delete(id, in: db) }
    }

    public func countAll() async throws -> Int {
        try await queue.read { db in try countAll(in: db) }
    }

    // MARK: Reads

    public func listByContainer(_ containerId: String, in db: Database) throws -> [ItemWithContext] {
        try Row.fetchAll(
            db,
            sql: "\(itemContextSelect) WHERE i.container_id = ? ORDER BY i.created_at DESC",
            arguments: [containerId]
        ).map(RowMapping.itemWithContext)
    }

    /// Everything waiting in the drop zone, newest first.
    public func listUnsorted(in db: Database) throws -> [ItemWithContext] {
        try Row.fetchAll(
            db,
            sql: "\(itemContextSelect) WHERE i.container_id = ? ORDER BY i.created_at DESC",
            arguments: [DropZone.containerId]
        ).map(RowMapping.itemWithContext)
    }

    /// The newest items, drop zone included; `limit` clamped to 1…100.
    ///
    /// RN reads `ITEM_CONTEXT_SELECT ORDER BY i.created_at DESC LIMIT ?` in one statement.
    /// There is no index on `created_at` (and U12 adds none), so that statement worked out the
    /// photo and tag subqueries for every item before sorting: 25 ms at 10 000 items on the
    /// build Mac's M4 Pro, paid on every Home focus and every write while Home shows. Here the
    /// same joins and the same `ORDER BY` pick the ids first, then the context is read for those
    /// rows only (5 ms; docs/PERFORMANCE.md). Same rows in the same order, ties and orphaned rows
    /// included: the first statement is RN's with only the id selected, so SQLite plans and sorts
    /// it the same way (`PerfReadParityTests`).
    public func listRecent(limit: Int = 40, in db: Database) throws -> [ItemWithContext] {
        let cap = max(1, min(limit, 100))
        let ids = try String.fetchAll(
            db,
            sql: """
                SELECT i.id
                  FROM items i
                  JOIN containers c ON c.id = i.container_id
                  JOIN spaces s ON s.id = c.space_id
                 ORDER BY i.created_at DESC LIMIT ?
                """,
            arguments: [cap]
        )
        return try Self.withContext(ids, in: db)
    }

    /// The context rows of `ids` (``itemContextSelect``), in the order of `ids`.
    static func withContext(_ ids: [String], in db: Database) throws -> [ItemWithContext] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let rows = try Row.fetchAll(
            db,
            sql: "\(itemContextSelect) WHERE i.id IN (\(placeholders))",
            arguments: StatementArguments(ids)
        )
        var byId: [String: ItemWithContext] = [:]
        byId.reserveCapacity(rows.count)
        for row in rows {
            let item = try RowMapping.itemWithContext(row)
            byId[item.item.id] = item
        }
        return ids.compactMap { byId[$0] }
    }

    public func countUnsorted(in db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) AS count FROM items WHERE container_id = ?",
            arguments: [DropZone.containerId]
        ) ?? 0
    }

    public func getById(_ id: String, in db: Database) throws -> ItemWithContext? {
        try Row.fetchOne(db, sql: "\(itemContextSelect) WHERE i.id = ?", arguments: [id])
            .map(RowMapping.itemWithContext)
    }

    public func getPhotos(_ itemId: String, in db: Database) throws -> [ItemPhoto] {
        try Row.fetchAll(
            db,
            sql: "SELECT * FROM item_photos WHERE item_id = ? ORDER BY created_at ASC",
            arguments: [itemId]
        ).map(RowMapping.itemPhoto)
    }

    public func countAll(in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) AS count FROM items") ?? 0
    }

    // MARK: Writes

    /// Creates the item with its photo and tags; all of it commits or none does.
    ///
    /// Quantity is checked before the name. An omitted name is stored as `''` (fast capture
    /// writes the row before recognition); a provided blank name throws. An unknown container
    /// fails the foreign key and rolls everything back.
    public func create(_ draft: ItemDraft, in db: Database) throws -> Item {
        let now = environment.now()
        let quantity = try requireQuantity(draft.quantity ?? 1)

        let name: String
        if let given = draft.name {
            name = given.jsTrimmed()
            if name.isEmpty { throw InventoryError.nameRequired }
        } else {
            name = ""
        }

        let item = Item(
            id: environment.makeId(),
            containerId: draft.containerId,
            name: name,
            category: draft.category?.jsTrimmed().nilIfEmpty,
            quantity: quantity,
            notes: draft.notes?.jsTrimmed().nilIfEmpty,
            createdAt: now,
            updatedAt: now
        )

        try db.inSavepoint {
            try db.execute(
                sql: """
                    INSERT INTO items
                         (id, container_id, name, category, quantity, notes, created_at,
                          updated_at, search_text)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    item.id,
                    item.containerId,
                    item.name,
                    item.category,
                    item.quantity,
                    item.notes,
                    item.createdAt,
                    item.updatedAt,
                    itemSearchText(name: item.name, category: item.category),
                ]
            )

            if let photo = draft.photo {
                try insertPhoto(photo, id: photo.id ?? environment.makeId(), itemId: item.id, createdAt: now, in: db)
            }

            if let tags = draft.tags, !tags.isEmpty {
                try replaceTags(itemId: item.id, tags: tags, in: db)
            }
            return .commit
        }

        return item
    }

    /// Applies a patch and returns the merged item (not re-read), or `nil` when the row is gone.
    ///
    /// Every update rewrites `search_text` from the merged name and category. With
    /// `expectedUpdatedAt`, a row whose `updated_at` moved on throws ``ConflictError`` with its
    /// current value and nothing is written; a row that vanished returns `nil`. `tags`
    /// replaces every link; `photo` deletes the photo rows (the trigger tombstones synced ones)
    /// and inserts the new one under a new id. The old photo's files are the caller's to delete.
    public func update(_ id: String, _ input: UpdateItemInput, in db: Database) throws -> Item? {
        guard let existingRow = try Row.fetchOne(db, sql: "SELECT * FROM items WHERE id = ?", arguments: [id]) else {
            return nil
        }
        let existing = try RowMapping.item(existingRow)

        let quantity = try requireQuantity(input.quantity ?? existing.quantity)

        let name = input.name?.jsTrimmed() ?? existing.name
        // Only an explicitly blank name is an error: an unnamed drop-zone capture must stay movable.
        if input.name != nil, name.isEmpty { throw InventoryError.nameRequired }

        var next = existing
        next.containerId = input.containerId ?? existing.containerId
        next.name = name
        next.category = Self.merged(input.category, existing.category)
        next.quantity = quantity
        next.notes = Self.merged(input.notes, existing.notes)
        next.updatedAt = environment.now()

        var vanished = false
        try db.inSavepoint {
            var sql = """
                UPDATE items
                      SET container_id = ?, name = ?, category = ?, quantity = ?,
                          notes = ?, updated_at = ?, search_text = ?
                    WHERE id = ?
                """
            var arguments: StatementArguments = [
                next.containerId,
                next.name,
                next.category,
                next.quantity,
                next.notes,
                next.updatedAt,
                itemSearchText(name: next.name, category: next.category),
                id,
            ]
            if let expected = input.expectedUpdatedAt {
                sql += " AND updated_at = ?"
                arguments += [expected]
            }

            try db.execute(sql: sql, arguments: arguments)
            if db.changesCount == 0 {
                let current = try Int64.fetchOne(db, sql: "SELECT updated_at FROM items WHERE id = ?", arguments: [id])
                if input.expectedUpdatedAt != nil, let current {
                    throw ConflictError(updatedAt: current)
                }
                vanished = true
                return .commit
            }

            if let tags = input.tags {
                try replaceTags(itemId: id, tags: tags, in: db)
            }

            switch input.photo {
            case .unchanged:
                break
            case .clear:
                try db.execute(sql: "DELETE FROM item_photos WHERE item_id = ?", arguments: [id])
            case .set(let photo):
                try db.execute(sql: "DELETE FROM item_photos WHERE item_id = ?", arguments: [id])
                try insertPhoto(photo, id: environment.makeId(), itemId: id, createdAt: environment.now(), in: db)
            }
            return .commit
        }

        return vanished ? nil : next
    }

    /// Deletes the item; cascades remove its photo rows and tag links (the tags themselves stay).
    public func delete(_ id: String, in db: Database) throws -> DeletionResult {
        var result = DeletionResult.notDeleted
        try db.inSavepoint {
            let photos = try Row.fetchAll(
                db,
                sql: "SELECT uri, thumb_uri FROM item_photos WHERE item_id = ?",
                arguments: [id]
            )
            let orphaned = try RowMapping.photoUris(photos)
            try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [id])
            result = DeletionResult(deleted: db.changesCount > 0, orphanedPhotoUris: orphaned)
            return .commit
        }
        return result
    }

    // MARK: Helpers

    /// `undefined` keeps, `null` or blank clears, otherwise trimmed (RN `input.x?.trim() || null`).
    private static func merged(_ update: FieldUpdate<String>, _ current: String?) -> String? {
        switch update {
        case .unchanged: current
        case .clear: nil
        case .set(let value): value.jsTrimmed().nilIfEmpty
        }
    }

    private func insertPhoto(_ photo: ItemPhotoInput, id: String, itemId: String, createdAt: Int64, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO item_photos (id, item_id, uri, thumb_uri, width, height, byte_size, created_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [id, itemId, photo.uri, photo.thumbUri, photo.width, photo.height, photo.byteSize, createdAt]
        )
    }

    /// RN `upsertTags`: resolves tag names to ids in input order, creating the missing ones.
    ///
    /// Names are trimmed and folded; empty or repeated folded names are skipped. An existing
    /// tag keeps its first spelling. Repeats are detected by code points, like a JS `Set`.
    private func upsertTags(_ tags: [String], in db: Database) throws -> [String] {
        var ids: [String] = []
        var seen = Set<[UInt8]>()

        for raw in tags {
            let name = raw.jsTrimmed()
            let normalized = normalizedTagName(name)
            guard !normalized.isEmpty, seen.insert(Array(normalized.utf8)).inserted else { continue }

            if let existing = try String.fetchOne(
                db,
                sql: "SELECT id FROM tags WHERE normalized_name = ?",
                arguments: [normalized]
            ) {
                ids.append(existing)
                continue
            }

            let id = environment.makeId()
            try db.execute(
                sql: "INSERT INTO tags (id, name, normalized_name, created_at) VALUES (?, ?, ?, ?)",
                arguments: [id, name, normalized, environment.now()]
            )
            ids.append(id)
        }

        return ids
    }

    /// RN `replaceTags`: upsert first, then replace every link of the item.
    private func replaceTags(itemId: String, tags: [String], in db: Database) throws {
        let tagIds = try upsertTags(tags, in: db)
        try db.execute(sql: "DELETE FROM item_tags WHERE item_id = ?", arguments: [itemId])
        for tagId in tagIds {
            try db.execute(sql: "INSERT INTO item_tags (item_id, tag_id) VALUES (?, ?)", arguments: [itemId, tagId])
        }
    }
}
