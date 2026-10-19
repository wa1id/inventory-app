import Foundation

// Small ports of the JavaScript built-ins the RN preference and session readers lean on, so the
// Swift readers accept and reject exactly what Hermes did. Internal to this module.

/// A parsed JSON value with JavaScript's types: one number type, booleans distinct from numbers.
enum JSONValue: Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    /// `JSON.parse(text)`, or nil where JS would throw a SyntaxError.
    ///
    /// A strict ECMA-404 parser written against the JS rules rather than `JSONSerialization`:
    /// whitespace is only tab, LF, CR and space (a BOM is an error), any value may be top level,
    /// duplicate object keys keep the last value, and numbers past the Double range become
    /// infinities instead of failing. Escaped lone surrogates become U+FFFD (a Swift String
    /// cannot hold them).
    static func parse(_ text: String) -> JSONValue? {
        var parser = JSONTextParser(units: Array(text.utf16))
        guard let value = parser.parseValue() else { return nil }
        parser.skipWhitespace()
        return parser.isAtEnd ? value : nil
    }
}

private struct JSONTextParser {
    let units: [UInt16]
    var index = 0

    var isAtEnd: Bool { index == units.count }

    private func peek() -> UInt16? { index < units.count ? units[index] : nil }

    mutating func skipWhitespace() {
        while let unit = peek(), unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D {
            index += 1
        }
    }

    private mutating func consume(_ literal: String) -> Bool {
        let expected = Array(literal.utf16)
        guard index + expected.count <= units.count,
              Array(units[index..<index + expected.count]) == expected else { return false }
        index += expected.count
        return true
    }

    mutating func parseValue() -> JSONValue? {
        skipWhitespace()
        guard let unit = peek() else { return nil }
        switch unit {
        case 0x7B: return parseObject()
        case 0x5B: return parseArray()
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
        return JSNumber.decimal(literal).map(JSONValue.number)
    }

    private static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }
}

/// JSON text the way `JSON.stringify` writes it.
enum JSONText {
    /// `JSON.stringify(string)`: quotes, backslash and the C0 controls escaped (short forms for
    /// \b \f \n \r \t, otherwise `\u00xx` in lowercase hex); everything else, including `/`,
    /// U+007F and U+2028/U+2029, stays literal.
    static func quote(_ string: String) -> String {
        var out = "\""
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
        return out + "\""
    }

    /// `JSON.stringify(strings)` for an array of strings: compact, no spaces.
    static func array(_ strings: [String]) -> String {
        "[" + strings.map(quote).joined(separator: ",") + "]"
    }
}

/// JavaScript string helpers.
enum JS {
    /// `String.prototype.trim()`: strips ECMAScript WhiteSpace and LineTerminator code points
    /// (which include U+FEFF but not U+0085), unlike `.whitespacesAndNewlines`.
    static func trim(_ string: String) -> String {
        let scalars = string.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isWhitespace($0) }),
              let last = scalars.lastIndex(where: { !isWhitespace($0) }) else { return "" }
        return String(scalars[first...last])
    }

    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            true
        default:
            false
        }
    }

    /// `String.prototype.toLowerCase()` as Hermes runs it on iOS: CoreFoundation's
    /// non-localized lowercase mapping (`CFStringLowercase` with no locale), which also applies
    /// the Greek final-sigma rule (01 Q10).
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

/// JavaScript's `Number(string)` (ECMAScript StringToNumber).
enum JSNumber {
    /// The value `Number(text)` produces, or nil where it produces NaN.
    static func parse(_ text: String) -> Double? {
        let trimmed = JS.trim(text)
        if trimmed.isEmpty { return 0 }
        let lower = trimmed.lowercased()
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where lower.hasPrefix(prefix) {
            return integer(String(trimmed.dropFirst(2)), radix: radix)
        }
        var body = Substring(trimmed)
        var sign = 1.0
        if let first = body.first, first == "+" || first == "-" {
            sign = first == "-" ? -1 : 1
            body = body.dropFirst()
        }
        if body == "Infinity" { return sign * .infinity }
        guard let magnitude = strDecimal(String(body)) else { return nil }
        return sign * magnitude
    }

    /// `DecimalDigits[.DecimalDigits][ExponentPart]` or `.DecimalDigits[ExponentPart]`, unsigned.
    private static func strDecimal(_ text: String) -> Double? {
        let units = Array(text.utf8)
        var index = 0
        func digits() -> String {
            let start = index
            while index < units.count, units[index] >= 0x30, units[index] <= 0x39 { index += 1 }
            return String(decoding: units[start..<index], as: UTF8.self)
        }
        let whole = digits()
        var fraction = ""
        if index < units.count, units[index] == 0x2E {
            index += 1
            fraction = digits()
        }
        guard !(whole.isEmpty && fraction.isEmpty) else { return nil }
        var exponent = ""
        if index < units.count, units[index] == 0x65 || units[index] == 0x45 {
            index += 1
            var sign = ""
            if index < units.count, units[index] == 0x2B || units[index] == 0x2D {
                sign = units[index] == 0x2D ? "-" : ""
                index += 1
            }
            let exponentDigits = digits()
            guard !exponentDigits.isEmpty else { return nil }
            exponent = "e" + sign + exponentDigits
        }
        guard index == units.count else { return nil }
        // Rebuilt in a form Swift's parser always takes ("5." and ".5" padded with zeros).
        return decimal((whole.isEmpty ? "0" : whole) + "." + (fraction.isEmpty ? "0" : fraction) + exponent)
    }

    /// A validated decimal literal as a Double; magnitudes past the range become infinities.
    static func decimal(_ literal: String) -> Double? {
        if let value = Double(literal) { return value }
        // Out-of-range exponents, should the parser refuse them: JS rounds to ±Infinity or ±0.
        guard let e = literal.firstIndex(where: { $0 == "e" || $0 == "E" }) else { return nil }
        let mantissa = literal[..<e]
        let negative = mantissa.hasPrefix("-")
        let isZero = mantissa.allSatisfy { $0 == "-" || $0 == "0" || $0 == "." }
        let magnitude: Double = isZero || literal[literal.index(after: e)...].hasPrefix("-") ? 0 : .infinity
        return negative ? -magnitude : magnitude
    }

    private static func integer(_ digits: String, radix: Int) -> Double? {
        guard !digits.isEmpty else { return nil }
        var value = 0.0
        for unit in digits.utf8 {
            let digit: Int
            switch unit {
            case 0x30...0x39: digit = Int(unit) - 0x30
            case 0x41...0x46: digit = Int(unit) - 0x41 + 10
            case 0x61...0x66: digit = Int(unit) - 0x61 + 10
            default: return nil
            }
            guard digit < radix else { return nil }
            value = value * Double(radix) + Double(digit)
        }
        return value
    }
}
