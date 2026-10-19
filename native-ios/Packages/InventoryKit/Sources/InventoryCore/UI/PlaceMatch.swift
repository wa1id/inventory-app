// RN: src/ui/placeMatch.ts. Filtering the place picker by what was typed, with
// the same folding as Home search (`compactAlphanumeric`).

/// What a container option can be found by (RN `PlaceMatchFields`).
public protocol PlaceMatchFields {
    var name: String? { get }
    var shortCode: String { get }
    var spaceName: String { get }
    var visualType: ContainerVisualType { get }
}

/// A container as the place picker offers it, joined with its space (RN `PlaceOption`).
public struct PlaceOption: PlaceMatchFields, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String?
    public var shortCode: String
    public var visualType: ContainerVisualType
    public var spaceId: String
    public var spaceName: String
    /// `""` when the space is not known (yet).
    public var spaceColor: String
    /// `""` when the space is not known (yet).
    public var spaceIcon: String
    public var itemCount: Int

    public init(
        id: String,
        name: String?,
        shortCode: String,
        visualType: ContainerVisualType,
        spaceId: String,
        spaceName: String,
        spaceColor: String,
        spaceIcon: String,
        itemCount: Int
    ) {
        self.id = id
        self.name = name
        self.shortCode = shortCode
        self.visualType = visualType
        self.spaceId = spaceId
        self.spaceName = spaceName
        self.spaceColor = spaceColor
        self.spaceIcon = spaceIcon
        self.itemCount = itemCount
    }
}

/// The typed filter as compacted terms: split on JS whitespace, compact each, drop empty ones (RN `placeTerms`).
public func placeTerms(_ query: String) -> [String] {
    query.unicodeScalars
        .split(whereSeparator: \.isJSWhitespace)
        .map { compactAlphanumeric(String(String.UnicodeScalarView($0))) }
        .filter { !$0.isEmpty }
}

/// Whether an option matches every term (RN `matchesPlace`).
///
/// Each term is looked for in the compacted name, label code, space name and
/// type name run together, so `drw7k` finds `DRW-7K2M`. Matching is a
/// code-point substring test and is case-sensitive after folding, like JS
/// `includes` (a typed `™` folds to `TM` and does not match `tm`).
///
/// - Parameter typeName: the display name of a visual type (RN `strings.entities.typeNames[t]`),
///   or `nil` for a type without one; an unknown type adds nothing to the haystack.
public func matchesPlace(
    _ option: some PlaceMatchFields,
    terms: [String],
    typeName: (ContainerVisualType) -> String?
) -> Bool {
    if terms.isEmpty { return true }
    let haystack = Array(
        compactAlphanumeric(
            "\(option.name ?? "") \(option.shortCode) \(option.spaceName) \(typeName(option.visualType) ?? "")"
        ).unicodeScalars
    )
    return terms.allSatisfy { haystack.containsScalars(Array($0.unicodeScalars)) }
}

/// One container as the picker offers it; a space not (yet) known gives no colour or icon (RN `toPlaceOption`).
public func toPlaceOption(_ row: ContainerWithSpace, space: Space?) -> PlaceOption {
    PlaceOption(
        id: row.container.id,
        name: row.container.name,
        shortCode: row.container.shortCode,
        visualType: row.container.visualType,
        spaceId: row.container.spaceId,
        spaceName: row.spaceName,
        spaceColor: space?.color ?? "",
        spaceIcon: space?.icon ?? "",
        itemCount: row.itemCount
    )
}

/// Containers joined with their spaces, in container order (RN `joinPlaceOptions`).
public func joinPlaceOptions(_ rows: [ContainerWithSpace], spaces: [Space]) -> [PlaceOption] {
    var spaceById: [String: Space] = [:]
    for space in spaces {
        spaceById[space.id] = space  // like `new Map(entries)`: a later duplicate id wins
    }
    return rows.map { toPlaceOption($0, space: spaceById[$0.container.spaceId]) }
}

extension Array where Element == Unicode.Scalar {
    /// Code-point substring test, like JS `String.prototype.includes`.
    func containsScalars(_ needle: [Unicode.Scalar]) -> Bool {
        if needle.isEmpty { return true }
        guard needle.count <= count else { return false }
        for start in 0...(count - needle.count) where self[start] == needle[0] {
            if self[start..<(start + needle.count)].elementsEqual(needle) { return true }
        }
        return false
    }
}
