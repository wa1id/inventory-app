import Testing
@testable import InventoryCore

// JS trim / toLowerCase / toUpperCase parity (01 §6.5, §11), against the
// generated corpus and the cases the specs call out.

@Suite("JS string semantics")
struct JSStringTests {
    @Test("final sigma follows the ICU rule")
    func finalSigma() {
        #expect(sameScalars("ΟΔΟΣ".jsLowercased(), "οδο\u{03C2}"))
        #expect(sameScalars("ΟΔΟΣ sign".jsLowercased(), "οδο\u{03C2} sign"))
        #expect(sameScalars("ΣΑΣ Σ".jsLowercased(), "\u{03C3}α\u{03C2} \u{03C3}"))
        #expect(sameScalars("aΣ.".jsLowercased(), "a\u{03C2}."))
        // A case-ignorable character between is skipped; a cased one after blocks it.
        #expect(sameScalars("Α\u{00AD}Σ".jsLowercased(), "α\u{00AD}\u{03C2}"))
        #expect(sameScalars("ΑΣ.Β".jsLowercased(), "α\u{03C3}.β"))
        // ICU tests case-ignorable first, so ʰ (cased and ignorable) does not count as a preceding letter.
        #expect(sameScalars("ʰΣ".jsLowercased(), "ʰ\u{03C3}"))
    }

    @Test("full case mappings")
    func fullCaseMappings() {
        #expect(sameScalars("İ".jsLowercased(), "i\u{0307}"))
        #expect(sameScalars("ß".jsUppercased(), "SS"))
        #expect(sameScalars("ı".jsUppercased(), "I"))
        #expect(sameScalars("ﬁ".jsLowercased(), "ﬁ"))
    }

    @Test("trim strips the JS white space set only")
    func trimSet() {
        #expect("\u{FEFF}\u{00A0} x \u{2028}\u{3000}".jsTrimmed() == "x")
        #expect(sameScalars("\u{0085}x".jsTrimmed(), "\u{0085}x"))
        #expect(" \n\t ".jsTrimmed() == "")
        #expect("".jsTrimmed() == "")
    }

    @Test("lower, upper and trim match JS over the corpus")
    func corpusParity() throws {
        let entries: [FoldingEntry] = try loadFixture("folding")
        for entry in entries {
            let lower = entry.input.jsLowercased()
            let upper = entry.input.jsUppercased()
            let trim = entry.input.jsTrimmed()
            #expect(sameScalars(lower, entry.lower), "lower \(scalarDump(entry.input)): \(scalarDump(lower))")
            #expect(sameScalars(upper, entry.upper), "upper \(scalarDump(entry.input)): \(scalarDump(upper))")
            #expect(sameScalars(trim, entry.trim), "trim \(scalarDump(entry.input)): \(scalarDump(trim))")
        }
    }
}
