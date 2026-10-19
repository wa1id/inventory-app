import Testing
@testable import InventoryCore

/// `Number(string)` and `String.prototype.trim()`.
///
/// InventoryStorage used to carry its own `JS.trim` and `JSNumber.parse`; these tests are the
/// proof that Core's `jsTrimmed()` and `jsNumber(_:)` mean the same thing, so the storage
/// readers could switch: the corner cases its suite pinned, the exact white-space set its trim
/// stripped, and the long radix literals its rounding got right (values from Node 24).
@Suite("Number() and trim()")
struct JSNumberTests {
    /// What InventoryStorage's `JS.isWhitespace` accepted, restated as the oracle.
    private static let storageWhitespace: Set<UInt32> = Set([0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680])
        .union(0x2000...0x200A)
        .union([0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF])

    @Test("trim strips ECMAScript white space, including U+FEFF but not U+0085")
    func trim() {
        #expect("\u{FEFF}\u{A0}\t a b \u{2028}\u{3000}".jsTrimmed() == "a b")
        #expect("\u{85}x\u{85}".jsTrimmed() == "\u{85}x\u{85}")
        #expect(" \n ".jsTrimmed() == "")
    }

    @Test("trim strips exactly the code points the storage readers' trim stripped")
    func trimSetIsTheStorageSet() {
        for value in UInt32(0)...0xFFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let text = String(scalar) + "x" + String(scalar)
            let stripped = Self.storageWhitespace.contains(value)
            #expect(text.jsTrimmed() == (stripped ? "x" : text), "U+\(String(value, radix: 16))")
        }
    }

    @Test("Number() corners", arguments: [
        ("0e99999999999999999999", 0.0),
        ("1e99999999999999999999", Double.infinity),
        ("-1e-99999999999999999999", -0.0),
        ("0x1F", 31),
        ("  12  ", 12),
        ("", 0),
        (" \n", 0),
        ("-Infinity", -Double.infinity),
        ("+.5", 0.5),
        ("5.", 5),
        ("1e400", Double.infinity),
        ("-0", -0.0),
    ] as [(String, Double)])
    func number(text: String, expected: Double) {
        let value = jsNumber(text.jsTrimmed())
        #expect(value == expected)
        #expect(value?.sign == expected.sign)
    }

    @Test("Number() is NaN for these", arguments: ["-0x1", "0x", "1e", "e1", ".", "1..2", "Infinityx", "١", "infinity", "0x1G", "1_000", "+-1", "0b2"])
    func notANumber(text: String) {
        #expect(jsNumber(text.jsTrimmed()) == nil)
    }

    @Test("0x, 0o and 0b literals of any length round to the nearest Double, ties to even", arguments: [
        ("0x1fffffffffffff1", 144_115_188_075_855_856),
        ("0x20000000000000100000000001", 2.535301200456459e+30),
        ("0xffffffffffffffffff", 4.722366482869645e+21),
        ("0b" + String(repeating: "1", count: 70), 1.1805916207174113e+21),
        ("0o7777777777777777777777777", 3.777893186295716e+22),
        ("0x10000000000000800", 18_446_744_073_709_551_616),
        ("0x10000000000000801", 18_446_744_073_709_555_712),
        ("0x10000000000001800", 18_446_744_073_709_559_808),
        ("0X7FFFFFFFFFFFFFFF", 9_223_372_036_854_775_808),
    ] as [(String, Double)])
    func longRadixLiterals(text: String, expected: Double) {
        #expect(jsNumber(text) == expected)
    }

    @Test("Number#toString", arguments: [
        (0.0, "0"), (-0.0, "0"), (1, "1"), (-1.5, "-1.5"), (1e21, "1e+21"), (1e20, "100000000000000000000"),
        (123_456_789_012_345_683_968, "123456789012345680000"), (0.000001, "0.000001"), (1e-7, "1e-7"),
        (1.5e-7, "1.5e-7"), (Double.infinity, "Infinity"), (-Double.infinity, "-Infinity"), (Double.nan, "NaN"),
        (0.1 + 0.2, "0.30000000000000004"), (5e-324, "5e-324"), (1.7976931348623157e308, "1.7976931348623157e+308"),
    ] as [(Double, String)])
    func numberString(value: Double, expected: String) {
        #expect(jsNumberString(value) == expected)
    }
}
