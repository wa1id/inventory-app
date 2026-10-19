// RN: src/ui/code.ts, plus codeProblem and serverHost from src/ui/household/join.ts.
// Household and recovery codes as a person types them, folded the same way the
// servers decode them, and the home server's address as Settings shows it.

/// Strip whitespace and hyphens, upper-case (JS rules), fold `I`/`L` to `1` and `O` to `0` (RN `normaliseCode`).
public func normaliseCode(_ input: String) -> String {
    var stripped = String.UnicodeScalarView()
    stripped.append(contentsOf: input.unicodeScalars.lazy.filter { !$0.isJSWhitespace && $0 != "-" })
    var out = String.UnicodeScalarView()
    for scalar in String(stripped).jsUppercased().unicodeScalars {
        switch scalar {
        case "I", "L": out.append("1")
        case "O": out.append("0")
        default: out.append(scalar)
        }
    }
    return String(out)
}

/// The characters of a normalised code that no code can contain (`U`, punctuation), each once, in order
/// (RN `invalidCodeChars`).
public func invalidCodeChars(_ normalised: String) -> [String] {
    var seen: [Unicode.Scalar] = []
    for scalar in normalised.unicodeScalars where !isCodeCharacter(scalar) && !seen.contains(scalar) {
        seen.append(scalar)
    }
    return seen.map { String($0) }
}

/// Groups of five joined by hyphens, as the code is printed: `MMWKY-M2H78-A` (RN `formatCode`).
public func formatCode(_ normalised: String) -> String {
    groupedInFives(normalised)
}

/// Household codes and recovery codes are both 16 bytes of Crockford base32: 26 characters
/// (RN `CODE_LENGTH`, src/ui/household/join.ts:12).
public let codeLength = 26

/// What is wrong with a normalised code (RN `CodeProblem`, src/ui/household/join.ts:14-15).
public enum CodeProblem: Sendable, Hashable {
    /// Characters no code uses, each once, joined by spaces: `U %`.
    case chars(String)
    /// The code has `count` characters (UTF-16 units, as JS `length` counts) instead of the expected length.
    case length(count: Int)
}

/// What is wrong with a normalised code, or `nil` (RN `codeProblem`, src/ui/household/join.ts:22-27).
///
/// Characters are checked first: a code with a `U` in it is wrong whatever its
/// length, and saying so points at the character to check.
public func codeProblem(_ normalised: String, length: Int = codeLength) -> CodeProblem? {
    let bad = invalidCodeChars(normalised)
    if !bad.isEmpty { return .chars(bad.joined(separator: " ")) }
    let count = normalised.utf16.count
    if count != length { return .length(count: count) }
    return nil
}

/// RN `/^[0-9A-HJKMNP-TV-Z]$/`.
private func isCodeCharacter(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x30...0x39, 0x41...0x48, 0x4A, 0x4B, 0x4D, 0x4E, 0x50...0x54, 0x56...0x5A: true
    default: false
    }
}

/// The host of the home server's address, for "Home server: inventory.wystudio.be" (RN `serverHost`).
///
/// Trims, drops a leading `scheme://`, then cuts at the first `/`, `?` or `#`.
/// If nothing is left, returns `origin` untrimmed.
public func serverHost(_ origin: String) -> String {
    var scalars = Array(origin.jsTrimmed().unicodeScalars)

    // /^[a-z][a-z0-9+.-]*:\/\//i (ASCII only, even with the i flag).
    if let first = scalars.first, first.isASCIILetter {
        var index = 1
        while index < scalars.count, scalars[index].isASCIILetter || scalars[index].isASCIIDigit
            || scalars[index] == "+" || scalars[index] == "." || scalars[index] == "-"
        {
            index += 1
        }
        if Array(scalars.dropFirst(index).prefix(3)) == [":", "/", "/"] {
            scalars.removeFirst(index + 3)
        }
    }

    // /[/?#].*$/: `.` stops at line terminators, so the match can only start after the last one.
    let searchStart = (scalars.lastIndex(where: \.isJSLineTerminator) ?? -1) + 1
    if let cut = scalars[searchStart...].firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
        scalars.removeSubrange(cut...)
    }

    return scalars.isEmpty ? origin : String(String.UnicodeScalarView(scalars))
}

extension Unicode.Scalar {
    fileprivate var isASCIILetter: Bool {
        (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
    }
}
