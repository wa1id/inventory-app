// Stored strings with a known vocabulary. They are structs, not enums, because
// the database and the household JSON may hold values this build does not know
// (an import, the desk, an older or newer app), and those must round-trip
// unchanged. Code that switches on them needs a `default` branch.

/// `containers.visual_type`: what a container looks like (RN `ContainerVisualType`).
///
/// Matching is exact and case-sensitive: a stored `Box` is unknown.
public struct ContainerVisualType: RawRepresentable, Hashable, Sendable, Codable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public static let box: Self = "box"
    public static let drawer: Self = "drawer"
    public static let shelf: Self = "shelf"
    public static let cabinet: Self = "cabinet"
    public static let bin: Self = "bin"
    public static let bag: Self = "bag"
    public static let crate: Self = "crate"
    public static let other: Self = "other"

    /// The known types in picker order (RN `CONTAINER_VISUAL_TYPES`).
    public static let allKnown: [Self] = [.box, .drawer, .shelf, .cabinet, .bin, .bag, .crate, .other]

    /// Whether this build knows the type; unknown types draw and read as `other`.
    public var isKnown: Bool { Self.allKnown.contains(self) }

    public var description: String { rawValue }
}

/// `spaces.kind` / `containers.kind`: `normal` rows are the user's, `system` rows are the drop zone.
///
/// Not part of the TS domain types; repositories filter list queries on it.
public struct RecordKind: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    /// A row the user made (the column default).
    public static let normal: Self = "normal"
    /// A seeded row the repositories refuse to modify (the drop zone).
    public static let system: Self = "system"

    public var description: String { rawValue }
}
