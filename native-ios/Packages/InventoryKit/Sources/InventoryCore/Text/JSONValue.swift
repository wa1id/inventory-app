import Foundation

/// A JSON value with JavaScript's types: one number type, and booleans kept apart from numbers.
///
/// RN code never validated JSON with a schema. It parsed with `JSON.parse` (stored preferences,
/// the keychain session) or `response.json()` (server answers), tested `typeof`, and coerced
/// with `String()` / `Number()`. This value lets Swift make exactly those checks, where a
/// strict `Codable` would turn `category: 42` into a failure instead of nil, and
/// its `parse` accepts and rejects exactly what `JSON.parse` does.
public enum JSONValue: Sendable, Hashable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    // MARK: - JSON.parse

    /// `JSON.parse(text)`, or nil where JS would throw a SyntaxError.
    ///
    /// A strict ECMA-404 parser written against the JS rules rather than `JSONSerialization`:
    /// whitespace is only tab, LF, CR and space (a BOM is an error), any value may be top level,
    /// duplicate object keys keep the last value, and numbers are rounded to the nearest Double
    /// however many digits they have (past the range they become ±Infinity or ±0 instead of
    /// failing). Escaped lone surrogates (`"\ud83d"`, which `JSON.stringify` writes for a cut
    /// emoji) become U+FFFD, because a Swift String cannot hold them. Nesting deeper than 256
    /// levels fails, as Hermes' JSON.parse throws a RangeError on deep nesting, rather than
    /// overflowing the stack.
    public static func parse(_ text: String) -> JSONValue? {
        var parser = JSONTextParser(units: Array(text.utf16))
        guard let value = parser.parseValue() else { return nil }
        parser.skipWhitespace()
        return parser.isAtEnd ? value : nil
    }

    /// `await response.json()` over a response body: the bytes decoded as UTF-8 with a leading
    /// byte order mark dropped (the Fetch standard's "UTF-8 decode"), then `JSON.parse`.
    ///
    /// Bytes that are not valid UTF-8 are refused (nil) rather than repaired, as the native
    /// clients always did; the servers only ever send `JSON.stringify` output.
    public static func parse(_ data: Data) -> JSONValue? {
        var bytes = data[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard let text = String(validating: bytes, as: UTF8.self) else { return nil }
        return parse(text)
    }

    // MARK: - JSON.stringify

    /// `JSON.stringify(value)`: compact, `/` and non-ASCII left as they are.
    ///
    /// Numbers are written as JS writes them (``jsNumberString(_:)``; a non-finite one as
    /// `null`). JS writes an object's keys in insertion order, which a Swift dictionary does
    /// not keep, so they come out sorted by UTF-16 code units: deterministic, and the same set
    /// of members. Where the order of keys matters, build the text field by field with
    /// ``quote(_:)``.
    public var jsonText: String {
        var out = ""
        write(to: &out)
        return out
    }

    /// `JSON.stringify(string)`: quotes, backslash and the C0 controls escaped (short forms for
    /// \b \f \n \r \t, otherwise `\u00xx` in lowercase hex); everything else, including `/`,
    /// U+007F and U+2028/U+2029, stays literal.
    public static func quote(_ string: String) -> String {
        var out = ""
        appendQuoted(string, to: &out)
        return out
    }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .number(let value): out += value.isFinite ? jsNumberString(value) : "null"
        case .string(let value): Self.appendQuoted(value, to: &out)
        case .array(let values):
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += "," }
                value.write(to: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            let keys = members.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            for (index, key) in keys.enumerated() {
                if index > 0 { out += "," }
                Self.appendQuoted(key, to: &out)
                out += ":"
                members[key]?.write(to: &out)
            }
            out += "}"
        }
    }

    private static func appendQuoted(_ string: String, to out: inout String) {
        out += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{00}"..."\u{1F}":
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }

    // MARK: - typeof checks

    /// The members when this is an object (`typeof v === 'object' && v !== null && !Array.isArray(v)`).
    public var objectValue: [String: JSONValue]? {
        if case .object(let members) = self { return members }
        return nil
    }

    /// The elements when this is an array (`Array.isArray(v)`).
    public var arrayValue: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    /// `typeof v === 'string'`.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// `typeof v === 'number'`.
    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// `typeof v === 'boolean'`.
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    // MARK: - Coercions

    /// JS `String(value)`.
    public var jsString: String {
        switch self {
        case .string(let value): value
        case .number(let value): jsNumberString(value)
        case .bool(let value): value ? "true" : "false"
        case .null: "null"
        // Array.prototype.toString: elements joined by ",", null and undefined as "".
        case .array(let values): values.map { $0 == .null ? "" : $0.jsString }.joined(separator: ",")
        case .object: "[object Object]"
        }
    }

    /// JS `Number(value)`; nil stands for NaN.
    public var jsNumber: Double? {
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
}

/// `Number(text)`: a JS trim, then StringToNumber. Named apart from `JSONValue.jsNumber`,
/// which would shadow the module's `jsNumber(_:)` inside the type.
private func stringToNumber(_ text: String) -> Double? {
    jsNumber(text.jsTrimmed())
}

private struct JSONTextParser {
    /// Far beyond anything the app stores or the servers send, well within the stack.
    static let maxDepth = 256

    let units: [UInt16]
    var index = 0
    var depth = 0

    var isAtEnd: Bool { index == units.count }

    private func peek() -> UInt16? { index < units.count ? units[index] : nil }

    mutating func skipWhitespace() {
        while let unit = peek(), unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D {
            index += 1
        }
    }

    private mutating func consume(_ literal: StaticString) -> Bool {
        let expected = literal.withUTF8Buffer { Array($0) }
        guard index + expected.count <= units.count else { return false }
        for (offset, byte) in expected.enumerated() where units[index + offset] != UInt16(byte) {
            return false
        }
        index += expected.count
        return true
    }

    mutating func parseValue() -> JSONValue? {
        skipWhitespace()
        guard let unit = peek() else { return nil }
        switch unit {
        case 0x7B, 0x5B:
            guard depth < Self.maxDepth else { return nil }
            depth += 1
            defer { depth -= 1 }
            return unit == 0x7B ? parseObject() : parseArray()
        case 0x22: return parseString().map(JSONValue.string)
        case 0x74: return consume("true") ? .bool(true) : nil
        case 0x66: return consume("false") ? .bool(false) : nil
        case 0x6E: return consume("null") ? .null : nil
        default: return parseNumber()
        }
    }

    private mutating func parseObject() -> JSONValue? {
        index += 1  // {
        var object: [String: JSONValue] = [:]
        skipWhitespace()
        if peek() == 0x7D {
            index += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard peek() == 0x22, let key = parseString() else { return nil }
            skipWhitespace()
            guard peek() == 0x3A else { return nil }
            index += 1
            guard let value = parseValue() else { return nil }
            object[key] = value
            skipWhitespace()
            switch peek() {
            case 0x2C: index += 1
            case 0x7D:
                index += 1
                return .object(object)
            default: return nil
            }
        }
    }

    private mutating func parseArray() -> JSONValue? {
        index += 1  // [
        var array: [JSONValue] = []
        skipWhitespace()
        if peek() == 0x5D {
            index += 1
            return .array(array)
        }
        while true {
            guard let value = parseValue() else { return nil }
            array.append(value)
            skipWhitespace()
            switch peek() {
            case 0x2C: index += 1
            case 0x5D:
                index += 1
                return .array(array)
            default: return nil
            }
        }
    }

    private mutating func parseString() -> String? {
        index += 1  // opening quote
        var out: [UInt16] = []
        while let unit = peek() {
            index += 1
            switch unit {
            case 0x22:
                // Decoding UTF-16 turns an unpaired surrogate into U+FFFD.
                return String(decoding: out, as: UTF16.self)
            case 0x5C:
                guard let escape = peek() else { return nil }
                index += 1
                switch escape {
                case 0x22, 0x5C, 0x2F: out.append(escape)
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0C)
                case 0x6E: out.append(0x0A)
                case 0x72: out.append(0x0D)
                case 0x74: out.append(0x09)
                case 0x75:
                    guard index + 4 <= units.count else { return nil }
                    var value: UInt16 = 0
                    for digit in units[index..<index + 4] {
                        guard let nibble = Self.hexValue(digit) else { return nil }
                        value = value << 4 | nibble
                    }
                    index += 4
                    out.append(value)
                default: return nil
                }
            case 0x00...0x1F:
                return nil  // unescaped control characters are a SyntaxError
            default:
                out.append(unit)
            }
        }
        return nil
    }

    private static func hexValue(_ unit: UInt16) -> UInt16? {
        switch unit {
        case 0x30...0x39: unit - 0x30
        case 0x41...0x46: unit - 0x41 + 10
        case 0x61...0x66: unit - 0x61 + 10
        default: nil
        }
    }

    private mutating func parseNumber() -> JSONValue? {
        let start = index
        if peek() == 0x2D { index += 1 }
        guard let first = peek(), Self.isDigit(first) else { return nil }
        index += 1
        if first != 0x30 {
            while let unit = peek(), Self.isDigit(unit) { index += 1 }
        }
        if peek() == 0x2E {
            index += 1
            guard let unit = peek(), Self.isDigit(unit) else { return nil }
            while let unit = peek(), Self.isDigit(unit) { index += 1 }
        }
        if peek() == 0x65 || peek() == 0x45 {
            index += 1
            if peek() == 0x2B || peek() == 0x2D { index += 1 }
            guard let unit = peek(), Self.isDigit(unit) else { return nil }
            while let unit = peek(), Self.isDigit(unit) { index += 1 }
        }
        let literal = String(decoding: units[start..<index], as: UTF16.self)
        return jsDecimalValue(literal).map(JSONValue.number)
    }

    private static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }
}
