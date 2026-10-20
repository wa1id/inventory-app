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
    /// Every word, shortest first (then by text), so a correction can skip the words too short
    /// to be close (docs/PERFORMANCE.md: 10 000 items can hold thousands of distinct words).
    let entries: [Entry]
    /// `lengthStarts[n]` is the index in ``entries`` of the first word of `n` or more scalars,
    /// for `n` up to one past the longest word.
    let lengthStarts: [Int]

    public init(counts: [String: Int] = [:]) {
        self.counts = counts
        let entries = counts
            .map { Entry(text: $0.key, scalars: Array($0.key.unicodeScalars), compact: Self.compact($0.key), count: $0.value) }
            .sorted { ($0.scalars.count, $0.text) < ($1.scalars.count, $1.text) }
        let longest = entries.last?.scalars.count ?? 0
        var starts = [Int](repeating: entries.count, count: longest + 2)
        var index = entries.count
        for length in stride(from: longest + 1, through: 0, by: -1) {
            while index > 0, entries[index - 1].scalars.count >= length { index -= 1 }
            starts[length] = index
        }
        self.entries = entries
        lengthStarts = starts
    }

    /// Counts the words of each text: a word counts once per text it is in.
    public init(texts: some Sequence<String>) {
        var counts: [String: Int] = [:]
        // Folding is the costly part and inventories repeat their words, so each space-separated
        // piece is tokenized once: 10 000 items take a third of the time (docs/PERFORMANCE.md).
        var pieces: [Substring: [String]] = [:]
        for text in texts {
            for word in Self.words(of: text, pieces: &pieces) { counts[word, default: 0] += 1 }
        }
        self.init(counts: counts)
    }

    public static let empty = SearchVocabulary()

    public var isEmpty: Bool { counts.isEmpty }

    /// The words of at least `length` scalars.
    func entries(atLeast length: Int) -> ArraySlice<Entry> {
        let length = max(0, length)
        guard length < lengthStarts.count else { return entries[entries.endIndex...] }
        return entries[lengthStarts[length]...]
    }

    /// ``tokenizeQuery(_:)`` of `text`, from the tokens of its space-separated pieces.
    ///
    /// The same terms in the same order: a lone space is a separator to the tokenizer, and folding
    /// never reaches across it (lowercasing's one context, the final sigma, stops at a space;
    /// decomposition and the accent strip work within a character). A piece whose own terms
    /// reach the tokenizer's cap could hide a later term, so that text is tokenized whole.
    static func words(of text: String, pieces: inout [Substring: [String]]) -> [String] {
        var terms: [String] = []
        for piece in text.split(separator: " ") {
            let pieceTerms: [String]
            if let known = pieces[piece] {
                pieceTerms = known
            } else {
                pieceTerms = tokenizeQuery(String(piece))
                pieces[piece] = pieceTerms
            }
            if pieceTerms.count >= maxSearchTerms { return tokenizeQuery(text) }
            for term in pieceTerms where !terms.contains(term) {
                terms.append(term)
                if terms.count >= maxSearchTerms { return terms }
            }
        }
        return terms
    }

    /// ``compactAlphanumeric(_:)``, without the Unicode folding for an ASCII word, where it
    /// changes nothing but the case.
    static func compact(_ word: String) -> String {
        guard word.utf8.allSatisfy({ $0 < 0x80 }) else { return compactAlphanumeric(word) }
        var out = String.UnicodeScalarView()
        for scalar in word.unicodeScalars {
            switch scalar.value {
            case 0x30...0x39, 0x61...0x7A: out.append(scalar)
            case 0x41...0x5A: out.append(Unicode.Scalar(scalar.value + 0x20) ?? scalar)
            default: break
            }
        }
        return String(out)
    }
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
        var table = SpellingTable(typed: typed, limit: limit)
        // Smaller is better, field by field.
        var best: (edits: Int, prefix: Int, rarity: Int, word: String)?
        // A word more than `limit` letters shorter than the term is too far from it as a whole
        // word, and too short to start with it.
        for entry in vocabulary.entries(atLeast: max(3, typed.count - limit)) {
            guard let distances = table.distances(to: entry.scalars) else { continue }
            var edits = distances.whole
            var prefix = 0
            // The term may be the start of a longer word, mistyped.
            if distances.start < edits {
                edits = distances.start
                prefix = 1
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

/// One term's optimal string alignment table (``SearchSpelling/editDistance(_:_:limit:)``)
/// against word after word, its rows reused.
///
/// One table answers both questions a correction asks of a word: its last row holds the
/// distance from the term to every start of the word, the whole word included, where four
/// separate tables (each with its own arrays) used to. Same distances, so the same corrections
/// (`SearchSpellingTests` checks it against the four-table way on random words).
struct SpellingTable {
    let typed: [Unicode.Scalar]
    let limit: Int
    private var beforePrevious: [Int]
    private var previous: [Int]
    private var current: [Int]

    init(typed: [Unicode.Scalar], limit: Int) {
        self.typed = typed
        self.limit = limit
        // Columns past `typed.count + limit` only hold distances over the limit.
        let width = typed.count + limit + 1
        beforePrevious = [Int](repeating: 0, count: width)
        previous = [Int](repeating: 0, count: width)
        current = [Int](repeating: 0, count: width)
    }

    /// The edits from the term to the whole `word` (when their lengths are within `limit`) and
    /// to the closest of the word's starts one letter shorter than the term to one letter longer
    /// (each shorter than the word itself); `limit + 1` stands for more than `limit`. Nil when
    /// neither can be within `limit`.
    mutating func distances(to word: [Unicode.Scalar]) -> (whole: Int, start: Int)? {
        let n = typed.count, m = word.count
        guard n > 0, m > 0 else { return nil }
        let tooMany = limit + 1
        let columns = min(m, n + limit)
        for j in 0...columns { previous[j] = j }
        for i in 1...n {
            current[0] = i
            var rowMinimum = i
            for j in 1...columns {
                let cost = typed[i - 1] == word[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, typed[i - 1] == word[j - 2], typed[i - 2] == word[j - 1] {
                    value = min(value, beforePrevious[j - 2] + 1)
                }
                current[j] = value
                rowMinimum = min(rowMinimum, value)
            }
            // No later row can come back within the limit.
            if rowMinimum > limit { return nil }
            (beforePrevious, previous, current) = (previous, current, beforePrevious)
        }
        // `previous` is the last row: the term against the word's first j letters.
        let whole = abs(m - n) <= limit ? min(previous[m], tooMany) : tooMany
        var start = tooMany
        let shortest = max(1, n - 1), longest = min(m - 1, n + 1)
        if shortest <= longest {
            for j in shortest...longest { start = min(start, previous[j]) }
        }
        return (whole, start)
    }
}
