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
