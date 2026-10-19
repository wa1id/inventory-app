import Testing
@testable import InventoryCore

// The stored folded columns (01 §4.4): items.search_text and tags.normalized_name,
// against Fixtures/storedText.json (the RN expressions run in Node).

@Suite("stored text")
struct StoredTextTests {
    @Test("search_text joins name and category, trims, then lowercases")
    func searchText() {
        #expect(itemSearchText(name: "Cordless Drill", category: "Power Tools") == "cordless drill power tools")
        #expect(itemSearchText(name: "Drill", category: nil) == "drill")
        #expect(itemSearchText(name: "", category: nil) == "")
        // Inner spaces survive; only the ends are trimmed (JS set: U+FEFF yes, U+0085 no).
        #expect(itemSearchText(name: "  Drill ", category: " Tools ") == "drill   tools")
        #expect(sameScalars(itemSearchText(name: "\u{FEFF}A", category: "\u{0085}"), "a \u{0085}"))
        // Final sigma: the name's last letter is final even with a category after it.
        #expect(sameScalars(itemSearchText(name: "ΟΔΟΣ", category: "ΣΑΣ"), "οδο\u{03C2} σα\u{03C2}"))
    }

    @Test("normalized_name is the trimmed JS lowercase")
    func tagName() {
        #expect(normalizedTagName("  DeWalt ") == "dewalt")
        #expect(normalizedTagName(" \n ") == "")
        #expect(sameScalars(normalizedTagName("İ"), "i\u{0307}"))
    }

    struct SearchEntry: Decodable { let name: String; let category: String?; let searchText: String }
    struct TagEntry: Decodable { let tag: String; let normalized: String }
    struct File: Decodable { let searchText: [SearchEntry]; let tags: [TagEntry] }

    @Test("match JS over the corpus")
    func matchJS() throws {
        let file = try loadFixture("storedText", as: File.self)
        #expect(file.searchText.count > 800)
        for entry in file.searchText {
            let actual = itemSearchText(name: entry.name, category: entry.category)
            #expect(
                sameScalars(actual, entry.searchText),
                "\(scalarDump(entry.name)) / \(entry.category.map(scalarDump) ?? "nil"): \(scalarDump(actual))"
            )
        }
        for entry in file.tags {
            let actual = normalizedTagName(entry.tag)
            #expect(sameScalars(actual, entry.normalized), "\(scalarDump(entry.tag)): \(scalarDump(actual))")
        }
    }
}
