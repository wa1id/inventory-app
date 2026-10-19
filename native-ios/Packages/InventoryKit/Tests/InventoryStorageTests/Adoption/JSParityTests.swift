import Foundation
import Testing
@testable import InventoryStorage

/// The JavaScript built-ins the preference readers rely on that stay in this module. Most
/// behaviour is pinned by the TS vectors in the store tests; JSON.parse, JSON.stringify, trim
/// and Number() are InventoryCore's and tested there (JSONValueTests, JSNumberTests).
@Suite("JS parity helpers")
struct JSParityTests {
    @Test("toLowerCase applies the Greek final sigma like Hermes")
    func lowercase() {
        #expect(JS.lowercase("ΟΔΟΣ") == "οδος")
        #expect(JS.lowercase("İ") == "i\u{307}")
    }

    @Test("keys compare by UTF-16 code units, without canonical equivalence")
    func keys() {
        #expect(JS.Key("é") != JS.Key("e\u{301}"))
        #expect(JS.Key("Garage").hasPrefix(JS.Key("Gar")))
        #expect(JS.Key("").isEmpty)
    }
}
