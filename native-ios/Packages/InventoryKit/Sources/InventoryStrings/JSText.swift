/// String transforms with JavaScript's semantics, for the copy that strings.ts
/// derives from its arguments at runtime.
enum JSText {
    /// `s.toLowerCase()`: the full Unicode lowercase mapping plus the Final_Sigma
    /// rule (Σ at the end of a word becomes ς), which Swift's `lowercased()` omits.
    static func lowercased(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var result = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            if scalar == "\u{03A3}" && isFinalSigma(scalars, at: index) {
                result.append("\u{03C2}")
            } else {
                result.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
            }
        }
        return String(result)
    }

    /// `s.charAt(0).toUpperCase() + s.slice(1)`: only the first UTF-16 code unit
    /// changes. A first character outside the BMP is half a surrogate pair in JS,
    /// which upper-cases to itself, so the string comes back unchanged.
    static func capitalizeFirst(_ s: String) -> String {
        var rest = s.unicodeScalars[...]
        guard let first = rest.popFirst(), first.value <= 0xFFFF else { return s }
        return first.properties.uppercaseMapping + String(rest)
    }

    /// Unicode Final_Sigma: preceded by a cased letter and not followed by one,
    /// skipping case-ignorable characters on both sides.
    private static func isFinalSigma(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        var before = index - 1
        while before >= 0, scalars[before].properties.isCaseIgnorable { before -= 1 }
        guard before >= 0, scalars[before].properties.isCased else { return false }
        var after = index + 1
        while after < scalars.count, scalars[after].properties.isCaseIgnorable { after += 1 }
        return !(after < scalars.count && scalars[after].properties.isCased)
    }
}
