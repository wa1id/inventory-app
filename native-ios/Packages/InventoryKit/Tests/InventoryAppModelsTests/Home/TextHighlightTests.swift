import Foundation
import Testing
@testable import InventoryAppModels

/// `Fixtures/shell/home-vectors.json`, generated from the real `splitHighlight` and `nameTotals`
/// by `Fixtures/shell/generator/shell-vectors.test.tsx`.
private struct ShellHomeVectors: Decodable {
    struct Highlight: Decodable {
        let text: String
        let terms: [String]
        let parts: [String]
    }

    struct Totals: Decodable {
        struct Input: Decodable {
            let name: String
            let quantity: Int
            let containerId: String
        }

        struct Total: Decodable, Equatable {
            let name: String
            let quantity: Int
            let places: Int
        }

        let items: [Input]
        let totals: [Total]
    }

    let highlight: [Highlight]
    let totals: [Totals]

    static func load() throws -> ShellHomeVectors {
        let url = try #require(Bundle.module.url(forResource: "home-vectors", withExtension: "json", subdirectory: "Fixtures/shell"))
        return try JSONDecoder().decode(ShellHomeVectors.self, from: Data(contentsOf: url))
    }
}

/// Port of src/ui/components/__tests__/textHelpers.test.tsx › splitHighlight, plus the vectors.
@Suite("splitHighlight (src/ui/components/AppText.tsx)")
struct TextHighlightTests {
    @Test("puts matches at odd indexes, case-insensitively")
    func matchesAtOddIndexes() {
        #expect(TextHighlight.split("Spare batteries AA", terms: ["batt", "aa"]) == ["Spare ", "batt", "eries ", "AA", ""])
    }

    @Test("ignores one-letter terms and escapes regex characters")
    func oneLetterAndEscaping() {
        #expect(TextHighlight.split("USB-C (2m)", terms: ["c", "(2m)"]) == ["USB-C ", "(2m)", ""])
        #expect(TextHighlight.split("Drill", terms: []) == ["Drill"])
    }

    @Test("matches the real splitHighlight on every vector")
    func vectors() throws {
        for vector in try ShellHomeVectors.load().highlight {
            // Compare code units: the parts must be JS's strings exactly, not canonically equal ones.
            let parts = TextHighlight.split(vector.text, terms: vector.terms)
            #expect(parts.map { Array($0.utf16) } == vector.parts.map { Array($0.utf16) }, "\(vector.text) / \(vector.terms)")
        }
    }

    @Test("folds case as a non-Unicode JS regex: single-unit upper case, never non-ASCII to ASCII")
    func canonicalize() {
        #expect(TextHighlight.canonicalize(UInt16(UInt8(ascii: "a"))) == UInt16(UInt8(ascii: "A")))
        #expect(TextHighlight.canonicalize(0x00DF) == 0x00DF)  // ß → SS is two units: unchanged
        #expect(TextHighlight.canonicalize(0x017F) == 0x017F)  // ſ → S would be ASCII: unchanged
        #expect(TextHighlight.canonicalize(0x00B5) == 0x039C)  // µ → Greek capital mu
        #expect(TextHighlight.canonicalize(0xD83E) == 0xD83E)  // a lone surrogate
    }
}

@Suite("nameTotals vectors (src/ui/home/homeList.ts)")
struct HomeListNameTotalsVectorTests {
    @Test("matches the real nameTotals on every vector")
    func vectors() throws {
        for vector in try ShellHomeVectors.load().totals {
            let totals = HomeList.nameTotals(vector.items.map {
                HomeList.NameTotalInput(name: $0.name, quantity: $0.quantity, containerId: $0.containerId)
            })
            let expected = vector.totals.map { HomeList.NameTotal(name: $0.name, quantity: $0.quantity, places: $0.places) }
            #expect(totals.map { Array($0.name.utf16) } == expected.map { Array($0.name.utf16) })
            #expect(totals == expected, "\(vector.items.map(\.name))")
        }
    }
}
