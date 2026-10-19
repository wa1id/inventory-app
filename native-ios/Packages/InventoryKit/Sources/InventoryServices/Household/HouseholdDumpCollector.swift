import Foundation
import GRDB
import InventoryCore
import InventoryNetwork
import InventoryStorage

/// Reads the local inventory as the id-preserving dump `POST /v1/import` takes
/// (RN: src/services/household/collectDump.ts; 04 §11.2).
///
/// Every row of the seven tables, unfiltered and unordered, snake_case mapped to camelCase:
/// the drop zone's system space and container are included, and so are shadow rows. Photo
/// rows carry their metadata only; their URIs stay on the phone (``localPhotoUris(from:)``)
/// and the bytes follow as uploads under the same ids.
///
/// Always the raw local database, never the shadowed repositories: this is what the phone
/// holds of its own.
public enum HouseholdDumpCollector {
    /// RN `collectHouseholdDump(db)`.
    public static func collectHouseholdDump(from store: DatabaseStore) async throws -> HouseholdDump {
        try await snapshot(from: store).dump
    }

    /// RN `localPhotoUris(db)`: each photo row's stored URI by photo id.
    public static func localPhotoUris(from store: DatabaseStore) async throws -> [String: String] {
        try await store.queue.read { db in try photoUris(db) }
    }

    /// The dump and the photo URIs from one read, so they describe the same moment. RN read them
    /// one after the other.
    static func snapshot(from store: DatabaseStore) async throws -> (dump: HouseholdDump, photoUris: [String: String]) {
        try await store.queue.read { db in (try dump(db), try photoUris(db)) }
    }

    // MARK: - Queries (collectDump.ts:15-144)

    static func dump(_ db: Database) throws -> HouseholdDump {
        let spaces = try Row.fetchAll(db, sql: "SELECT id, name, icon, color, kind, created_at, updated_at FROM spaces").map { row in
            HouseholdDump.SpaceRow(
                id: try row.decode(forColumn: "id"),
                name: try row.decode(forColumn: "name"),
                icon: try row.decode(forColumn: "icon"),
                color: try row.decode(forColumn: "color"),
                kind: RecordKind(rawValue: try row.decode(forColumn: "kind")),
                createdAt: try row.decode(forColumn: "created_at"),
                updatedAt: try row.decode(forColumn: "updated_at")
            )
        }
        let containers = try Row.fetchAll(
            db,
            sql: "SELECT id, space_id, name, visual_type, short_code, kind, created_at, updated_at FROM containers"
        ).map { row in
            HouseholdDump.ContainerRow(
                id: try row.decode(forColumn: "id"),
                spaceId: try row.decode(forColumn: "space_id"),
                name: try row.decode(forColumn: "name"),
                visualType: ContainerVisualType(rawValue: try row.decode(forColumn: "visual_type")),
                shortCode: try row.decode(forColumn: "short_code"),
                kind: RecordKind(rawValue: try row.decode(forColumn: "kind")),
                createdAt: try row.decode(forColumn: "created_at"),
                updatedAt: try row.decode(forColumn: "updated_at")
            )
        }
        let items = try Row.fetchAll(
            db,
            sql: "SELECT id, container_id, name, category, quantity, notes, search_text, created_at, updated_at FROM items"
        ).map { row in
            HouseholdDump.ItemRow(
                id: try row.decode(forColumn: "id"),
                containerId: try row.decode(forColumn: "container_id"),
                name: try row.decode(forColumn: "name"),
                category: try row.decode(forColumn: "category"),
                quantity: try row.decode(forColumn: "quantity"),
                notes: try row.decode(forColumn: "notes"),
                searchText: try row.decode(forColumn: "search_text"),
                createdAt: try row.decode(forColumn: "created_at"),
                updatedAt: try row.decode(forColumn: "updated_at")
            )
        }
        let tags = try Row.fetchAll(db, sql: "SELECT id, name, normalized_name, created_at FROM tags").map { row in
            Tag(
                id: try row.decode(forColumn: "id"),
                name: try row.decode(forColumn: "name"),
                normalizedName: try row.decode(forColumn: "normalized_name"),
                createdAt: try row.decode(forColumn: "created_at")
            )
        }
        let itemTags = try Row.fetchAll(db, sql: "SELECT item_id, tag_id FROM item_tags").map { row in
            HouseholdDump.ItemTagRow(itemId: try row.decode(forColumn: "item_id"), tagId: try row.decode(forColumn: "tag_id"))
        }
        let qrBindings = try Row.fetchAll(db, sql: "SELECT id, token, container_id, created_at, updated_at FROM qr_bindings").map { row in
            QrBinding(
                id: try row.decode(forColumn: "id"),
                token: try row.decode(forColumn: "token"),
                containerId: try row.decode(forColumn: "container_id"),
                createdAt: try row.decode(forColumn: "created_at"),
                updatedAt: try row.decode(forColumn: "updated_at")
            )
        }
        // `uri` is selected, as RN does, but it is not part of the dump.
        let photos = try Row.fetchAll(db, sql: "SELECT id, item_id, uri, width, height, byte_size, created_at FROM item_photos").map { row in
            HouseholdDump.PhotoRow(
                id: try row.decode(forColumn: "id"),
                itemId: try row.decode(forColumn: "item_id"),
                width: try row.decode(forColumn: "width"),
                height: try row.decode(forColumn: "height"),
                byteSize: try row.decode(forColumn: "byte_size"),
                createdAt: try row.decode(forColumn: "created_at")
            )
        }
        return HouseholdDump(
            spaces: spaces, containers: containers, items: items, tags: tags,
            itemTags: itemTags, qrBindings: qrBindings, photos: photos
        )
    }

    static func photoUris(_ db: Database) throws -> [String: String] {
        var uris: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, uri FROM item_photos") {
            uris[try row.decode(String.self, forColumn: "id")] = try row.decode(String.self, forColumn: "uri")
        }
        return uris
    }
}
