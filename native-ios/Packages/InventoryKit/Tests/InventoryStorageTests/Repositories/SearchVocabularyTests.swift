import InventoryCore
import Testing
@testable import InventoryStorage

/// Native only: the words a search that found nothing is corrected against
/// (``LocalSearchRepository/vocabulary()``).
@Suite("search vocabulary")
struct SearchVocabularyTests {
    @Test("holds the words of item names, categories, tags, spaces and containers")
    func words() async throws {
        let seeded = try await SearchTests.seedInventory()
        let words = try await seeded.repos.search.vocabulary()
        for word in ["cordless", "drill", "power", "tools", "hammer", "whisk", "utensils", "dewalt", "18v",
                     "garage", "kitchen", "tool", "box", "utensil", "drawer"] {
            #expect(words.counts[word] != nil, "missing \(word)")
        }
        // "tools" twice (Power Tools, Hand Tools); "tool" once (Tool Box).
        #expect(words.counts["tools"] == 2)
        #expect(words.counts["tool"] == 1)
    }

    @Test("a misspelt query is corrected to words the search then finds")
    func correctsToFindableWords() async throws {
        let seeded = try await SearchTests.seedInventory()
        let repos = seeded.repos
        #expect(try await repos.search.search("dril hamer").items.isEmpty)
        let words = try await repos.search.vocabulary()
        let corrected = try #require(SearchSpelling.correctedQuery("dril hamer", vocabulary: words))
        #expect(corrected == "dril hammer")
        let found = try await repos.search.search("cordlss")
        #expect(found.items.isEmpty)
        let shown = try #require(SearchSpelling.correctedQuery("cordlss", vocabulary: words))
        #expect(shown == "cordless")
        #expect(try await repos.search.search(shown).items.map(\.item.item.name) == ["Cordless Drill"])
    }
}
