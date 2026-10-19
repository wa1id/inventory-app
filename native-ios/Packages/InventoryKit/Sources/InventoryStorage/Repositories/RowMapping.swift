import GRDB
import InventoryCore

// RN: the `to*` row mappers of src/repositories/*.ts. Rows are decoded with no
// coercion beyond SQLite's own; a value of the wrong type throws instead of
// trapping, so one odd row (an import, an older build) fails a read rather than
// crashing the app.

enum RowMapping {
    static func space(_ row: Row) throws -> Space {
        Space(
            id: try row.decode(forColumn: "id"),
            name: try row.decode(forColumn: "name"),
            icon: try row.decode(forColumn: "icon"),
            color: try row.decode(forColumn: "color"),
            createdAt: try row.decode(forColumn: "created_at"),
            updatedAt: try row.decode(forColumn: "updated_at")
        )
    }

    static func container(_ row: Row) throws -> Container {
        Container(
            id: try row.decode(forColumn: "id"),
            spaceId: try row.decode(forColumn: "space_id"),
            name: try row.decode(forColumn: "name"),
            // Any stored string round-trips (RN casts without checking).
            visualType: ContainerVisualType(rawValue: try row.decode(forColumn: "visual_type")),
            shortCode: try row.decode(forColumn: "short_code"),
            createdAt: try row.decode(forColumn: "created_at"),
            updatedAt: try row.decode(forColumn: "updated_at")
        )
    }

    static func containerWithCounts(_ row: Row) throws -> ContainerWithCounts {
        ContainerWithCounts(
            container: try container(row),
            itemCount: try row.decode(forColumn: "item_count"),
            qrToken: try row.decode(forColumn: "qr_token")
        )
    }

    static func item(_ row: Row) throws -> Item {
        Item(
            id: try row.decode(forColumn: "id"),
            containerId: try row.decode(forColumn: "container_id"),
            name: try row.decode(forColumn: "name"),
            category: try row.decode(forColumn: "category"),
            quantity: try row.decode(forColumn: "quantity"),
            notes: try row.decode(forColumn: "notes"),
            createdAt: try row.decode(forColumn: "created_at"),
            updatedAt: try row.decode(forColumn: "updated_at")
        )
    }

    /// RN `toItemWithContext`, over a row of ``itemContextSelect``.
    static func itemWithContext(_ row: Row) throws -> ItemWithContext {
        ItemWithContext(
            item: try item(row),
            photoId: try row.decode(forColumn: "photo_id"),
            photoUri: try row.decode(forColumn: "photo_uri"),
            photoThumbUri: try row.decode(forColumn: "photo_thumb_uri"),
            tags: splitTagNames(try row.decode(forColumn: "tag_names")),
            spaceId: try row.decode(forColumn: "space_id"),
            spaceName: try row.decode(forColumn: "space_name"),
            spaceIcon: try row.decode(forColumn: "space_icon"),
            spaceColor: try row.decode(forColumn: "space_color"),
            containerName: try row.decode(forColumn: "container_name"),
            containerShortCode: try row.decode(forColumn: "container_short_code")
        )
    }

    static func itemPhoto(_ row: Row) throws -> ItemPhoto {
        ItemPhoto(
            id: try row.decode(forColumn: "id"),
            itemId: try row.decode(forColumn: "item_id"),
            uri: try row.decode(forColumn: "uri"),
            thumbUri: try row.decode(forColumn: "thumb_uri"),
            width: try row.decode(forColumn: "width"),
            height: try row.decode(forColumn: "height"),
            byteSize: try row.decode(forColumn: "byte_size"),
            createdAt: try row.decode(forColumn: "created_at")
        )
    }

    static func qrBinding(_ row: Row) throws -> QrBinding {
        QrBinding(
            id: try row.decode(forColumn: "id"),
            token: try row.decode(forColumn: "token"),
            containerId: try row.decode(forColumn: "container_id"),
            createdAt: try row.decode(forColumn: "created_at"),
            updatedAt: try row.decode(forColumn: "updated_at")
        )
    }

    /// `[uri, thumb_uri]` per photo row, `NULL`s dropped (the orphaned files after a delete).
    static func photoUris(_ rows: [Row]) throws -> [String] {
        try rows.flatMap { row -> [String] in
            let uri: String? = try row.decode(forColumn: "uri")
            let thumb: String? = try row.decode(forColumn: "thumb_uri")
            return [uri, thumb].compactMap { $0 }
        }
    }
}

/// Shared projection for every item list (RN `ITEM_CONTEXT_SELECT`, src/repositories/items.ts:72-91).
///
/// The primary photo is the earliest by `created_at`. Tags are joined with U+001F (`char(31)`)
/// in whatever order the plan yields (tag id order in practice); they are not sorted.
let itemContextSelect = """

      SELECT i.*,
             (SELECT p.id FROM item_photos p WHERE p.item_id = i.id
               ORDER BY p.created_at ASC LIMIT 1) AS photo_id,
             (SELECT p.uri FROM item_photos p WHERE p.item_id = i.id
               ORDER BY p.created_at ASC LIMIT 1) AS photo_uri,
             (SELECT p.thumb_uri FROM item_photos p WHERE p.item_id = i.id
               ORDER BY p.created_at ASC LIMIT 1) AS photo_thumb_uri,
             (SELECT GROUP_CONCAT(t.name, char(31)) FROM item_tags it
                JOIN tags t ON t.id = it.tag_id WHERE it.item_id = i.id) AS tag_names,
             c.space_id AS space_id,
             s.name AS space_name,
             s.icon AS space_icon,
             s.color AS space_color,
             c.name AS container_name,
             c.short_code AS container_short_code
        FROM items i
        JOIN containers c ON c.id = i.container_id
        JOIN spaces s ON s.id = c.space_id

    """

extension String {
    /// `nil` for an empty string (JS `value || null` after a trim).
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
