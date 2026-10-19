import Foundation
import Testing
@testable import InventoryCore

// Port of src/core/__tests__/quantity.test.ts, plus the JS Number() vectors of
// 01-data.md §6.4 and Fixtures/quantity.json.

@Suite("clampQuantity")
struct ClampQuantityTests {
    @Test("keeps a whole number in range")
    func keepsAWholeNumberInRange() {
        #expect(clampQuantity(0) == 0)
        #expect(clampQuantity(8) == 8)
        #expect(clampQuantity(maxQuantity) == maxQuantity)
    }

    @Test("rejects fractions and non-numbers by falling back to empty")
    func rejectsFractionsAndNonNumbers() {
        #expect(clampQuantity(1.5) == minQuantity)
        #expect(clampQuantity(Double.nan) == minQuantity)
        #expect(clampQuantity(Double.infinity) == minQuantity)
        #expect(clampQuantity(-Double.infinity) == minQuantity)
    }

    @Test("stops below zero and above the household cap")
    func stopsBelowZeroAndAboveTheCap() {
        #expect(clampQuantity(-1) == minQuantity)
        #expect(clampQuantity(maxQuantity + 1) == maxQuantity)
        #expect(clampQuantity(Int.min) == minQuantity)
        #expect(clampQuantity(Int.max) == maxQuantity)
    }

    @Test("matches JS for the generated numbers")
    func matchesJS() throws {
        struct Entry: Decodable { let input: Double; let value: Int }
        struct File: Decodable { let clamp: [Entry] }
        for entry in try loadFixture("quantity", as: File.self).clamp {
            #expect(clampQuantity(entry.input) == entry.value, "\(entry.input)")
        }
    }
}

@Suite("parseQuantityInput")
struct ParseQuantityInputTests {
    @Test("rejects", arguments: ["", "   ", "abc", "1.5", "-1"])
    func rejects(raw: String) {
        #expect(parseQuantityInput(raw) == nil)
    }

    @Test("accepts zero and trims whole numbers")
    func acceptsZeroAndTrimsWholeNumbers() {
        #expect(parseQuantityInput("0") == 0)
        #expect(parseQuantityInput(" 12 ") == 12)
    }

    // 01 §6.4, verified in Node.
    static let accepted: [(String, Int)] = [
        ("1.0", 1), ("1e2", 100), ("0x1F", 31), ("0b11", 3), ("+5", 5), ("5.", 5), ("00012", 12),
        ("-0", 0), (" 7\n", 7), ("12345", 12345),
    ]

    @Test("accepts the JS Number() integer forms", arguments: accepted)
    func acceptsJSIntegerForms(raw: String, expected: Int) {
        #expect(parseQuantityInput(raw) == expected)
    }

    @Test(
        "rejects what JS Number() rejects or reads as a non-integer",
        arguments: [".5", "1_000", "Infinity", "٣", "1,5", "1e-7", "abc", "1.5", "-1"]
    )
    func rejectsJSNonIntegers(raw: String) {
        #expect(parseQuantityInput(raw) == nil)
    }

    @Test("matches JS for the generated inputs")
    func matchesJS() throws {
        struct Entry: Decodable { let input: String; let value: String? }
        struct File: Decodable { let parse: [Entry] }
        for entry in try loadFixture("quantity", as: File.self).parse {
            // JS returns a float beyond 2^63; natively that is nil (documented deviation).
            let expected = entry.value.flatMap { Double($0) }.flatMap { Int(exactly: $0) }
            #expect(parseQuantityInput(entry.input) == expected, "\(scalarDump(entry.input))")
        }
    }
}

@Suite("stepQuantity")
struct StepQuantityTests {
    @Test("moves by one and stops at the ends")
    func movesByOneAndStopsAtTheEnds() {
        #expect(stepQuantity(3, 1) == 4)
        #expect(stepQuantity(3, -1) == 2)
        #expect(stepQuantity(0, -1) == 0)
        #expect(stepQuantity(maxQuantity, 1) == maxQuantity)
    }

    @Test("does not overflow")
    func doesNotOverflow() {
        #expect(stepQuantity(Int.max, 1) == maxQuantity)
        #expect(stepQuantity(Int.min, -1) == minQuantity)
    }
}
