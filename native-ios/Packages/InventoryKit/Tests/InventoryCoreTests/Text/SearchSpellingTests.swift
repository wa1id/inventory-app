import Testing
@testable import InventoryCore

/// Native only: correcting the words of a search that found nothing (``SearchSpelling``).
@Suite("SearchSpelling")
struct SearchSpellingTests {
    private static let inventory = SearchVocabulary(texts: [
        "cordless drill power tools", "drill bits", "hammer hand tools", "screwdriver set",
        "usb-c cable cables", "garage", "tool chest", "kitchen", "whisk utensils",
    ])

    private func corrected(_ query: String, _ vocabulary: SearchVocabulary = inventory) -> String? {
        SearchSpelling.correctedQuery(query, vocabulary: vocabulary)
    }

    @Test("a missed, wrong, extra or swapped letter is corrected")
    func oneEdit() {
        #expect(corrected("dril") == nil)  // already the start of "drill": known, nothing to correct
        #expect(corrected("drils") == "drill")
        #expect(corrected("drilll") == "drill")
        #expect(corrected("dirll") == "drill")
        #expect(corrected("hamer") == "hammer")
        #expect(corrected("wihsk") == "whisk")
    }

    @Test("long words allow two edits, short ones one, and under four letters none")
    func editsByLength() {
        #expect(corrected("scrwedrivr") == "screwdriver")
        #expect(corrected("kitchn") == "kitchen")
        #expect(corrected("hmmr") == nil)  // two edits from "hammer" is too many for four letters
        #expect(corrected("drl") == nil)
    }

    @Test("a mistyped start of a longer word finds that word")
    func prefix() {
        #expect(corrected("scewdr") == "screwdriver")
        #expect(corrected("garag") == nil)  // known: "garage" contains it
    }

    @Test("known terms stay, unknown ones are corrected, hopeless ones dropped")
    func severalTerms() {
        #expect(corrected("cordless drils") == "cordless drill")
        #expect(corrected("blue drils") == "drill")
        #expect(corrected("purple zebra") == nil)
        #expect(corrected("cordless drill") == nil)  // nothing unknown: the search was simply empty
    }

    @Test("separators and accents are matched as the search matches them")
    func compactAndAccents() {
        #expect(corrected("usbc") == nil)  // known through the compact form of "usb-c"
        #expect(corrected("Hämmer") == nil)  // folds to "hammer", which is known
        #expect(corrected("Hämer") == "hammer")
        #expect(corrected("DRILS") == "drill")
    }

    @Test("closer words win, then whole words, then the more frequent word")
    func ranking() {
        let words = SearchVocabulary(counts: ["cable": 5, "table": 1, "fable": 9])
        #expect(corrected("cabke", words) == "cable")  // one edit from cable, two from the others
        let tie = SearchVocabulary(counts: ["cable": 2, "table": 7])
        #expect(corrected("xable", tie) == "table")  // one edit from both: the more frequent
        let whole = SearchVocabulary(counts: ["tape": 1, "tapestry": 50])
        #expect(corrected("tapw", whole) == "tape")  // the whole word before the start of a longer one
    }

    @Test("two terms corrected to the same word are searched once")
    func dedupes() {
        #expect(corrected("drils drilk") == "drill")
    }

    @Test("an empty vocabulary or query corrects nothing")
    func empty() {
        #expect(corrected("drils", .empty) == nil)
        #expect(corrected("   ") == nil)
    }

    @Test("the vocabulary counts words as the query tokenizer splits and folds them")
    func vocabulary() {
        let words = SearchVocabulary(texts: ["Tool Chest", "tool box", "Küche"])
        #expect(words.counts == ["tool": 2, "chest": 1, "box": 1, "kuche": 1])
    }

    @Test("the vocabulary splits texts into words exactly as the query tokenizer does", arguments: [
        "cordless drill power tools", "  double  spaces ", "usb-c --cable-- -", "Crème brûlée torch crème",
        "ΟΔΟΣ ΟΔΟΣ οδοσ", "™ ﬁle ½ cup", "no\u{00A0}break here", "e\u{0301}cole école",
        "a b c d e f g h i j k l m n", "a/b/c/d/e/f/g/h/i/j/k/l/m/n", "x a/b/c/d/e/f/g/h/i/j/k/l/m", "zoë’s café",
        "", " ", "-", "drill drill drill",
    ])
    func vocabularyWords(text: String) {
        var pieces: [Substring: [String]] = [:]
        #expect(SearchVocabulary.words(of: text, pieces: &pieces) == tokenizeQuery(text))
        // Again, from the pieces already seen.
        #expect(SearchVocabulary.words(of: text, pieces: &pieces) == tokenizeQuery(text))
    }

    @Test("an ASCII word's compact form is compactAlphanumeric's", arguments: ["usb-c", "USB-C", "4x40", "a-b-c", "TM", "--", "Z9-q"])
    func asciiCompact(word: String) {
        #expect(SearchVocabulary.compact(word) == compactAlphanumeric(word))
    }

    @Test("words are kept shortest first, and the length index finds the long enough ones")
    func lengthIndex() {
        let words = SearchVocabulary(counts: ["ab": 1, "abc": 1, "drill": 2, "hammer": 1, "whisk": 1, "screwdriver": 1])
        for length in 0...13 {
            let expected = words.entries.filter { $0.scalars.count >= length }.map(\.text).sorted()
            #expect(words.entries(atLeast: length).map(\.text).sorted() == expected, "length \(length)")
        }
        #expect(words.entries.map(\.scalars.count) == words.entries.map(\.scalars.count).sorted())
        #expect(SearchVocabulary.empty.entries(atLeast: 4).isEmpty)
    }

    @Test("the one-table correction picks the same word as four tables per word, on random typos")
    func sameAsFourTables() {
        var random = SearchSpellingTestRandom(seed: 0xC0FFEE)
        let letters = Array("abcdeilnorstu")
        var counts: [String: Int] = [:]
        while counts.count < 600 {
            let word = String((0..<(2 + random.below(10))).map { _ in letters[random.below(letters.count)] })
            counts[word, default: 0] += 1 + random.below(5)
        }
        let vocabulary = SearchVocabulary(counts: counts)
        let words = Array(counts.keys).sorted()
        var checked = 0
        for _ in 0..<400 {
            var typed = Array(words[random.below(words.count)].unicodeScalars)
            for _ in 0..<(1 + random.below(3)) {
                let position = random.below(typed.count + 1)
                switch random.below(4) {
                case 0: typed.insert(Unicode.Scalar(UInt8(ascii: "a") + UInt8(random.below(26))), at: position)
                case 1 where typed.count > 1: typed.remove(at: min(position, typed.count - 1))
                case 2 where position + 1 < typed.count: typed.swapAt(position, position + 1)
                default: if position < typed.count { typed[position] = "z" }
                }
            }
            let term = String(String.UnicodeScalarView(typed))
            guard tokenizeQuery(term) == [term] else { continue }
            #expect(SearchSpelling.closestWord(to: term, in: vocabulary) == Self.fourTableClosestWord(to: term, in: vocabulary), "\(term)")
            // A shorter piece of it, so some terms are known.
            let piece = String(term.prefix(1 + random.below(term.count)))
            for candidate in [term, piece] {
                let known = vocabulary.entries.contains { $0.text.contains(candidate) }
                #expect(SearchSpelling.isKnown(candidate, in: vocabulary) == known, "\(candidate)")
            }
            checked += 1
        }
        #expect(checked > 300)
    }

    /// The correction as first written: four edit-distance tables per word (the whole word and
    /// three of its starts). The reference ``SearchSpelling/closestWord(to:in:)`` must agree with.
    private static func fourTableClosestWord(to term: String, in vocabulary: SearchVocabulary) -> String? {
        let typed = Array(term.unicodeScalars)
        let limit = SearchSpelling.allowedEdits(forLength: typed.count)
        guard limit > 0 else { return nil }
        var best: (edits: Int, prefix: Int, rarity: Int, word: String)?
        for entry in vocabulary.entries where entry.scalars.count >= 3 {
            let word = entry.scalars
            var edits = limit + 1
            var prefix = 0
            if abs(word.count - typed.count) <= limit {
                edits = SearchSpelling.editDistance(typed, word, limit: limit)
            }
            let shortest = max(1, typed.count - 1), longest = min(word.count - 1, typed.count + 1)
            if shortest <= longest {
                for length in shortest...longest {
                    let start = SearchSpelling.editDistance(typed, Array(word[0..<length]), limit: limit)
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

    @Test("edit distance counts a swap of neighbours as one and stops past the limit")
    func distance() {
        func d(_ a: String, _ b: String, _ limit: Int = 5) -> Int {
            SearchSpelling.editDistance(Array(a.unicodeScalars), Array(b.unicodeScalars), limit: limit)
        }
        #expect(d("drill", "drill") == 0)
        #expect(d("dirll", "drill") == 1)
        #expect(d("kitten", "sitting") == 3)
        #expect(d("kitten", "sitting", 1) == 2)
        #expect(d("", "abc") == 3)
    }
}

/// SplitMix64, so the random typos are the same on every run.
private struct SearchSpellingTestRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func below(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(max(1, bound)))
    }
}
