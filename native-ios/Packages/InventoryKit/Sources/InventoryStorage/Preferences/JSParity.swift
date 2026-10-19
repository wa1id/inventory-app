import Foundation

// The JavaScript built-ins the RN preference readers lean on that InventoryCore does not
// already provide (its `JSONValue`, `jsTrimmed()` and `jsNumber(_:)` cover `JSON.parse`,
// `JSON.stringify`, `trim()` and `Number()`). Internal to this module.

/// JavaScript string helpers with Hermes' semantics on iOS.
enum JS {
    /// `String.prototype.toLowerCase()` as Hermes runs it on iOS: CoreFoundation's
    /// non-localized lowercase mapping (`CFStringLowercase` with no locale), which also applies
    /// the Greek final-sigma rule (01 Q10).
    ///
    /// Deliberately not InventoryCore's `jsLowercased()`, which follows V8/ICU (the home
    /// server): category memory was written on the phone, by Hermes.
    static func lowercase(_ string: String) -> String {
        let mutable = NSMutableString(string: string)
        CFStringLowercase(mutable, nil)
        return mutable as String
    }

    /// A string as JavaScript compares it: by UTF-16 code units, with no canonical equivalence.
    struct Key: Hashable, Sendable {
        let units: [UInt16]
        init(_ string: String) { units = Array(string.utf16) }

        func hasPrefix(_ other: Key) -> Bool { units.starts(with: other.units) }
        var isEmpty: Bool { units.isEmpty }
    }
}
