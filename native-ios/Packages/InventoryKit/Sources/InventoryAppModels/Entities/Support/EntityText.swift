import Foundation
import InventoryCore

/// JavaScript string semantics the entity rules rely on, in one place.
///
/// The RN code compares strings with `===` (UTF-16 code units, no canonical equivalence:
/// `"Café"` precomposed and `"Cafe\u{301}"` differ) and tests them for truthiness (only `""`
/// is blank; `" "` is not). Swift's `==` compares canonically, so every comparison the RN rules
/// make with `===` goes through ``same(_:_:)``. Trimming is `jsTrimmed()` from InventoryCore.
enum EntityText {
    /// JS `a === b`: the same UTF-16 code units.
    static func same(_ a: String, _ b: String) -> Bool {
        a.utf16.elementsEqual(b.utf16)
    }

    /// JS `a === b` for optional strings (`null === null`).
    static func same(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): same(a, b)
        default: false
        }
    }

    /// JS `s.trim() !== ''` (and `Boolean(s.trim())`).
    static func hasText(_ s: String) -> Bool {
        !s.jsTrimmed().isEmpty
    }

    /// JS `a.trim() !== b.trim()`.
    static func trimmedDiffer(_ a: String, _ b: String) -> Bool {
        !same(a.jsTrimmed(), b.jsTrimmed())
    }

    /// JS `s.split(',')`: every piece, empty ones included, split on the code point U+002C
    /// (a comma followed by a combining mark is still a comma, as in JS).
    static func splitOnComma(_ s: String) -> [String] {
        s.unicodeScalars
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
    }

    /// JS `a.localeCompare(b, 'en', { sensitivity: 'base' })`: case and accents ignored.
    ///
    /// Foundation's locale-aware compare with case and diacritic folding is the base-strength
    /// collation the RN app gets from ICU (07 §2.5, 01 §8.3); the parity vectors in
    /// Fixtures/entities pin it against the real `localeCompare`.
    static func localeCompareBase(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive], locale: english)
    }

    private static let english = Locale(identifier: "en")
}

extension Array {
    /// A stable sort: equal elements keep their order, as JS `Array.prototype.sort` guarantees
    /// and Swift's `sorted(by:)` does not promise (07 Q12).
    func entityStableSorted(by order: (Element, Element) -> ComparisonResult) -> [Element] {
        enumerated()
            .sorted { lhs, rhs in
                switch order(lhs.element, rhs.element) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }
}
