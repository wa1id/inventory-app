import Foundation

// RN: src/core/tokenize.ts. Search terms and the punctuation-free "compact"
// form shared by search SQL parameters and the place picker filter.

/// Upper bound on query terms; each term adds a set of OR'd LIKE comparisons to the search SQL.
let maxSearchTerms = 12

/// Splits a raw search query into normalized, deduplicated terms (RN `tokenizeQuery`).
///
/// Lowercase (JS rules), then NFKD, then strip U+0300–U+036F, then split on
/// anything that is not a letter, a number or an ASCII `-`; trim dashes from
/// each piece, drop empty pieces, dedupe in first-seen order and stop at 12.
/// NFKD runs after lowercasing and is not lowercased again, so `™` gives `TM`.
public func tokenizeQuery(_ query: String) -> [String] {
    if query.isEmpty { return [] }
    var terms: [[Unicode.Scalar]] = []
    var piece: [Unicode.Scalar] = []

    func flush() {
        defer { piece.removeAll(keepingCapacity: true) }
        let trimmed = piece.trimmingDashes()
        guard !trimmed.isEmpty, !terms.contains(trimmed) else { return }
        terms.append(trimmed)
    }

    for scalar in foldedScalars(query) {
        if scalar.isLetterOrNumber || scalar == "-" {
            piece.append(scalar)
        } else if !piece.isEmpty {
            flush()
            if terms.count >= maxSearchTerms { break }
        }
    }
    if terms.count < maxSearchTerms, !piece.isEmpty { flush() }

    return terms.map { String(String.UnicodeScalarView($0)) }
}

/// Escapes LIKE wildcards (`\`, `%`, `_`) with `\` and wraps the term in `%…%` (RN `toLikePattern`).
///
/// Always used with `ESCAPE '\'`.
public func toLikePattern(_ term: String) -> String {
    var out = "%"
    for scalar in term.unicodeScalars {
        if scalar == "\\" || scalar == "%" || scalar == "_" { out.unicodeScalars.append("\\") }
        out.unicodeScalars.append(scalar)
    }
    out.unicodeScalars.append("%")
    return out
}

/// Lowercase, fold accents and drop everything but letters and numbers of any script (RN `compactAlphanumeric`).
///
/// `USB-C`, `usb c` and `usb/c` all give `usbc`; `Küche` gives `kuche`.
public func compactAlphanumeric(_ value: String) -> String {
    var out = String.UnicodeScalarView()
    for scalar in foldedScalars(value) where scalar.isLetterOrNumber {
        out.append(scalar)
    }
    return String(out)
}

/// The form container short codes are compared in; same as `compactAlphanumeric` (RN `normalizeForCodeMatch`).
public func normalizeForCodeMatch(_ value: String) -> String {
    compactAlphanumeric(value)
}

/// `toLowerCase()` → `normalize('NFKD')` → remove U+0300–U+036F, in that order.
private func foldedScalars(_ value: String) -> [Unicode.Scalar] {
    value.jsLowercased()
        .decomposedStringWithCompatibilityMapping
        .unicodeScalars
        .filter { !(0x0300...0x036F).contains($0.value) }
}

extension Array where Element == Unicode.Scalar {
    /// RN `term.replace(/^-+|-+$/g, '')`.
    fileprivate func trimmingDashes() -> [Unicode.Scalar] {
        guard let first = firstIndex(where: { $0 != "-" }), let last = lastIndex(where: { $0 != "-" }) else {
            return []
        }
        return Array(self[first...last])
    }
}
