/// Search terms marked in a row's text, so a result shows why it matched (RN `splitHighlight`
/// in src/ui/components/AppText.tsx, matching the desk's `highlight()`; 06 §5.7).
public enum TextHighlight {
    /// `text` split around the search terms of two or more characters: even indexes are plain
    /// text, odd indexes are matches, with the text's own spelling. A match at either end
    /// leaves an empty string there, as JS `split` does.
    ///
    /// Exactly RN's `text.split(new RegExp("(t1|t2|…)", "gi"))` with every term escaped:
    /// - a term counts only when longer than one UTF-16 code unit;
    /// - at each position the terms are tried in the order given and the first that matches
    ///   wins (alternation, not the longest match); matching resumes after it;
    /// - case is ignored as a non-Unicode JS regex ignores it: two code units match when they
    ///   upper-case to the same single code unit, and a non-ASCII unit never matches an ASCII
    ///   one (`ſ` is not `s`, `ß` matches only `ß`).
    public static func split(_ text: String, terms: [String]) -> [String] {
        let usable = terms.map { Array($0.utf16) }.filter { $0.count > 1 }
        guard !usable.isEmpty else { return [text] }
        let units = Array(text.utf16)
        let folded = units.map(canonicalize)
        let patterns = usable.map { $0.map(canonicalize) }

        var parts: [String] = []
        var start = 0
        var position = 0
        while position < units.count {
            guard let length = patterns.first(where: { matches($0, in: folded, at: position) })?.count else {
                position += 1
                continue
            }
            parts.append(string(units[start..<position]))
            parts.append(string(units[position..<position + length]))
            position += length
            start = position
        }
        parts.append(string(units[start..<units.count]))
        return parts
    }

    private static func matches(_ pattern: [UInt16], in folded: [UInt16], at position: Int) -> Bool {
        guard position + pattern.count <= folded.count else { return false }
        return folded[position..<position + pattern.count].elementsEqual(pattern)
    }

    /// ECMAScript `Canonicalize` without the `u` flag: the code unit's upper-case form when that
    /// is a single code unit, unless it would turn a non-ASCII unit into an ASCII one.
    static func canonicalize(_ unit: UInt16) -> UInt16 {
        guard let scalar = Unicode.Scalar(unit) else { return unit }  // a lone surrogate
        let upper = Array(scalar.properties.uppercaseMapping.utf16)
        guard upper.count == 1 else { return unit }
        let mapped = upper[0]
        if unit >= 128 && mapped < 128 { return unit }
        return mapped
    }

    private static func string(_ units: ArraySlice<UInt16>) -> String {
        String(decoding: units, as: UTF16.self)
    }
}
