import InventoryCore
import InventoryStrings

// RN: src/ui/components/PlaceRows.tsx, LocationLine.tsx and src/ui/item/WhereCard.tsx. What the
// place rows, the location line and the where card say (06 §5.7, 07 §4.3-4.5).

/// A container as its row needs it (RN `ContainerRowData`).
public struct ContainerRowData: Sendable, Hashable, Identifiable {
    public var id: String
    /// Nil when unnamed (the row then says "Unnamed bag", quietly).
    public var name: String?
    public var shortCode: String
    /// Kept as stored: an unknown type draws and reads as `other`.
    public var visualType: ContainerVisualType
    public var itemCount: Int
    /// Set when the container has a QR label (" · QR label" in a space's list).
    public var qrToken: String?
    public var spaceId: String?
    /// Set in search, where the row's second line is the space it is in.
    public var spaceName: String?
    public var spaceColor: String?

    public init(
        id: String,
        name: String?,
        shortCode: String,
        visualType: ContainerVisualType,
        itemCount: Int,
        qrToken: String? = nil,
        spaceId: String? = nil,
        spaceName: String? = nil,
        spaceColor: String? = nil
    ) {
        self.id = id
        self.name = name
        self.shortCode = shortCode
        self.visualType = visualType
        self.itemCount = itemCount
        self.qrToken = qrToken
        self.spaceId = spaceId
        self.spaceName = spaceName
        self.spaceColor = spaceColor
    }

    /// A container in a space's list.
    public init(_ row: ContainerWithCounts) {
        self.init(
            id: row.id,
            name: row.name,
            shortCode: row.shortCode,
            visualType: row.visualType,
            itemCount: row.itemCount,
            qrToken: row.qrToken,
            spaceId: row.spaceId
        )
    }
}

/// Where a container row is shown (RN `ContainerRowProps.context`).
public enum ContainerRowContext: Sendable, Hashable {
    /// In its space: the second line is what it holds (and " · QR label").
    case space
    /// In search: what it holds is the aside; the second line is its space.
    case search
}

/// A location as a row draws it, for search rows that name only the space.
public struct RowPlace: PlaceLike, Sendable, Hashable {
    public var containerId: String
    public var containerName: String?
    public var containerShortCode: String
    public var spaceId: String
    public var spaceName: String
    public var spaceColor: String

    public init(containerId: String, containerName: String?, containerShortCode: String, spaceId: String, spaceName: String, spaceColor: String) {
        self.containerId = containerId
        self.containerName = containerName
        self.containerShortCode = containerShortCode
        self.spaceId = spaceId
        self.spaceName = spaceName
        self.spaceColor = spaceColor
    }

    /// The same location as any `PlaceLike`.
    public init(_ place: some PlaceLike) {
        self.init(
            containerId: place.containerId,
            containerName: place.containerName,
            containerShortCode: place.containerShortCode,
            spaceId: place.spaceId,
            spaceName: place.spaceName,
            spaceColor: place.spaceColor
        )
    }
}

/// The words and identifiers of the place rows.
public enum PlaceRowText {
    /// "Box" … "Container"; an unknown stored type reads as "Container" (RN `typeName`).
    public static func typeName(_ visualType: ContainerVisualType) -> String {
        L10n.Entities.TypeNames[visualType.rawValue] ?? L10n.Entities.TypeNames.other
    }

    /// The container's name, or "Unnamed bag" for its type (RN `label` in `ContainerRow`).
    public static func containerLabel(name: String?, visualType: ContainerVisualType) -> String {
        name ?? L10n.Entities.unnamedContainer(typeName: typeName(visualType))
    }

    /// A container's second line in its space: "3 items", plus " · QR label" when it has one.
    public static func containerMeta(itemCount: Int, hasLabel: Bool) -> String {
        let items = L10n.Entities.contents(count: itemCount)
        return hasLabel ? items + L10n.Rows.separator + L10n.Rows.qrLabel : items
    }

    /// "Tool chest, Cabinet, label C A B, J 9 2 R. 3 items." with " Has a QR label" when
    /// `hasLabel` (RN `rows.containerA11y`). Search rows never pass a token, so never say so.
    public static func containerAccessibilityLabel(_ container: ContainerRowData) -> String {
        L10n.Rows.containerA11y(
            label: containerLabel(name: container.name, visualType: container.visualType),
            type: typeName(container.visualType),
            spelled: spellCode(container.shortCode),
            items: L10n.Entities.contents(count: container.itemCount),
            hasLabel: container.qrToken != nil
        )
    }

    /// "2 containers and 5 items", "No containers yet", … (RN `entities.spaceCounts`).
    public static func spaceCounts(containers: Int, items: Int) -> String {
        L10n.Entities.spaceCounts(containers: containers, items: items)
    }

    /// "Garage. 2 containers and 5 items." (RN `rows.spaceA11y`).
    public static func spaceAccessibilityLabel(name: String, containers: Int, items: Int) -> String {
        L10n.Rows.spaceA11y(name: name, counts: spaceCounts(containers: containers, items: items))
    }

    /// A search hit shown as given: "<title>. <subtitle>" (RN `PlaceRow`'s fallback).
    public static func hitAccessibilityLabel(_ hit: LocationSearchResult) -> String {
        "\(hit.title). \(hit.subtitle)"
    }

    /// The location line's container text: its name; else, where no tape is drawn (the where
    /// card), its code as text; else nothing beside the tape (RN LocationLine.tsx:134). An empty
    /// name stays empty (JS `??` keeps `''`).
    public static func locationContainerLabel(_ place: some PlaceLike, showsTape: Bool) -> String? {
        place.containerName ?? (showsTape ? nil : place.containerShortCode)
    }

    /// Whether a place is the drop zone, which is always the tray and the words "Drop zone".
    public static func isDropZone(_ place: some PlaceLike) -> Bool {
        EntityText.same(place.containerId, DropZone.containerId)
    }

    /// `space-row-<id>`.
    public static func spaceIdentifier(_ id: String) -> String { "space-row-\(id)" }
    /// `container-row-<id>`.
    public static func containerIdentifier(_ id: String) -> String { "container-row-\(id)" }
    /// `place-row-<hit id>`, the search hit's wrapper.
    public static func placeIdentifier(_ hitId: String) -> String { "place-row-\(hitId)" }
}

/// What a search hit for a place draws, joined with the full lists (RN `PlaceRow`).
public enum PlaceRowContent: Sendable, Hashable {
    /// A known space: its row, tile 48.
    case space(SpaceWithCounts)
    /// A known container: its search row (the item count is the hit's own).
    case container(ContainerRowData)
    /// The join is missing (a list still loading, a place made a moment ago): the hit's own
    /// title and preformatted subtitle, never parsed.
    case hit(LocationSearchResult)

    /// Joins a hit with `spaces.listWithCounts()` and `containers.listAllWithSpace()` by id.
    public static func resolve(
        _ hit: LocationSearchResult,
        spaces: [String: SpaceWithCounts],
        containers: [String: ContainerWithSpace]
    ) -> PlaceRowContent {
        let space = spaces[hit.kind == .space ? hit.id : hit.spaceId]
        if hit.kind == .space, let space { return .space(space) }
        if hit.kind == .container, let container = containers[hit.id] {
            return .container(
                ContainerRowData(
                    id: container.id,
                    name: container.name,
                    shortCode: container.shortCode,
                    visualType: container.visualType,
                    itemCount: hit.itemCount,
                    spaceId: container.spaceId,
                    spaceName: container.spaceName,
                    spaceColor: space?.color
                )
            )
        }
        return .hit(hit)
    }
}

/// What the item screen's "Kept in" card says (RN `WhereCard`).
public struct WhereCardCopy: Sendable, Hashable {
    public let isDropZone: Bool
    /// "File it…" in the drop zone, else "Move…".
    public let actionTitle: String
    /// "File “Cordless drill”…" / "Move “Cordless drill”…", or the unnamed forms.
    public let actionAccessibilityLabel: String
    /// `item-file` or `item-move`.
    public let actionIdentifier: String

    /// - Parameter name: the item's name; blank when it has none yet.
    public init(place: some PlaceLike, name: String) {
        isDropZone = PlaceRowText.isDropZone(place)
        // RN tests the raw name for truthiness here, not its trimmed form.
        let named = !name.isEmpty
        if isDropZone {
            actionTitle = L10n.Item.fileIt
            actionAccessibilityLabel = named ? L10n.Item.fileItA11y(name: name) : L10n.Item.fileItA11yUnnamed
            actionIdentifier = "item-file"
        } else {
            actionTitle = L10n.Item.move
            actionAccessibilityLabel = named ? L10n.Item.moveA11y(name: name) : L10n.Item.moveA11yUnnamed
            actionIdentifier = "item-move"
        }
    }
}
