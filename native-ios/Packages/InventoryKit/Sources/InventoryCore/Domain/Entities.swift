// RN: src/db/types.ts:34-108. The stored entities, field for field. Timestamps
// are integer epoch milliseconds. Property names are the TS names, so the
// synthesized `Codable` uses the household wire keys (a `nil` optional is
// encoded as an absent key).

/// A broad area where things are stored: a room, a garage, an attic.
public struct Space: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    /// An emoji, several, letters, or nothing; shown as stored.
    public var icon: String
    /// Any stored string; render through `HexColor.safeColor`.
    public var color: String
    public var createdAt: Int64
    public var updatedAt: Int64

    public init(id: String, name: String, icon: String, color: String, createdAt: Int64, updatedAt: Int64) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A box, drawer, shelf or cabinet inside exactly one space.
public struct Container: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var spaceId: String
    /// `nil` when blank (the repositories never store `''`).
    public var name: String?
    public var visualType: ContainerVisualType
    /// Human-friendly, unique, printed on labels, e.g. `BOX-4F2A`.
    public var shortCode: String
    public var createdAt: Int64
    public var updatedAt: Int64

    public init(
        id: String,
        spaceId: String,
        name: String?,
        visualType: ContainerVisualType,
        shortCode: String,
        createdAt: Int64,
        updatedAt: Int64
    ) {
        self.id = id
        self.spaceId = spaceId
        self.name = name
        self.visualType = visualType
        self.shortCode = shortCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A single physical thing stored in a container.
public struct Item: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var containerId: String
    /// `''` for an item captured but not yet named.
    public var name: String
    public var category: String?
    /// 0 or more; may exceed 9999 (only the stepper clamps).
    public var quantity: Int
    public var notes: String?
    public var createdAt: Int64
    public var updatedAt: Int64

    public init(
        id: String,
        containerId: String,
        name: String,
        category: String?,
        quantity: Int,
        notes: String?,
        createdAt: Int64,
        updatedAt: Int64
    ) {
        self.id = id
        self.containerId = containerId
        self.name = name
        self.category = category
        self.quantity = quantity
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A photo of an item. The schema allows several per item; the app uses the earliest.
public struct ItemPhoto: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var itemId: String
    /// A stored URI as written (absolute `file://`, `r2:` or http); resolve before use.
    public var uri: String
    /// Small copy for list rows; `nil` on rows captured before thumbnails.
    public var thumbUri: String?
    public var width: Int?
    public var height: Int?
    public var byteSize: Int?
    public var createdAt: Int64

    public init(
        id: String,
        itemId: String,
        uri: String,
        thumbUri: String?,
        width: Int?,
        height: Int?,
        byteSize: Int?,
        createdAt: Int64
    ) {
        self.id = id
        self.itemId = itemId
        self.uri = uri
        self.thumbUri = thumbUri
        self.width = width
        self.height = height
        self.byteSize = byteSize
        self.createdAt = createdAt
    }
}

/// A tag. `name` keeps the first spelling ever saved; `normalizedName` is its trimmed JS-lowercase form.
public struct Tag: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var normalizedName: String
    public var createdAt: Int64

    public init(id: String, name: String, normalizedName: String, createdAt: Int64) {
        self.id = id
        self.name = name
        self.normalizedName = normalizedName
        self.createdAt = createdAt
    }
}

/// Binds an opaque printed QR token to exactly one container.
public struct QrBinding: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    /// 32 lowercase hex characters.
    public var token: String
    public var containerId: String
    public var createdAt: Int64
    public var updatedAt: Int64

    public init(id: String, token: String, containerId: String, createdAt: Int64, updatedAt: Int64) {
        self.id = id
        self.token = token
        self.containerId = containerId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
