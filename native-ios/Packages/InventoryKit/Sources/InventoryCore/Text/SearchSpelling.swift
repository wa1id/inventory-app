import Foundation

// Native only: RN had no spelling correction. When a search finds nothing, Home corrects the
// query's unknown words against the words the inventory itself uses and searches again
// (SearchModel). The search SQL is untouched, so local and household search still return what
// the home server's would (DECISIONS U12); only the words searched for change.

/// The words an inventory uses (item names and categories, tags, space and container names),
/// split and folded as ``tokenizeQuery(_:)`` splits and folds a query, with how often each occurs.
public struct SearchVocabulary: Sendable, Hashable {
    struct Entry: Sendable, Hashable {
        var text: String
        var scalars: [Unicode.Scalar]
        /// ``compactAlphanumeric(_:)`` of the word, so `usbc` is known when `usb-c` is.
        var compact: String
        var count: Int
    }

    /// Each word and how many times it occurs.
    public let counts: [String: Int]
    let entries: [Entry]

    public init(counts: [String: Int] = [:]) {
        self.counts = counts
        entries = counts
            .map { Entry(text: $0.key, scalars: Array($0.key.unicodeScalars), compact: compactAlphanumeric($0.key), count: $0.value) }
            .sorted { $0.text < $1.text }
    }

    /// Counts the words of each text.
    public init(texts: some Sequence<String>) {
        var counts: [String: Int] = [:]
        for text in texts {
            for word in tokenizeQuery(text) { counts[word, default: 0] += 1 }
        }
        self.init(counts: counts)
    }

    public static let empty = SearchVocabulary()

    public var isEmpty: Bool { counts.isEmpty }
}

/// Corrects the words of a search that found nothing.
public enum SearchSpelling {
    /// Terms shorter than this are never corrected: too many words are one letter away from them.
    static let minimumLength = 4

    /// Edits allowed for a term of `length` letters: none below 4, one up to 5, two from 6.
    static func allowedEdits(forLength length: Int) -> Int {
        switch length {
        case ..<minimumLength: 0
        case ...5: 1
        default: 2
        }
    }

    /// What to search instead of `query`, which found nothing.
    ///
    /// A term that some known word contains (as the search's `LIKE '%term%'` would find it) is
    /// kept. Any other term is replaced by the closest known word: the fewest edits (a typed,
    /// missed, extra or swapped letter each count one), whole words before the start of a longer
    /// word (`screwdr` for `screwdriver`), then the more frequent word. A term with no word close
    /// enough is dropped. Nil when no term changes, or when no term is left.
    public static func correctedQuery(_ query: String, vocabulary: SearchVocabulary) -> String? {
        let terms = tokenizeQuery(query)
        guard !terms.isEmpty, !vocabulary.isEmpty else { return nil }
        var corrected: [String] = []
        var changed = false
        for term in terms {
            if isKnown(term, in: vocabulary) {
                corrected.append(term)
            } else {
                changed = true
                if let word = closestWord(to: term, in: vocabulary), !corrected.contains(word) {
                    corrected.append(word)
                }
            }
        }
        guard changed, !corrected.isEmpty else { return nil }
        return corrected.joined(separator: " ")
    }

    static func isKnown(_ term: String, in vocabulary: SearchVocabulary) -> Bool {
        let compact = compactAlphanumeric(term)
        return vocabulary.entries.contains { entry in
            entry.text.contains(term) || (!compact.isEmpty && entry.compact.contains(compact))
        }
    }

    static func closestWord(to term: String, in vocabulary: SearchVocabulary) -> String? {
        let typed = Array(term.unicodeScalars)
        let limit = allowedEdits(forLength: typed.count)
        guard limit > 0 else { return nil }
        // Smaller is better, field by field.
        var best: (edits: Int, prefix: Int, rarity: Int, word: String)?
        for entry in vocabulary.entries where entry.scalars.count >= 3 {
            let word = entry.scalars
            var edits = limit + 1
            var prefix = 0
            if abs(word.count - typed.count) <= limit {
                edits = editDistance(typed, word, limit: limit)
            }
            // The term may be the start of a longer word, mistyped.
            let shortest = max(1, typed.count - 1), longest = min(word.count - 1, typed.count + 1)
            if shortest <= longest {
                for length in shortest...longest {
                    let start = editDistance(typed, Array(word[0..<length]), limit: limit)
                    if start < edits {
                        edits = start
                        prefix = 1
                    }
                }
            }
            guard edits <= limit else { continue }
            let candidate = (edits: edits, prefix: prefix, rarity: -entry.count, word: entry.text)
            if let current = best, current <= candidate { continue }
            best = candidate
        }
        return best?.word
    }

    /// The optimal string alignment distance (insertions, deletions, substitutions and swaps of
    /// two neighbouring letters), or `limit + 1` as soon as it must exceed `limit`.
    static func editDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var beforePrevious = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMinimum = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, beforePrevious[j - 2] + 1)
                }
                current[j] = value
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > limit { return limit + 1 }
            (beforePrevious, previous, current) = (previous, current, beforePrevious)
        }
        return min(previous[b.count], limit + 1)
    }
}
