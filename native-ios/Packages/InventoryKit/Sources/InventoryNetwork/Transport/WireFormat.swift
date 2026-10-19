import Foundation

// Small JS-compatible helpers the clients use to build requests and read answers.
// Response bodies are parsed with InventoryCore's `JSONValue` (`JSON.parse` exactly,
// `typeof` checks, `String()` / `Number()` coercions).

extension Double {
    /// A finite JS number as `Int64`, rounded toward zero; nil when it does not fit.
    var truncatedInt64: Int64? {
        guard isFinite else { return nil }
        return Int64(exactly: rounded(.towardZero))
    }
}

/// JS `encodeURIComponent`: everything but `A-Z a-z 0-9 - _ . ! ~ * ' ( )` is
/// percent-encoded as UTF-8 with uppercase hex.
func encodeURIComponent(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: uriComponentAllowed) ?? value
}

private let uriComponentAllowed = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
)

/// `value.replace(/\/+$/, '')`.
func strippingTrailingSlashes(_ value: String) -> String {
    var scalars = value.unicodeScalars[...]
    while scalars.last == "/" { scalars = scalars.dropLast() }
    return String(scalars)
}

/// JSON the way `JSON.stringify` writes it: `/` is not escaped.
func wireJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return encoder
}
