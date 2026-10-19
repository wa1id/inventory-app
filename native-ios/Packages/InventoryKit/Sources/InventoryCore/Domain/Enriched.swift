// RN: src/db/types.ts:110-143 and src/repositories/search.ts:11-30. The TS
// types `extends` an entity; here they wrap it and forward its fields through
// dynamic member lookup (`row.name` works as in TS, `row.item` gives the entity).
// `Codable` stays flat, matching the household JSON.

/// A space with the counts the dashboard shows (RN `SpaceWithCounts`).
@dynamicMemberLookup
public struct SpaceWithCounts: Sendable, Hashable, Identifiable {
    public var space: Space
    public var containerCount: Int
    /// Item rows (quantity-0 items count).
    public var itemCount: Int

    public init(space: Space, containerCount: Int, itemCount: Int) {
        self.space = space
        self.containerCount = containerCount
        self.itemCount = itemCount
    }

    public var id: String { space.id }

    public subscript<Value>(dynamicMember keyPath: WritableKeyPath<Space, Value>) -> Value {
        get { space[keyPath: keyPath] }
        set { space[keyPath: keyPath] = newValue }
    }
}

/// A container with its item count and newest QR binding (RN `ContainerWithCounts`).
@dynamicMemberLookup
public struct ContainerWithCounts: Sendable, Hashable, Identifiable {
    public var container: Container
    public var itemCount: Int
    /// Token of the newest binding, or `nil` when the container has no label.
    public var qrToken: String?

    public init(container: Container, itemCount: Int, qrToken: String?) {
        self.container = container
        self.itemCount = itemCount
        self.qrToken = qrToken
    }

    public var id: String { container.id }

    public subscript<Value>(dynamicMember keyPath: WritableKeyPath<Container, Value>) -> Value {
        get { container[keyPath: keyPath] }
        set { container[keyPath: keyPath] = newValue }
    }
}

/// A container with its space name and item count, as `containers.listAllWithSpace()` returns it
/// (RN `Container & { spaceName, itemCount }`); the place picker's source.
@dynamicMemberLookup
public struct ContainerWithSpace: Sendable, Hashable, Identifiable {
    public var container: Container
    public var spaceName: String
    public var itemCount: Int

    public init(container: Container, spaceName: String, itemCount: Int) {
        self.container = container
        self.spaceName = spaceName
        self.itemCount = itemCount
    }

    public var id: String { container.id }

    public subscript<Value>(dynamicMember keyPath: WritableKeyPath<Container, Value>) -> Value {
        get { container[keyPath: keyPath] }
        set { container[keyPath: keyPath] = newValue }
    }
}

/// An item plus what every list row needs: primary photo, tags and location (RN `ItemWithContext`).
@dynamicMemberLookup
public struct ItemWithContext: Sendable, Hashable, Identifiable {
    public var item: Item
    /// Earliest photo's row id, or `nil` without a photo.
    public var photoId: String?
    public var photoUri: String?
    /// `nil` for photos captured before thumbnails; consumers fall back to `photoUri`.
    public var photoThumbUri: String?
    /// Tag display names, in tag-id order (the SQL's order; not sorted).
    public var tags: [String]
    public var spaceId: String
    public var spaceName: String
    public var spaceIcon: String
    public var spaceColor: String
    public var containerName: String?
    public var containerShortCode: String

    public init(
        item: Item,
        photoId: String?,
        photoUri: String?,
        photoThumbUri: String?,
        tags: [String],
        spaceId: String,
        spaceName: String,
        spaceIcon: String,
        spaceColor: String,
        containerName: String?,
        containerShortCode: String
    ) {
        self.item = item
        self.photoId = photoId
        self.photoUri = photoUri
        self.photoThumbUri = photoThumbUri
        self.tags = tags
        self.spaceId = spaceId
        self.spaceName = spaceName
        self.spaceIcon = spaceIcon
        self.spaceColor = spaceColor
        self.containerName = containerName
        self.containerShortCode = containerShortCode
    }

    public var id: String { item.id }

    /// The item's container (also reachable as a dynamic member; spelled out for ``PlaceLike``).
    public var containerId: String {
        get { item.containerId }
        set { item.containerId = newValue }
    }

    public subscript<Value>(dynamicMember keyPath: WritableKeyPath<Item, Value>) -> Value {
        get { item[keyPath: keyPath] }
        set { item[keyPath: keyPath] = newValue }
    }
}

extension ItemWithContext: PlaceLike {}

/// Why an item showed up in search results (RN `ItemMatchKind`).
public enum ItemMatchKind: String, Sendable, Hashable, Codable {
    /// The item's own fields matched every term.
    case direct
    /// Some term matched only the item's space or container.
    case location
}

/// An item search hit (RN `ItemSearchResult`).
@dynamicMemberLookup
public struct ItemSearchResult: Sendable, Hashable, Identifiable {
    public var item: ItemWithContext
    public var matchKind: ItemMatchKind

    public init(item: ItemWithContext, matchKind: ItemMatchKind) {
        self.item = item
        self.matchKind = matchKind
    }

    public var id: String { item.id }

    public subscript<Value>(dynamicMember keyPath: WritableKeyPath<ItemWithContext, Value>) -> Value {
        get { item[keyPath: keyPath] }
        set { item[keyPath: keyPath] = newValue }
    }
}

/// A space or container whose name or code matched a search (RN `LocationSearchResult`).
public struct LocationSearchResult: Sendable, Hashable, Codable, Identifiable {
    /// `space` or `container` (RN `kind`).
    public enum Kind: String, Sendable, Hashable, Codable {
        case space
        case container
    }

    public var kind: Kind
    public var id: String
    public var title: String
    /// Hard-coded English in the repository, for parity with the home server.
    public var subtitle: String
    public var spaceId: String
    public var itemCount: Int

    public init(kind: Kind, id: String, title: String, subtitle: String, spaceId: String, itemCount: Int) {
        self.kind = kind
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.spaceId = spaceId
        self.itemCount = itemCount
    }
}

/// Everything a search returns (RN `SearchResults`).
public struct SearchResults: Sendable, Hashable, Codable {
    public var terms: [String]
    public var locations: [LocationSearchResult]
    public var items: [ItemSearchResult]

    public init(terms: [String], locations: [LocationSearchResult], items: [ItemSearchResult]) {
        self.terms = terms
        self.locations = locations
        self.items = items
    }

    /// The result of a blank query.
    public static let empty = SearchResults(terms: [], locations: [], items: [])
}

/// What a scanned code resolves to (RN `ScanOutcome`, `src/repositories/qr.ts:48-51`).
public enum ScanOutcome: Sendable, Hashable {
    /// The token is bound to this container.
    case bound(container: Container, token: String)
    /// Our token format, but no container has it yet.
    case unknown(token: String)
    /// Not one of our codes.
    case invalid(raw: String)
}

// MARK: - Flat Codable

extension SpaceWithCounts: Codable {
    private enum CodingKeys: String, CodingKey { case containerCount, itemCount }

    public init(from decoder: any Decoder) throws {
        space = try Space(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        containerCount = try container.decode(Int.self, forKey: .containerCount)
        itemCount = try container.decode(Int.self, forKey: .itemCount)
    }

    public func encode(to encoder: any Encoder) throws {
        try space.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(containerCount, forKey: .containerCount)
        try container.encode(itemCount, forKey: .itemCount)
    }
}

extension ContainerWithCounts: Codable {
    private enum CodingKeys: String, CodingKey { case itemCount, qrToken }

    public init(from decoder: any Decoder) throws {
        container = try Container(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        itemCount = try values.decode(Int.self, forKey: .itemCount)
        qrToken = try values.decodeIfPresent(String.self, forKey: .qrToken)
    }

    public func encode(to encoder: any Encoder) throws {
        try container.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(itemCount, forKey: .itemCount)
        try values.encodeIfPresent(qrToken, forKey: .qrToken)
    }
}

extension ContainerWithSpace: Codable {
    private enum CodingKeys: String, CodingKey { case spaceName, itemCount }

    public init(from decoder: any Decoder) throws {
        container = try Container(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        spaceName = try values.decode(String.self, forKey: .spaceName)
        itemCount = try values.decode(Int.self, forKey: .itemCount)
    }

    public func encode(to encoder: any Encoder) throws {
        try container.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(spaceName, forKey: .spaceName)
        try values.encode(itemCount, forKey: .itemCount)
    }
}

extension ItemWithContext: Codable {
    private enum CodingKeys: String, CodingKey {
        case photoId, photoUri, photoThumbUri, tags, spaceId, spaceName, spaceIcon, spaceColor
        case containerName, containerShortCode
    }

    public init(from decoder: any Decoder) throws {
        item = try Item(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        photoId = try values.decodeIfPresent(String.self, forKey: .photoId)
        photoUri = try values.decodeIfPresent(String.self, forKey: .photoUri)
        photoThumbUri = try values.decodeIfPresent(String.self, forKey: .photoThumbUri)
        tags = try values.decode([String].self, forKey: .tags)
        spaceId = try values.decode(String.self, forKey: .spaceId)
        spaceName = try values.decode(String.self, forKey: .spaceName)
        spaceIcon = try values.decode(String.self, forKey: .spaceIcon)
        spaceColor = try values.decode(String.self, forKey: .spaceColor)
        containerName = try values.decodeIfPresent(String.self, forKey: .containerName)
        containerShortCode = try values.decode(String.self, forKey: .containerShortCode)
    }

    public func encode(to encoder: any Encoder) throws {
        try item.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(photoId, forKey: .photoId)
        try values.encodeIfPresent(photoUri, forKey: .photoUri)
        try values.encodeIfPresent(photoThumbUri, forKey: .photoThumbUri)
        try values.encode(tags, forKey: .tags)
        try values.encode(spaceId, forKey: .spaceId)
        try values.encode(spaceName, forKey: .spaceName)
        try values.encode(spaceIcon, forKey: .spaceIcon)
        try values.encode(spaceColor, forKey: .spaceColor)
        try values.encodeIfPresent(containerName, forKey: .containerName)
        try values.encode(containerShortCode, forKey: .containerShortCode)
    }
}

extension ItemSearchResult: Codable {
    private enum CodingKeys: String, CodingKey { case matchKind }

    public init(from decoder: any Decoder) throws {
        item = try ItemWithContext(from: decoder)
        matchKind = try decoder.container(keyedBy: CodingKeys.self).decode(ItemMatchKind.self, forKey: .matchKind)
    }

    public func encode(to encoder: any Encoder) throws {
        try item.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(matchKind, forKey: .matchKind)
    }
}
