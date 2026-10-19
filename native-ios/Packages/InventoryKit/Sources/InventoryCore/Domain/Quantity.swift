// RN: src/core/quantity.ts. A quantity is a whole number of things currently in
// a container. Zero is allowed (the item stays filed). Only the stepper and the
// saved-quantity writer clamp to 9999; typed values above it parse unclamped.

/// Lowest quantity (RN `MIN_QUANTITY`).
public let minQuantity = 0

/// Household-scale cap applied by the stepper (RN `MAX_QUANTITY`).
public let maxQuantity = 9999

/// `value` limited to `minQuantity...maxQuantity` (RN `clampQuantity`).
public func clampQuantity(_ value: Int) -> Int {
    min(max(value, minQuantity), maxQuantity)
}

/// RN `clampQuantity` for a JS number: anything that is not a whole number (fractions, NaN, ±∞) gives 0.
public func clampQuantity(_ value: Double) -> Int {
    guard value.isFinite, value.rounded(.towardZero) == value else { return minQuantity }
    if value < Double(minQuantity) { return minQuantity }
    if value > Double(maxQuantity) { return maxQuantity }
    return Int(value)
}

/// `current + delta`, clamped (RN `stepQuantity`).
public func stepQuantity(_ current: Int, _ delta: Int) -> Int {
    let (sum, overflow) = current.addingReportingOverflow(delta)
    if overflow { return delta < 0 ? minQuantity : maxQuantity }
    return clampQuantity(sum)
}

/// What the user typed into the quantity field, or `nil` (RN `parseQuantityInput`).
///
/// Trims with JS rules, then follows JS `Number()`: `"1.0"`, `"1e2"`, `"0x1F"`,
/// `"+5"` and `"5."` parse; empty, fractional, negative and non-ASCII-digit input
/// does not. Values above 9999 come back unclamped. Unlike JS, a value outside
/// `Int` (beyond 2^63) gives `nil` instead of an imprecise float.
public func parseQuantityInput(_ raw: String) -> Int? {
    let trimmed = raw.jsTrimmed()
    if trimmed.isEmpty { return nil }
    guard let value = jsNumber(trimmed), value.isFinite, value.rounded(.towardZero) == value,
          !(value < Double(minQuantity))
    else { return nil }
    return Int(exactly: value)
}

/// JS `Number(string)` (ECMA-262 StringToNumber) for an already trimmed string; `nil` stands for NaN.
///
/// Public so the network clients coerce server values (`Number(body.updatedAt)`) with the same grammar.
public func jsNumber(_ text: String) -> Double? {
    let scalars = Array(text.unicodeScalars)
    if scalars.isEmpty { return 0 }
    guard scalars.allSatisfy(\.isASCII) else { return nil }
    let chars = scalars.map { Character($0) }

    // NonDecimalIntegerLiteral: 0x / 0o / 0b, no sign, at least one digit.
    if chars.count > 2, chars[0] == "0" {
        let radix: Int? = switch chars[1] {
        case "x", "X": 16
        case "o", "O": 8
        case "b", "B": 2
        default: nil
        }
        if let radix { return integerValue(chars.dropFirst(2), radix: radix) }
    }

    var index = 0
    var sign = ""
    if chars[index] == "+" || chars[index] == "-" {
        sign = chars[index] == "-" ? "-" : ""
        index += 1
    }
    let rest = String(chars[index...])
    if rest == "Infinity" { return sign == "-" ? -.infinity : .infinity }

    func digits() -> String {
        var out = ""
        while index < chars.count, chars[index].isASCII, chars[index].isNumber {
            out.append(chars[index])
            index += 1
        }
        return out
    }

    let whole = digits()
    var fraction = ""
    if index < chars.count, chars[index] == "." {
        index += 1
        fraction = digits()
    }
    guard !whole.isEmpty || !fraction.isEmpty else { return nil }

    var exponent = ""
    if index < chars.count, chars[index] == "e" || chars[index] == "E" {
        index += 1
        var exponentSign = ""
        if index < chars.count, chars[index] == "+" || chars[index] == "-" {
            exponentSign = chars[index] == "-" ? "-" : ""
            index += 1
        }
        let exponentDigits = digits()
        guard !exponentDigits.isEmpty else { return nil }
        exponent = "e" + exponentSign + exponentDigits
    }
    guard index == chars.count else { return nil }

    let literal = sign + (whole.isEmpty ? "0" : whole) + (fraction.isEmpty ? "" : "." + fraction) + exponent
    return Double(literal)
}

/// The value of an unsigned digit string in `radix`, rounded to a Double like JS; `nil` if a digit is invalid.
private func integerValue(_ digits: ArraySlice<Character>, radix: Int) -> Double? {
    var exact: UInt64? = 0
    var approximate = 0.0
    for character in digits {
        guard let digit = character.hexDigitValue, digit < radix else { return nil }
        approximate = approximate * Double(radix) + Double(digit)
        if let value = exact {
            let (shifted, overflowA) = value.multipliedReportingOverflow(by: UInt64(radix))
            let (sum, overflowB) = shifted.addingReportingOverflow(UInt64(digit))
            exact = overflowA || overflowB ? nil : sum
        }
    }
    // Beyond 64 bits the exact value is outside `Int` anyway; the approximation only has to stay huge.
    return exact.map { Double($0) } ?? approximate
}
