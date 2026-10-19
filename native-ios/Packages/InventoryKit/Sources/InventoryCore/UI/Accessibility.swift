import InventoryStrings

// RN: src/ui/a11y.ts. Spoken forms for VoiceOver labels. The copy defaults to the
// String Catalog (`SpokenCopy.standard`); tests can pass their own.

/// Where something is, in the shape every location renderer needs (RN `PlaceLike`).
public protocol PlaceLike {
    var containerId: String { get }
    var containerName: String? { get }
    var containerShortCode: String { get }
    var spaceId: String { get }
    var spaceName: String { get }
    var spaceColor: String { get }
}

/// The copy the spoken helpers compose (RN `strings.a11y.*` and `strings.rows.*`).
public struct SpokenCopy: Sendable {
    /// `strings.a11y.inDropZone`: "In the drop zone, not filed yet".
    public var inDropZone: String
    /// `strings.a11y.inPlace(space, container, spelled)`: "In Garage, Tool chest, label C A B, J 9 2 R".
    public var inPlace: @Sendable (_ space: String, _ container: String, _ spelled: String) -> String
    /// `strings.a11y.inSpace(space, spelled)`: "In Garage, label C A B, J 9 2 R".
    public var inSpace: @Sendable (_ space: String, _ spelled: String) -> String
    /// `strings.rows.noneLeft`: "None left".
    public var noneLeft: String
    /// `strings.rows.quantity(count)`: "Quantity 12".
    public var quantity: @Sendable (_ count: Int) -> String

    public init(
        inDropZone: String,
        inPlace: @escaping @Sendable (_ space: String, _ container: String, _ spelled: String) -> String,
        inSpace: @escaping @Sendable (_ space: String, _ spelled: String) -> String,
        noneLeft: String,
        quantity: @escaping @Sendable (_ count: Int) -> String
    ) {
        self.inDropZone = inDropZone
        self.inPlace = inPlace
        self.inSpace = inSpace
        self.noneLeft = noneLeft
        self.quantity = quantity
    }

    /// The app's copy: `strings.a11y.inDropZone`, `.inPlace`, `.inSpace`, `strings.rows.noneLeft`, `.quantity`.
    public static var standard: SpokenCopy {
        SpokenCopy(
            inDropZone: L10n.A11y.inDropZone,
            inPlace: { L10n.A11y.inPlace(space: $0, container: $1, spelled: $2) },
            inSpace: { L10n.A11y.inSpace(space: $0, spelled: $1) },
            noneLeft: L10n.Rows.noneLeft,
            quantity: { L10n.Rows.quantity(count: $0) }
        )
    }
}

/// A code spelled out for screen readers: `DRW-7K2M` → `D R W, 7 K 2 M` (RN `spellCode`).
///
/// Split on `-`, trim each group (JS rules), space its characters, drop empty
/// groups, join with `", "`. Read as written, "DRW" comes out as "drew".
public func spellCode(_ code: String) -> String {
    code.unicodeScalars
        .split(separator: "-", omittingEmptySubsequences: false)
        .map { group -> String in
            let trimmed = String(String.UnicodeScalarView(group)).jsTrimmed()
            return trimmed.unicodeScalars.map { String($0) }.joined(separator: " ")
        }
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
}

/// The spoken form of a location (RN `whereSpoken`).
///
/// The drop zone is never read by its internal code. A container name counts
/// only when non-empty (JS truthiness): `""` reads as unnamed, `" "` as named.
public func whereSpoken(_ place: some PlaceLike, copy: SpokenCopy = .standard) -> String {
    if place.containerId == DropZone.containerId { return copy.inDropZone }
    let spelled = spellCode(place.containerShortCode)
    if let name = place.containerName, !name.isEmpty {
        return copy.inPlace(place.spaceName, name, spelled)
    }
    return copy.inSpace(place.spaceName, spelled)
}

/// "Quantity 12", or "None left" at zero (RN `quantitySpoken`).
public func quantitySpoken(_ quantity: Int, copy: SpokenCopy = .standard) -> String {
    quantity == 0 ? copy.noneLeft : copy.quantity(quantity)
}
