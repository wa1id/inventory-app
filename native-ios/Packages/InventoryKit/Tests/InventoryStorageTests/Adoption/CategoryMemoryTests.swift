import Foundation
import Testing
@testable import InventoryStorage

/// `suggestCategories` from `src/ui/components/__tests__/textHelpers.test.tsx`, plus parity
/// vectors from the real `categoryMemory.ts` (01 §8.3). RN has no persistence tests here.
@Suite("CategoryMemory (categoryMemory.ts)")
@MainActor
struct CategoryMemoryTests {
    let known = ["Tools", "Toys", "tools", "Kitchen", "Tape", "Tins", "Tea", "Towels", "Tiles"]

    @Test("suggestCategories offers known categories that start with what is typed, once each")
    func startsWithTyped() {
        #expect(CategoryMemory.suggest(known, prefix: "to") == ["Tools", "Toys", "Towels"])
    }

    @Test("suggestCategories hides an exact match and caps the list at six")
    func hidesExactAndCaps() {
        #expect(CategoryMemory.suggest(known, prefix: "Tools") == [])
        #expect(CategoryMemory.suggest(known, prefix: "").count == 6)
    }

    struct SuggestVector: Decodable {
        let known: [String]
        let prefix: String
        let max: Int?
        let expected: [String]
    }

    @Test("suggest matches suggestCategories (TS vectors: trim, case folding, final sigma, code units)")
    func suggestVectors() throws {
        for vector in try AdoptionFixtures.decode([SuggestVector].self, from: "suggest-categories-vectors.json") {
            let result = CategoryMemory.suggest(vector.known, prefix: vector.prefix, max: vector.max ?? CategoryMemory.maxSuggestions)
            #expect(result == vector.expected, "prefix \(vector.prefix.debugDescription)")
            // Swift's == folds canonically equivalent strings; JS compares code units.
            #expect(result.map { Array($0.utf16) } == vector.expected.map { Array($0.utf16) })
        }
    }

    struct MemoryScenario: Decodable {
        struct Step: Decodable {
            let op: String
            let categories: [String?]?
            let category: String?
        }
        struct Expected: Decodable {
            let known: [String]
            let persisted: String?
        }
        let name: String
        let stored: String?
        let steps: [Step]
        let expected: Expected
    }

    @Test("load, seen and record behave like the TS module (vectors)")
    func memoryVectors() throws {
        for scenario in try AdoptionFixtures.decode([MemoryScenario].self, from: "category-memory-vectors.json") {
            let preferences = InMemoryPreferences(scenario.stored.map { [PreferenceKey.recentCategories: $0] } ?? [:])
            let memory = CategoryMemory(preferences: preferences)
            for step in scenario.steps {
                switch step.op {
                case "mount": _ = memory.known
                case "seen": memory.rememberCategories(step.categories ?? [])
                default: memory.record(step.category)
                }
            }
            #expect(memory.known == scenario.expected.known, "\(scenario.name)")
            #expect(preferences.values[PreferenceKey.recentCategories] == scenario.expected.persisted, "\(scenario.name)")
        }
    }

    @Test("02 §11.2 #4: stored categories are trimmed, deduped, filtered and capped on read")
    func decodeRule() {
        #expect(CategoryMemory.decodeSaved(#"{"a":1}"#) == [])
        #expect(CategoryMemory.decodeSaved(#"[" Tools ","tools",2,"","Toys"]"#) == ["Tools", "Toys"])
        let many = "[" + (1...25).map { "\"c\($0)\"" }.joined(separator: ",") + "]"
        #expect(CategoryMemory.decodeSaved(many).count == 20)
    }

    @Test("a category recorded before anything read the stored list keeps the stored ones (RN race not ported)")
    func recordBeforeLoad() {
        let preferences = InMemoryPreferences([PreferenceKey.recentCategories: #"["Tools","Kitchen"]"#])
        let memory = CategoryMemory(preferences: preferences)
        memory.record("Garden")
        #expect(preferences.values[PreferenceKey.recentCategories] == #"["Garden","Tools","Kitchen"]"#)
        #expect(memory.known == ["Garden", "Tools", "Kitchen"])
    }

    @Test("suggestions read the known list")
    func suggestions() {
        let memory = CategoryMemory(preferences: InMemoryPreferences([PreferenceKey.recentCategories: #"["Toys"]"#]))
        memory.rememberCategories(["Tools", nil, "Kitchen"])
        #expect(memory.suggestions(for: "to") == ["Toys", "Tools"])
    }

    @Test("persisted JSON escapes like JSON.stringify")
    func persistedEscaping() {
        let preferences = InMemoryPreferences()
        CategoryMemory(preferences: preferences).record("DIY/\"Tools\"\\é\u{1}")
        #expect(preferences.values[PreferenceKey.recentCategories] == #"["DIY/\"Tools\"\\é\u0001"]"#)
    }
}
