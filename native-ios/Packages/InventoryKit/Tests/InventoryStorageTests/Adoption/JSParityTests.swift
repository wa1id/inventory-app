import Foundation
import Testing
@testable import InventoryStorage

/// The JavaScript built-ins the preference readers rely on. Most behaviour is pinned by the TS
/// vectors in the store tests; these cover the corners the vectors do not reach.
@Suite("JS parity helpers")
struct JSParityTests {
    @Test("trim strips ECMAScript white space, including U+FEFF but not U+0085")
    func trim() {
        #expect(JS.trim("\u{FEFF}\u{A0}\t a b \u{2028}\u{3000}") == "a b")
        #expect(JS.trim("\u{85}x\u{85}") == "\u{85}x\u{85}")
        #expect(JS.trim(" \n ") == "")
    }

    @Test("toLowerCase applies the Greek final sigma like Hermes")
    func lowercase() {
        #expect(JS.lowercase("ΟΔΟΣ") == "οδος")
        #expect(JS.lowercase("İ") == "i\u{307}")
    }

    @Test("JSON.parse keeps the last duplicate key and rejects what JS rejects")
    func parse() {
        #expect(JSONValue.parse(#"{"a":1,"a":2}"#) == .object(["a": .number(2)]))
        #expect(JSONValue.parse(#" [true,false,null,"x",-0.5e1] "#)
            == .array([.bool(true), .bool(false), .null, .string("x"), .number(-5)]))
        for text in ["", " ", "\u{FEFF}1", "01", "1.", ".1", "+1", "[1,]", "{\"a\"}", "'a'", "nul", "\"a", "\"\u{0}\""] {
            #expect(JSONValue.parse(text) == nil, "\(text.debugDescription)")
        }
        #expect(JSONValue.parse("1e400") == .number(.infinity))
        #expect(JSONValue.parse("-1e-400") == .number(-0.0))
    }

    @Test("JSON.parse refuses absurd nesting instead of overflowing the stack")
    func nesting() {
        func nested(_ depth: Int) -> String {
            String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        }
        #expect(JSONValue.parse(nested(256)) != nil)
        #expect(JSONValue.parse(nested(257)) == nil)
        #expect(JSONValue.parse(String(repeating: "{\"a\":", count: 300) + "1" + String(repeating: "}", count: 300)) == nil)
        #expect(JSONValue.parse(String(repeating: "[", count: 200_000)) == nil)
        // Depth is nesting, not the number of containers.
        #expect(JSONValue.parse("[" + Array(repeating: "[]", count: 1_000).joined(separator: ",") + "]") != nil)
    }

    @Test("JSON.stringify quoting")
    func quote() {
        #expect(JSONText.quote("a/b\"c\\d\u{8}\u{C}\n\r\t\u{1F}\u{7F}\u{2028}é📦")
            == "\"a/b\\\"c\\\\d\\b\\f\\n\\r\\t\\u001f\u{7F}\u{2028}é📦\"")
        #expect(JSONText.array([]) == "[]")
        #expect(JSONText.array(["a", "b"]) == #"["a","b"]"#)
    }

    @Test("Number() corners", arguments: [
        ("0e99999999999999999999", 0.0),
        ("1e99999999999999999999", Double.infinity),
        ("-1e-99999999999999999999", -0.0),
        ("0x1F", 31),
        ("  12  ", 12),
    ] as [(String, Double)])
    func number(text: String, expected: Double) {
        #expect(JSNumber.parse(text) == expected)
    }

    @Test("Number() is NaN for these", arguments: ["-0x1", "0x", "1e", "e1", ".", "1..2", "Infinityx", "١"])
    func notANumber(text: String) {
        #expect(JSNumber.parse(text) == nil)
    }
}
