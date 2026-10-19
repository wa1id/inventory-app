import Foundation
import InventoryNetwork
import InventoryStorage
import InventoryStrings
import Testing
@testable import InventoryAppModels

/// `src/ui/components/__tests__/textHelpers.test.tsx` › suggestCategories: the Category chips
/// the item forms offer come from InventoryStorage's `CategoryMemory` (01 §8.3).
@MainActor
@Suite("suggestCategories (textHelpers.test.tsx)")
struct EntitiesSuggestCategoriesTests {
    private let known = ["Tools", "Toys", "tools", "Kitchen", "Tape", "Tins", "Tea", "Towels", "Tiles"]

    @Test("offers known categories that start with what is typed, once each")
    func startsWithTyped() {
        #expect(CategoryMemory.suggest(known, prefix: "to") == ["Tools", "Toys", "Towels"])
    }

    @Test("hides an exact match and caps the list at six")
    func hidesExactAndCaps() {
        #expect(CategoryMemory.suggest(known, prefix: "Tools") == [])
        #expect(CategoryMemory.suggest(known, prefix: "").count == 6)
    }
}

/// `src/ui/components/__tests__/ItemForm.test.tsx`.
@Suite("validateItemForm (ItemForm.test.tsx)")
struct EntitiesValidateItemFormTests {
    private func values(name: String = "", category: String = "", tags: String = "", quantity: String = "1", notes: String = "") -> ItemFormValues {
        ItemFormValues(name: name, category: category, tags: tags, quantity: quantity, notes: notes)
    }

    @Test("accepts a minimal item")
    func acceptsMinimal() {
        let (errors, parsed) = ItemForm.validate(values(name: "Drill"))
        #expect(errors.isEmpty)
        #expect(parsed == ParsedItemForm(name: "Drill", category: nil, tags: [], quantity: 1, notes: nil))
    }

    @Test("requires a name")
    func requiresName() {
        let (errors, parsed) = ItemForm.validate(values(name: "   "))
        #expect(errors.name == L10n.Forms.itemNameRequired)
        #expect(parsed == nil)
    }

    @Test("rejects quantity", arguments: ["-1", "1.5", "abc", ""])
    func rejectsQuantity(_ quantity: String) {
        let (errors, _) = ItemForm.validate(values(name: "Drill", quantity: quantity))
        #expect(errors.quantity == L10n.Forms.quantityInvalid)
    }

    @Test("accepts quantity 0 so an item can stay filed with none currently there")
    func acceptsZero() {
        let (errors, parsed) = ItemForm.validate(values(name: "Drill", quantity: "0"))
        #expect(errors.isEmpty)
        #expect(parsed?.quantity == 0)
    }

    @Test("splits and trims tags, dropping empties")
    func splitsTags() {
        let (_, parsed) = ItemForm.validate(values(name: "Drill", tags: " power tool ,, dewalt , "))
        #expect(parsed?.tags == ["power tool", "dewalt"])
    }

    @Test("reports every problem at once so nothing is lost between attempts")
    func reportsEveryProblem() {
        let (errors, parsed) = ItemForm.validate(values(name: "", quantity: "-1"))
        #expect(errors.name != nil)
        #expect(errors.quantity != nil)
        #expect(parsed == nil)
    }
}

@Suite("applySuggestion (ItemForm.test.tsx)")
struct EntitiesApplySuggestionTests {
    private let suggestion = RecognitionSuggestion(name: "Cordless drill", category: "Power Tools", tags: ["dewalt", "18v"], confidence: 0.9)

    @Test("fills an untouched form")
    func fillsUntouched() {
        let values = ItemForm.applySuggestion(.empty, suggestion)
        #expect(values.name == "Cordless drill")
        #expect(values.category == "Power Tools")
        #expect(values.tags == "dewalt, 18v")
    }

    @Test("never takes back a field the user typed while it was in flight")
    func neverTakesBack() {
        let typed = ItemFormValues(name: "Angle grinder", category: "Garage", quantity: "3", notes: "top shelf")
        let values = ItemForm.applySuggestion(typed, suggestion)
        #expect(values.name == "Angle grinder")
        #expect(values.category == "Garage")
        #expect(values.quantity == "3")
        #expect(values.notes == "top shelf")
        // Blanks are still worth filling.
        #expect(values.tags == "dewalt, 18v")
    }

    @Test("replaces the supporting fields on an explicit refresh")
    func replacesOnRefresh() {
        let wrong = ItemFormValues(name: "Angle grinder", category: "Kitchenware", tags: "blender, mixing")
        let values = ItemForm.applySuggestion(wrong, suggestion, overwrite: true)
        #expect(values.category == "Power Tools")
        #expect(values.tags == "dewalt, 18v")
    }

    @Test("keeps the corrected name on a refresh, whatever the backend echoes")
    func keepsCorrectedName() {
        let values = ItemForm.applySuggestion(ItemFormValues(name: "Angle grinder"), suggestion, overwrite: true)
        #expect(values.name == "Angle grinder")
    }

    @Test("leaves quantity and notes alone even on a refresh")
    func leavesQuantityAndNotes() {
        let values = ItemForm.applySuggestion(
            ItemFormValues(name: "Angle grinder", quantity: "4", notes: "chipped"), suggestion, overwrite: true)
        #expect(values.quantity == "4")
        #expect(values.notes == "chipped")
    }

    @Test("clears fields a refreshed suggestion has nothing to say about")
    func clearsOnEmptyRefresh() {
        let values = ItemForm.applySuggestion(
            ItemFormValues(name: "Shoebox", category: "Power Tools", tags: "dewalt"),
            RecognitionSuggestion(name: "Shoebox", category: nil, tags: [], confidence: 0.6),
            overwrite: true
        )
        #expect(values.category == "")
        #expect(values.tags == "")
    }
}

/// The item form rules against `Fixtures/entities/entities-vectors.json` (JS trim white space,
/// `Number()` quantity forms, a comma followed by a combining mark, white-space-only names).
@Suite("item form parity (Fixtures/entities)")
struct EntitiesItemFormParityTests {
    struct Values: Decodable {
        let name: String
        let category: String
        let tags: String
        let quantity: String
        let notes: String

        var form: ItemFormValues {
            ItemFormValues(name: name, category: category, tags: tags, quantity: quantity, notes: notes)
        }
    }

    struct Parsed: Decodable, Equatable {
        let name: String
        let category: String?
        let tags: [String]
        let quantity: Int
        let notes: String?
    }

    struct ValidateCase: Decodable {
        let input: Values
        let errors: [String]
        let parsed: Parsed?
    }

    struct Suggestion: Decodable {
        let name: String?
        let category: String?
        let tags: [String]
        let confidence: Double
    }

    struct ApplyCase: Decodable {
        let current: Values
        let suggestion: Suggestion
        let overwrite: Bool
        let expected: Values
    }

    struct Fixture: Decodable {
        let validate: [ValidateCase]
        let applySuggestion: [ApplyCase]
    }

    private func fixture() throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "entities-vectors", withExtension: "json", subdirectory: "Fixtures/entities"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test("validateItemForm matches JS")
    func validateMatches() throws {
        for vector in try fixture().validate {
            let (errors, parsed) = ItemForm.validate(vector.input.form)
            var keys: [String] = []
            if errors.name != nil { keys.append("name") }
            if errors.quantity != nil { keys.append("quantity") }
            #expect(keys == vector.errors, "\(vector.input)")
            let expected = vector.parsed.map {
                ParsedItemForm(name: $0.name, category: $0.category, tags: $0.tags, quantity: $0.quantity, notes: $0.notes)
            }
            #expect(parsed.map(Self.units) == expected.map(Self.units), "\(vector.input)")
        }
    }

    @Test("applySuggestion matches JS")
    func applyMatches() throws {
        for vector in try fixture().applySuggestion {
            let suggestion = RecognitionSuggestion(
                name: vector.suggestion.name, category: vector.suggestion.category, tags: vector.suggestion.tags,
                confidence: vector.suggestion.confidence)
            let applied = ItemForm.applySuggestion(vector.current.form, suggestion, overwrite: vector.overwrite)
            #expect(EntitiesUnits.of(applied) == EntitiesUnits.of(vector.expected.form), "\(vector.current) \(vector.overwrite)")
        }
    }

    /// Compares by code units, as the JSON (and JS) do.
    private static func units(_ parsed: ParsedItemForm) -> [[UInt16]?] {
        [Array(parsed.name.utf16), parsed.category.map { Array($0.utf16) }, Array(parsed.tags.joined(separator: "\u{1}").utf16),
         Array(String(parsed.quantity).utf16), parsed.notes.map { Array($0.utf16) }]
    }
}

/// Code-unit views for comparing strings the way JS does.
enum EntitiesUnits {
    static func of(_ values: ItemFormValues) -> [[UInt16]] {
        [values.name, values.category, values.tags, values.quantity, values.notes].map { Array($0.utf16) }
    }

    static func of(_ string: String?) -> [UInt16]? {
        string.map { Array($0.utf16) }
    }
}
