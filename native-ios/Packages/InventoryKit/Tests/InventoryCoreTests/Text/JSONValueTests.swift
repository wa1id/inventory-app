import Foundation
import Testing
@testable import InventoryCore

/// `JSONValue`: JSON.parse, JSON.stringify and the JS coercions. Most behaviour is pinned by
/// the TS vectors in the storage and network suites (preference readers, householdRequest,
/// parseRecognitionResponse, String()/Number()); these cover the corners they do not reach.
@Suite("JSONValue")
struct JSONValueTests {
    @Test("JSON.parse keeps the last duplicate key and rejects what JS rejects")
    func parse() {
        #expect(JSONValue.parse(#"{"a":1,"a":2}"#) == .object(["a": .number(2)]))
        #expect(JSONValue.parse(#" [true,false,null,"x",-0.5e1] "#)
            == .array([.bool(true), .bool(false), .null, .string("x"), .number(-5)]))
        for text in ["", " ", "\u{FEFF}1", "01", "1.", ".1", "+1", "[1,]", "{\"a\"}", "'a'", "nul", "\"a", "\"\u{0}\"", "NaN", "Infinity", "\u{A0}1"] {
            #expect(JSONValue.parse(text) == nil, "\(text.debugDescription)")
        }
        #expect(JSONValue.parse("1e400") == .number(.infinity))
        #expect(JSONValue.parse("-1e-400") == .number(-0.0))
        #expect(JSONValue.parse("\t\n\r 7 ") == .number(7))
    }

    @Test("JSON.parse rounds long numbers to the nearest Double, as JS does")
    func longNumbers() {
        // Integers past Int64 used to arrive from JSONSerialization as NSDecimalNumber.
        #expect(JSONValue.parse("12345678901234567890123") == .number(1.2345678901234568e22))
        #expect(JSONValue.parse("9007199254740993") == .number(9_007_199_254_740_992))
        #expect(JSONValue.parse("0.1000000000000000055511151231257827") == .number(0.1))
    }

    @Test("escaped lone surrogates read as U+FFFD; pairs and escaped backslashes are untouched", arguments: [
        (#""\ud83d""#, "\u{FFFD}"), (#""\udc00""#, "\u{FFFD}"), (#""a\ud83dA""#, "a\u{FFFD}A"),
        (#""\ud83d🔧""#, "\u{FFFD}\u{1F527}"), (#""🔧""#, "\u{1F527}"), (#""\\ud83d""#, #"\ud83d"#),
    ])
    func loneSurrogates(json: String, expected: String) {
        #expect(JSONValue.parse(json) == .string(expected), "\(json)")
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

    @Test("a body is decoded as UTF-8, a leading BOM dropped; invalid UTF-8 is refused")
    func data() {
        #expect(JSONValue.parse(Data(#"{"a":"é"}"#.utf8)) == .object(["a": .string("é")]))
        #expect(JSONValue.parse(Data([0xEF, 0xBB, 0xBF]) + Data("[1]".utf8)) == .array([.number(1)]))
        #expect(JSONValue.parse(Data([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF]) + Data("[1]".utf8)) == nil)
        #expect(JSONValue.parse(Data([0x22, 0xC3, 0x22])) == nil)
        #expect(JSONValue.parse(Data()) == nil)
    }

    @Test("JSON.stringify quoting")
    func quote() {
        #expect(JSONValue.quote("a/b\"c\\d\u{8}\u{C}\n\r\t\u{1F}\u{7F}\u{2028}é📦")
            == "\"a/b\\\"c\\\\d\\b\\f\\n\\r\\t\\u001f\u{7F}\u{2028}é📦\"")
        #expect(JSONValue.array([]).jsonText == "[]")
        #expect(JSONValue.array([.string("a"), .string("b")]).jsonText == #"["a","b"]"#)
    }

    @Test("JSON.stringify of values: compact, JS number text, non-finite as null, keys sorted")
    func stringify() {
        let value = JSONValue.object([
            "b": .array([.number(1), .bool(true), .null, .string("x")]),
            "a": .number(-0.5),
            "B": .object([:]),
            "é": .number(1e21),
            "z": .number(0.000001),
            "y": .number(1.5e-7),
            "x": .number(.infinity),
            "w": .number(-0.0),
        ])
        #expect(value.jsonText == #"{"B":{},"a":-0.5,"b":[1,true,null,"x"],"w":0,"x":null,"y":1.5e-7,"z":0.000001,"é":1e+21}"#)
        #expect(JSONValue.null.jsonText == "null")
        #expect(JSONValue.bool(false).jsonText == "false")
        #expect(JSONValue.number(1_700_000_000_000).jsonText == "1700000000000")
        #expect(JSONValue.string("\u{FFFD}").jsonText == "\"\u{FFFD}\"")
    }

    @Test("what stringify writes parses back to the same value", arguments: [
        #"{"id":"s1","name":"Garage 🧰","count":3,"nested":{"list":[0.1,-2,1e-7,true,null]},"tag":"a\"b\\c\n"}"#,
        #"[[],{},"",0,-0.25,123456789012]"#,
        #""\u0000\u001f""#,
    ])
    func roundTrip(text: String) throws {
        let value = try #require(JSONValue.parse(text))
        #expect(JSONValue.parse(value.jsonText) == value)
        // JSONDecoder reads it too, which is what the household client relies on.
        _ = try JSONSerialization.jsonObject(with: Data(value.jsonText.utf8), options: [.fragmentsAllowed])
    }

    @Test("typeof accessors")
    func accessors() {
        let object = JSONValue.object(["a": .number(1)])
        #expect(object.objectValue == ["a": .number(1)])
        #expect(object.arrayValue == nil)
        #expect(JSONValue.array([.null]).arrayValue == [.null])
        #expect(JSONValue.array([]).objectValue == nil)
        #expect(JSONValue.string("1").stringValue == "1")
        #expect(JSONValue.string("1").numberValue == nil)
        #expect(JSONValue.number(1).numberValue == 1)
        #expect(JSONValue.bool(true).numberValue == nil)
        #expect(JSONValue.bool(true).boolValue == true)
        #expect(JSONValue.null.boolValue == nil)
    }

    @Test("String() and Number()", arguments: [
        (JSONValue.string(" 12 "), " 12 ", 12.0 as Double?),
        (.number(1e21), "1e+21", 1e21),
        (.bool(true), "true", 1),
        (.null, "null", 0),
        (.array([]), "", 0),
        (.array([.number(5)]), "5", 5),
        (.array([.number(1), .null, .string("x")]), "1,,x", nil),
        (.object([:]), "[object Object]", nil),
        (.string("0x1F"), "0x1F", 31),
        (.string("abc"), "abc", nil),
    ])
    func coercions(value: JSONValue, string: String, number: Double?) {
        #expect(value.jsString == string)
        #expect(value.jsNumber == number)
    }
}
