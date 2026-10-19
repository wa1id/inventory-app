// JavaScript's string ↔ number conversions, the two directions RN code leans on:
// `Number(string)` (quantities, config timeouts, server values, stored preferences)
// and `Number#toString()` (`String(value)`, `JSON.stringify`).

/// JS `Number(string)` (ECMA-262 StringToNumber) for an already trimmed string; `nil` stands for NaN.
///
/// Trim first with ``Swift/String/jsTrimmed()``, as StringToNumber does: `Number(" 12 ")` is
/// `jsNumber(" 12 ".jsTrimmed())`. The empty string is 0. Accepts `Infinity` with an
/// optional sign, unsigned `0x` / `0o` / `0b` integers (rounded to the nearest Double, ties
/// to even, however long), and decimal literals whose magnitude may overflow to ±Infinity
/// or underflow to ±0. Only ASCII digits count.
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
        if let radix { return jsIntegerValue(chars.dropFirst(2), radix: radix) }
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
    return jsDecimalValue(literal)
}

/// A validated decimal literal (`-?digits[.digits][e±digits]`) as the nearest Double.
///
/// Swift's parser rounds correctly; should it refuse an out-of-range exponent, JS's answer
/// is ±Infinity, or ±0 for a vanishing one, which is what this returns instead.
func jsDecimalValue(_ literal: String) -> Double? {
    if let value = Double(literal) { return value }
    guard let e = literal.firstIndex(where: { $0 == "e" || $0 == "E" }) else { return nil }
    let mantissa = literal[..<e]
    let negative = mantissa.hasPrefix("-")
    let isZero = mantissa.allSatisfy { $0 == "-" || $0 == "0" || $0 == "." }
    let magnitude: Double = isZero || literal[literal.index(after: e)...].hasPrefix("-") ? 0 : .infinity
    return negative ? -magnitude : magnitude
}

/// `0x`, `0o` and `0b` digits as the nearest Double (ties to even), as StringToNumber rounds
/// them; `nil` if a digit is invalid. Accumulating in a Double would round at every step and
/// drift once the value passes 2^53, so the first 64 significant bits are kept exactly and the
/// rest only as a sticky bit.
private func jsIntegerValue(_ digits: ArraySlice<Character>, radix: Int) -> Double? {
    guard !digits.isEmpty else { return nil }
    let bitsPerDigit = radix.trailingZeroBitCount  // radix is 16, 8 or 2
    var leading: UInt64 = 0  // the first 64 significant bits
    var kept = 0
    var dropped = 0          // significant bits after those
    var sticky = false       // whether any dropped bit is set
    for character in digits {
        guard let digit = character.hexDigitValue, digit < radix else { return nil }
        for shift in stride(from: bitsPerDigit - 1, through: 0, by: -1) {
            let bit = UInt64((digit >> shift) & 1)
            if kept == 0 && bit == 0 { continue }
            if kept < 64 {
                leading = leading << 1 | bit
                kept += 1
            } else {
                dropped += 1
                sticky = sticky || bit == 1
            }
        }
    }
    // 64 bits leave ten below the rounding position, so folding the dropped bits into the
    // lowest one breaks exact ties the right way without creating false ones.
    if sticky { leading |= 1 }
    return Double(sign: .plus, exponent: dropped, significand: Double(leading))
}

/// JS `Number::toString(10)`: `"NaN"`, `"Infinity"`, `"0"` for ±0, integers in plain digits
/// below 1e21, otherwise the shortest round-trip digits placed by the ECMA-262 rules
/// (`1e+21`, `1.5e-7`, `0.000001`).
public func jsNumberString(_ value: Double) -> String {
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
