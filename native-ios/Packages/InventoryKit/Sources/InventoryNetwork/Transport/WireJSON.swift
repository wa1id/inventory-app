import Foundation
import InventoryCore

/// A server response body parsed with JavaScript's types: one number type, and
/// booleans kept apart from numbers.
///
/// The RN clients never validate shapes with a schema; they test `typeof` and
/// coerce with `String()` / `Number()`. This value lets the Swift clients make the
/// same checks, where a strict `Codable` would turn `category: 42` into a failure
/// instead of nil. Parsing goes through `JSONSerialization`; JSON from these
/// servers is always `JSON.stringify` output, so the JS-exact text parser the
/// storage layer needs for on-device values is not required here, with one
/// exception handled below: lone surrogate escapes.
enum WireJSON: Sendable, Equatable {
    case object([String: WireJSON])
    case array([WireJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    /// `JSON.parse` over the body, or nil where it would throw. Any value may be top level.
    static func parse(_ data: Data) -> WireJSON? {
        parseText(data)?.value
    }

    /// ``parse(_:)``, plus the JSON text it finally parsed, for a `Decodable` pass over the same body.
    ///
    /// `JSON.stringify` writes a lone surrogate as a `\udXXX` escape, and the servers
    /// do produce them: the recognition server cuts names with `slice(0, 80)`
    /// (server/src/prompt.ts:83-85), which can split an emoji. `JSON.parse` accepts
    /// the escape; `JSONSerialization` and `JSONDecoder` refuse the whole body, which
    /// would turn a usable suggestion into `malformed_response`. So a body that fails
    /// is retried with those escapes read as U+FFFD, the rule InventoryStorage's
    /// JS-exact parser uses (a Swift String cannot hold a lone surrogate).
    static func parseText(_ data: Data) -> (value: WireJSON, text: Data)? {
        if let value = bridged(data) { return (value, data) }
        guard let repaired = replacingLoneSurrogateEscapes(in: data), let value = bridged(repaired) else {
            return nil
        }
        return (value, repaired)
    }

    private static func bridged(_ data: Data) -> WireJSON? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return WireJSON(bridging: any)
    }

    /// The JSON text with every `\uXXXX` escape of an unpaired surrogate replaced by
    /// U+FFFD, or nil when there is none. Only escapes inside strings are touched,
    /// and every other escape is copied whole, so `\\ud800` (a backslash, then text)
    /// stays as it is.
    static func replacingLoneSurrogateEscapes(in data: Data) -> Data? {
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        var inString = false
        var changed = false

        /// The code unit of a `\uXXXX` escape starting at `start`.
        func escapedUnit(at start: Int) -> UInt16? {
            guard start + 5 < bytes.count, bytes[start] == UInt8(ascii: "\\"), bytes[start + 1] == UInt8(ascii: "u") else {
                return nil
            }
            var unit: UInt16 = 0
            for byte in bytes[(start + 2)...(start + 5)] {
                guard let digit = hexDigitValue(byte) else { return nil }
                unit = unit << 4 | UInt16(digit)
            }
            return unit
        }

        while index < bytes.count {
            let byte = bytes[index]
            guard inString else {
                if byte == UInt8(ascii: "\"") { inString = true }
                output.append(byte)
                index += 1
                continue
            }
            if byte == UInt8(ascii: "\"") {
                inString = false
                output.append(byte)
                index += 1
            } else if byte == UInt8(ascii: "\\") {
                if let unit = escapedUnit(at: index) {
                    if UTF16.isLeadSurrogate(unit), let next = escapedUnit(at: index + 6), UTF16.isTrailSurrogate(next) {
                        output.append(contentsOf: bytes[index..<(index + 12)])
                        index += 12
                    } else if UTF16.isLeadSurrogate(unit) || UTF16.isTrailSurrogate(unit) {
                        output.append(contentsOf: Array("\u{FFFD}".utf8))
                        index += 6
                        changed = true
                    } else {
                        output.append(contentsOf: bytes[index..<(index + 6)])
                        index += 6
                    }
                } else {
                    // Any other escape, copied whole so an escaped quote or backslash is not misread.
                    output.append(contentsOf: bytes[index..<min(index + 2, bytes.count)])
                    index += 2
                }
            } else {
                output.append(byte)
                index += 1
            }
        }
        return changed ? Data(output) : nil
    }

    private static func hexDigitValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    private init?(bridging any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            // JSONSerialization bridges true/false to NSNumber; JS keeps them booleans.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if number is NSDecimalNumber {
                // Integers past Int64 arrive as NSDecimalNumber, whose doubleValue is not
                // correctly rounded; JSON.parse rounds the decimal text to the nearest double.
                self = .number(Double(number.stringValue) ?? number.doubleValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            var values: [WireJSON] = []
            values.reserveCapacity(array.count)
            for element in array {
                guard let value = WireJSON(bridging: element) else { return nil }
                values.append(value)
            }
            self = .array(values)
        case let dictionary as [String: Any]:
            var object: [String: WireJSON] = [:]
            for (key, element) in dictionary {
                guard let value = WireJSON(bridging: element) else { return nil }
                object[key] = value
            }
            self = .object(object)
        default:
            return nil
        }
    }

    /// The members when this is an object (`typeof v === 'object' && v !== null && !Array.isArray(v)`).
    var objectValue: [String: WireJSON]? {
        if case .object(let members) = self { return members }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// `typeof v === 'number'`.
    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// JS `String(value)`.
    var jsString: String {
        switch self {
        case .string(let value): value
        case .number(let value): Self.jsNumberString(value)
        case .bool(let value): value ? "true" : "false"
        case .null: "null"
        // Array.prototype.toString: elements joined by ",", null and undefined as "".
        case .array(let values): values.map { $0 == .null ? "" : $0.jsString }.joined(separator: ",")
        case .object: "[object Object]"
        }
    }

    /// JS `Number(value)`; nil stands for NaN.
    var jsNumber: Double? {
        switch self {
        case .number(let value): value
        case .bool(let value): value ? 1 : 0
        case .null: 0
        case .string(let value): stringToNumber(value)
        // ToPrimitive on an array is its toString, then StringToNumber.
        case .array: stringToNumber(jsString)
        case .object: nil
        }
    }

    /// JS `Number::toString(10)` for a double: integers in plain digits below 1e21,
    /// otherwise the shortest round-trip digits placed by the ECMA-262 rules.
    static func jsNumberString(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == 0 { return "0" }
        if value < 0 { return "-" + jsNumberString(-value) }

        // Swift's description also prints the shortest round-trip digits; take
        // them apart into digits `s` and exponent `n` so that value = 0.s × 10^n.
        let text = "\(value)"
        let parts = text.split(separator: "e", maxSplits: 1)
        let mantissa = String(parts[0])
        let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let pointIndex = mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) }
            ?? mantissa.count
        var digits = Array(mantissa.filter { $0 != "." })
        var point = pointIndex + exponent
        while digits.first == "0" {
            digits.removeFirst()
            point -= 1
        }
        while digits.last == "0" { digits.removeLast() }
        let k = digits.count
        let n = point
        let s = String(digits)

        if k <= n && n <= 21 {
            return s + String(repeating: "0", count: n - k)
        }
        if 0 < n && n <= 21 {
            return String(digits[0..<n]) + "." + String(digits[n...])
        }
        if -6 < n && n <= 0 {
            return "0." + String(repeating: "0", count: -n) + s
        }
        let e = n - 1
        let sign = e < 0 ? "-" : "+"
        let head = k == 1 ? s : String(digits[0]) + "." + String(digits[1...])
        return head + "e" + sign + String(abs(e))
    }
}

/// JS StringToNumber after a JS trim (InventoryCore's `jsNumber`), named apart from `WireJSON.jsNumber`.
private func stringToNumber(_ text: String) -> Double? {
    jsNumber(text.jsTrimmed())
}

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
