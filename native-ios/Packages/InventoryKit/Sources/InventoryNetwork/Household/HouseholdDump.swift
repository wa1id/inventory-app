import Foundation
import InventoryCore

/// The id-preserving snapshot `POST /v1/import` takes (RN `HouseholdDump`,
/// src/services/household/dump.ts, filled by collectDump.ts), row for row as the
/// phone's tables hold them.
///
/// It encodes the way `JSON.stringify` writes RN's object: every key is present
/// and a NULL column is an explicit `null`. That is load-bearing, not cosmetic:
/// the home server binds `photo.width`, `photo.height` and `photo.byteSize`
/// straight into SQLite (home-server/src/importer.ts:174-176), and node:sqlite
/// refuses an `undefined` parameter, so a photo row without those keys fails the
/// whole import with a 400. Synthesized `Encodable` would leave nil keys out.
public struct HouseholdDump: Codable, Sendable, Hashable {
    public var spaces: [SpaceRow]
    public var containers: [ContainerRow]
    public var items: [ItemRow]
    /// RN `DumpTag`: the same fields as the domain ``Tag``.
    public var tags: [Tag]
    public var itemTags: [ItemTagRow]
    /// RN `DumpQrBinding`: the same fields as the domain ``QrBinding``.
    public var qrBindings: [QrBinding]
    public var photos: [PhotoRow]

    public init(
        spaces: [SpaceRow] = [],
        containers: [ContainerRow] = [],
        items: [ItemRow] = [],
        tags: [Tag] = [],
        itemTags: [ItemTagRow] = [],
        qrBindings: [QrBinding] = [],
        photos: [PhotoRow] = []
    ) {
        self.spaces = spaces
        self.containers = containers
        self.items = items
        self.tags = tags
        self.itemTags = itemTags
        self.qrBindings = qrBindings
        self.photos = photos
    }

    /// RN `DumpSpace`; the drop zone's system space included.
    public struct SpaceRow: Codable, Sendable, Hashable {
        public var id: String
        public var name: String
        public var icon: String
        public var color: String
        public var kind: RecordKind
        public var createdAt: Int64
        public var updatedAt: Int64

        public init(id: String, name: String, icon: String, color: String, kind: RecordKind, createdAt: Int64, updatedAt: Int64) {
            self.id = id
            self.name = name
            self.icon = icon
            self.color = color
            self.kind = kind
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    /// RN `DumpContainer`; the drop zone's system container included.
    public struct ContainerRow: Codable, Sendable, Hashable {
        public var id: String
        public var spaceId: String
        public var name: String?
        public var visualType: ContainerVisualType
        public var shortCode: String
        public var kind: RecordKind
        public var createdAt: Int64
        public var updatedAt: Int64

        public init(
            id: String,
            spaceId: String,
            name: String?,
            visualType: ContainerVisualType,
            shortCode: String,
            kind: RecordKind,
            createdAt: Int64,
            updatedAt: Int64
        ) {
            self.id = id
            self.spaceId = spaceId
            self.name = name
            self.visualType = visualType
            self.shortCode = shortCode
            self.kind = kind
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        private enum CodingKeys: String, CodingKey {
            case id, spaceId, name, visualType, shortCode, kind, createdAt, updatedAt
        }

        public func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id, forKey: .id)
            try values.encode(spaceId, forKey: .spaceId)
            try values.encodeNullable(name, forKey: .name)
            try values.encode(visualType, forKey: .visualType)
            try values.encode(shortCode, forKey: .shortCode)
            try values.encode(kind, forKey: .kind)
            try values.encode(createdAt, forKey: .createdAt)
            try values.encode(updatedAt, forKey: .updatedAt)
        }
    }

    /// RN `DumpItem`, with the stored `search_text` the importer keeps.
    public struct ItemRow: Codable, Sendable, Hashable {
        public var id: String
        public var containerId: String
        public var name: String
        public var category: String?
        public var quantity: Int
        public var notes: String?
        public var searchText: String
        public var createdAt: Int64
        public var updatedAt: Int64

        public init(
            id: String,
            containerId: String,
            name: String,
            category: String?,
            quantity: Int,
            notes: String?,
            searchText: String,
            createdAt: Int64,
            updatedAt: Int64
        ) {
            self.id = id
            self.containerId = containerId
            self.name = name
            self.category = category
            self.quantity = quantity
            self.notes = notes
            self.searchText = searchText
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        private enum CodingKeys: String, CodingKey {
            case id, containerId, name, category, quantity, notes, searchText, createdAt, updatedAt
        }

        public func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id, forKey: .id)
            try values.encode(containerId, forKey: .containerId)
            try values.encode(name, forKey: .name)
            try values.encodeNullable(category, forKey: .category)
            try values.encode(quantity, forKey: .quantity)
            try values.encodeNullable(notes, forKey: .notes)
            try values.encode(searchText, forKey: .searchText)
            try values.encode(createdAt, forKey: .createdAt)
            try values.encode(updatedAt, forKey: .updatedAt)
        }
    }

    /// RN `DumpItemTag`.
    public struct ItemTagRow: Codable, Sendable, Hashable {
        public var itemId: String
        public var tagId: String

        public init(itemId: String, tagId: String) {
            self.itemId = itemId
            self.tagId = tagId
        }
    }

    /// RN `DumpPhoto`: the row's metadata only. The bytes follow as
    /// ``HouseholdClient/importPhoto(id:bytes:)`` under the same id, and the server
    /// writes its own `r2:` URIs.
    public struct PhotoRow: Codable, Sendable, Hashable {
        public var id: String
        public var itemId: String
        public var width: Int?
        public var height: Int?
        public var byteSize: Int?
        public var createdAt: Int64

        public init(id: String, itemId: String, width: Int?, height: Int?, byteSize: Int?, createdAt: Int64) {
            self.id = id
            self.itemId = itemId
            self.width = width
            self.height = height
            self.byteSize = byteSize
            self.createdAt = createdAt
        }

        private enum CodingKeys: String, CodingKey {
            case id, itemId, width, height, byteSize, createdAt
        }

        public func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id, forKey: .id)
            try values.encode(itemId, forKey: .itemId)
            // Never omitted: the importer binds these three directly (see HouseholdDump).
            try values.encodeNullable(width, forKey: .width)
            try values.encodeNullable(height, forKey: .height)
            try values.encodeNullable(byteSize, forKey: .byteSize)
            try values.encode(createdAt, forKey: .createdAt)
        }
    }
}

extension KeyedEncodingContainer {
    /// `JSON.stringify` of a nullable field: the value, or an explicit `null`; never an absent key.
    mutating func encodeNullable<Value: Encodable>(_ value: Value?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}
