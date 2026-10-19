import Foundation
import GRDB
import InventoryCore
import InventoryStorage

/// Writes this phone's successful household writes into local SQLite (RN: the `upsert*`
/// helpers and `shadow()` of src/services/household/shadow.ts; 04 §7).
///
/// The SQL is shadow.ts's, statement for statement, with the same arguments, so the shadow rows
/// are the ones the RN build wrote (`ShadowParityTests` replays a script through both). Two
/// harmless differences: each mirror runs in one transaction, so a failure leaves nothing half
/// written where RN could keep the first statements of a multi-statement mirror; and the
/// mirror runs in a task of its own, so a caller that goes away after the server write does
/// not cancel it.
///
/// A mirror never fails the household write: the home server is the source of truth. A failure
/// (a foreign key the local database lacks, a short code another local container holds) only
/// logs `household_shadow_failed` as an event with the error's class.
struct HouseholdShadowMirror: Sendable {
    let queue: DatabaseQueue
    /// RN `Date.now()` for `item_photos.remote_synced_at` and a new tag's `created_at`.
    let now: @Sendable () -> Int64
    /// RN `newId()` for a new tag.
    let makeId: @Sendable () -> String
    let telemetry: TelemetryReporter

    /// RN `shadow(work)`: runs the mirror, swallows and reports any error.
    func run(_ work: @escaping @Sendable (Database) throws -> Void) async {
        let queue = queue
        let mirror = Task<Void, any Error> {
            try await queue.write { db in try work(db) }
        }
        do {
            try await mirror.value
        } catch {
            telemetry.event("household_shadow_failed", ["errorClass": .string(errorClass(of: error))])
        }
    }

    // MARK: - Statements (shadow.ts:116-259)

    /// shadow.ts:116-127.
    static func upsertSpace(_ space: Space, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO spaces (id, name, icon, color, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  name = excluded.name,
                  icon = excluded.icon,
                  color = excluded.color,
                  updated_at = excluded.updated_at
                """,
            arguments: [space.id, space.name, space.icon, space.color, space.createdAt, space.updatedAt]
        )
    }

    /// shadow.ts:129-150.
    static func upsertContainer(_ container: Container, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO containers
                  (id, space_id, name, visual_type, short_code, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  space_id = excluded.space_id,
                  name = excluded.name,
                  visual_type = excluded.visual_type,
                  short_code = excluded.short_code,
                  updated_at = excluded.updated_at
                """,
            arguments: [
                container.id, container.spaceId, container.name, container.visualType.rawValue,
                container.shortCode, container.createdAt, container.updatedAt,
            ]
        )
    }

    /// shadow.ts:152-178. `search_text` is `` `${name} ${category ?? ''}`.trim().toLowerCase() ``.
    static func upsertItemRow(_ item: Item, in db: Database) throws {
        let searchText = itemSearchText(name: item.name, category: item.category)
        try db.execute(
            sql: """
                INSERT INTO items
                  (id, container_id, name, category, quantity, notes, created_at, updated_at, search_text)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  container_id = excluded.container_id,
                  name = excluded.name,
                  category = excluded.category,
                  quantity = excluded.quantity,
                  notes = excluded.notes,
                  updated_at = excluded.updated_at,
                  search_text = excluded.search_text
                """,
            arguments: [
                item.id, item.containerId, item.name, item.category, item.quantity, item.notes,
                item.createdAt, item.updatedAt, searchText,
            ]
        )
    }

    /// shadow.ts:180-244: the item with its space, container, photo and tags, from the
    /// `ItemWithContext` the server answered a create with.
    ///
    /// Parity, on purpose (04 §7): the space's `updated_at` and the container's take the item's
    /// timestamps, the container's `visual_type` becomes `box` (even the drop zone's, seeded as
    /// `other`), an empty short code becomes `CTR-` and the id's first four characters
    /// upper-cased, `kind` is never written, and tags are found by their plain lower-cased name.
    func upsertItemGraph(_ item: ItemWithContext, in db: Database) throws {
        try Self.upsertSpace(
            Space(
                id: item.spaceId, name: item.spaceName, icon: item.spaceIcon, color: item.spaceColor,
                createdAt: item.createdAt, updatedAt: item.updatedAt
            ),
            in: db
        )
        try Self.upsertContainer(
            Container(
                id: item.containerId,
                spaceId: item.spaceId,
                name: item.containerName,
                visualType: .box,
                shortCode: item.containerShortCode.isEmpty ? Self.fallbackShortCode(item.containerId) : item.containerShortCode,
                createdAt: item.createdAt,
                updatedAt: item.updatedAt
            ),
            in: db
        )
        try Self.upsertItemRow(item.item, in: db)

        // RN `if (item.photoId && item.photoUri)`: empty strings count as none.
        if let photoId = item.photoId, !photoId.isEmpty, let photoUri = item.photoUri, !photoUri.isEmpty {
            try db.execute(
                sql: """
                    INSERT INTO item_photos
                      (id, item_id, uri, thumb_uri, width, height, byte_size, created_at, remote_synced_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      uri = excluded.uri,
                      thumb_uri = excluded.thumb_uri,
                      remote_synced_at = excluded.remote_synced_at
                    """,
                arguments: [
                    photoId, item.id, photoUri, item.photoThumbUri, nil as Int?, nil as Int?, nil as Int?,
                    item.createdAt, now(),
                ]
            )
        }

        try db.execute(sql: "DELETE FROM item_tags WHERE item_id = ?", arguments: [item.id])
        for raw in item.tags {
            let name = raw.jsTrimmed()
            let normalized = normalizedTagName(raw)
            if normalized.isEmpty { continue }
            let existing = try String.fetchOne(db, sql: "SELECT id FROM tags WHERE normalized_name = ?", arguments: [normalized])
            let tagId = existing ?? makeId()
            if existing == nil {
                try db.execute(
                    sql: "INSERT INTO tags (id, name, normalized_name, created_at) VALUES (?, ?, ?, ?)",
                    arguments: [tagId, name, normalized, now()]
                )
            }
            try db.execute(sql: "INSERT OR IGNORE INTO item_tags (item_id, tag_id) VALUES (?, ?)", arguments: [item.id, tagId])
        }
    }

    /// shadow.ts:246-259: the binding replaces any other with its token or on its container.
    static func upsertQr(_ binding: QrBinding, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM qr_bindings WHERE token = ? OR container_id = ?",
            arguments: [binding.token, binding.containerId]
        )
        try db.execute(
            sql: """
                INSERT INTO qr_bindings (id, token, container_id, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [binding.id, binding.token, binding.containerId, binding.createdAt, binding.updatedAt]
        )
    }

    /// JS `` `CTR-${containerId.slice(0, 4).toUpperCase()}` ``: four UTF-16 code units.
    static func fallbackShortCode(_ containerId: String) -> String {
        let prefix = String(decoding: Array(containerId.utf16.prefix(4)), as: UTF16.self)
        return "CTR-" + prefix.jsUppercased()
    }
}
