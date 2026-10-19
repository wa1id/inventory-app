// JavaScript string semantics the RN app relies on, at Unicode-scalar level.
//
// The RN code trims, lowercases and uppercases with JS built-ins (V8/ICU on the
// home server, Hermes on the phone). Their results feed stored columns
// (`search_text`, `tags.normalized_name`), search parameters and codes, so the
// native app reproduces them exactly instead of using Foundation's variants:
// `.whitespacesAndNewlines` differs from JS `trim()` (it keeps U+FEFF and
// strips U+0085), and Swift's `lowercased()` has no Final_Sigma rule.
//
// The target is V8/ICU (the home server, and the vectors in Fixtures/). Foundation's
// `NSString.lowercased` / `CFStringLowercase`, which Hermes on iOS most likely used for
// the data already on devices, applies Final_Sigma differently around `.`, `:`, `·`,
// modifier letters and circled or Roman-numeral letters (01 Q10, still open; see
// JSStringTests "keeps ICU's Final_Sigma where CoreFoundation differs").

extension Unicode.Scalar {
    /// JS `WhiteSpace` or `LineTerminator`: the set `String.prototype.trim()` strips and regex `\s` matches.
    public var isJSWhitespace: Bool {
        switch value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// JS `LineTerminator`: the characters a regex `.` does not match.
    var isJSLineTerminator: Bool {
        switch value {
        case 0x0A, 0x0D, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// `\p{Letter}` or `\p{Number}` (general categories L* and N*).
    var isLetterOrNumber: Bool {
        switch properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    /// ASCII `[0-9]`, the only digits JS regex classes and `Number()` accept.
    var isASCIIDigit: Bool { (0x30...0x39).contains(value) }

    /// ASCII `[0-9a-fA-F]`.
    var isASCIIHexDigit: Bool {
        switch value {
        case 0x30...0x39, 0x41...0x46, 0x61...0x66: return true
        default: return false
        }
    }
}

extension String {
    /// JS `String.prototype.trim()`: strips JS white space and line terminators from both ends.
    public func jsTrimmed() -> String {
        let scalars = unicodeScalars
        guard let first = scalars.firstIndex(where: { !$0.isJSWhitespace }),
              let last = scalars.lastIndex(where: { !$0.isJSWhitespace })
        else { return "" }
        return String(scalars[first...last])
    }

    /// JS `String.prototype.toLowerCase()` as V8 computes it (ICU, root locale).
    ///
    /// Full Unicode case mapping (`İ` → `i̇`), plus the context-sensitive
    /// Final_Sigma rule: `Σ` becomes `ς` when a cased letter precedes it and
    /// none follows, skipping case-ignorable characters on both sides.
    public func jsLowercased() -> String {
        if utf8.allSatisfy({ $0 < 0x80 }) { return lowercased() }
        let scalars = Array(unicodeScalars)
        var out = String.UnicodeScalarView()
        for index in scalars.indices {
            let scalar = scalars[index]
            if scalar.value == 0x03A3 {
                out.append(Self.isFinalSigma(scalars, at: index) ? "\u{03C2}" : "\u{03C3}")
            } else {
                out.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
            }
        }
        return String(out)
    }

    /// JS `String.prototype.toUpperCase()`: full Unicode case mapping (`ß` → `SS`), no context.
    public func jsUppercased() -> String {
        if utf8.allSatisfy({ $0 < 0x80 }) { return uppercased() }
        var out = String.UnicodeScalarView()
        for scalar in unicodeScalars {
            out.append(contentsOf: scalar.properties.uppercaseMapping.unicodeScalars)
        }
        return String(out)
    }

    /// ICU's Final_Sigma test (`ucase.cpp`, `isFollowedByCasedLetter`), which V8 uses.
    private static func isFinalSigma(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        hasCasedLetter(scalars, from: index - 1, step: -1) && !hasCasedLetter(scalars, from: index + 1, step: 1)
    }

    private static func hasCasedLetter(_ scalars: [Unicode.Scalar], from start: Int, step: Int) -> Bool {
        var index = start
        while scalars.indices.contains(index) {
            let properties = scalars[index].properties
            // ICU checks case-ignorable first, so a character that is both is skipped.
            if properties.isCaseIgnorable {
                index += step
                continue
            }
            return properties.isCased
        }
        return false
    }
}
