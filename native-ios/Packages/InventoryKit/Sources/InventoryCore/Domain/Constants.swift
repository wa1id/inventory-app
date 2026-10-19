import Foundation

// RN: src/db/constants.ts.

/// The holding area for things photographed before they have a home (RN `DROP_ZONE_*`).
///
/// Real rows flagged `kind = 'system'`, seeded by migration 3, so joins and
/// counts keep working; list queries filter them out by kind.
public enum DropZone {
    /// RN `DROP_ZONE_CONTAINER_ID`.
    public static let containerId = "drop-zone"
    /// RN `DROP_ZONE_SPACE_ID`.
    public static let spaceId = "drop-zone-space"
}

/// U+001F, the `GROUP_CONCAT(t.name, char(31))` separator for tag names (RN `TAG_DELIMITER`).
public let tagDelimiter: Unicode.Scalar = "\u{1F}"

/// Splits a `GROUP_CONCAT` tag column: `nil` or `''` → `[]`, empty pieces dropped (RN `splitTagNames`).
public func splitTagNames(_ value: String?) -> [String] {
    guard let value, !value.isEmpty else { return [] }
    return value.unicodeScalars
        .split(separator: tagDelimiter, omittingEmptySubsequences: true)
        .map { String(String.UnicodeScalarView($0)) }
}

/// Integer epoch milliseconds, floored, like JS `Date.now()`.
public func epochMillis(_ date: Date = Date()) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
}
