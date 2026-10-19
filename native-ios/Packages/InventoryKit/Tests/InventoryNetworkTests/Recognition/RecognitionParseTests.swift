import Foundation
import Testing
@testable import InventoryNetwork

// RN: src/services/ai/__tests__/recognition.test.ts › parseRecognitionResponse

private let validSuggestion = #"{"name":"Cordless Drill","category":"Power Tools","tags":["dewalt","18v"],"confidence":0.92}"#
private let validBody = #"{"contractVersion":1,"suggestion":\#(validSuggestion)}"#

private func parse(_ json: String) -> RecognitionResult {
    parseRecognitionResponse(Data(json.utf8))
}

private func suggestionOf(_ result: RecognitionResult) -> RecognitionSuggestion? {
    if case .success(let suggestion, _) = result { return suggestion }
    return nil
}

@Suite("parseRecognitionResponse")
struct RecognitionParseTests {
    @Test("accepts and normalizes a well-formed suggestion")
    func acceptsAndNormalizesAWellFormedSuggestion() throws {
        let result = parse(validBody)
        let suggestion = try #require(suggestionOf(result))
        #expect(suggestion.name == "Cordless Drill")
        #expect(suggestion.tags == ["dewalt", "18v"])
        #expect(result == .success(
            RecognitionSuggestion(name: "Cordless Drill", category: "Power Tools", tags: ["dewalt", "18v"], confidence: 0.92),
            contractVersion: 1
        ))
    }

    @Test("rejects %s as malformed", arguments: [
        ("null body", "null"),
        ("a string body", #""nope""#),
        ("a missing contract version", #"{"suggestion":\#(validSuggestion)}"#),
        ("a missing suggestion", #"{"contractVersion":1}"#),
        ("a non-numeric confidence", #"{"contractVersion":1,"suggestion":{"name":"Cordless Drill","category":"Power Tools","tags":["dewalt","18v"],"confidence":"high"}}"#),
        ("a confidence above 1", #"{"contractVersion":1,"suggestion":{"name":"Cordless Drill","category":"Power Tools","tags":["dewalt","18v"],"confidence":4}}"#),
    ])
    func rejectsAsMalformed(label: String, body: String) {
        #expect(parse(body) == .failed(.malformedResponse), "\(label)")
    }

    @Test("rejects a contract version it does not understand")
    func rejectsAContractVersionItDoesNotUnderstand() {
        #expect(parse(#"{"contractVersion":999,"suggestion":\#(validSuggestion)}"#) == .failed(.unsupportedVersion))
    }

    @Test("treats an explicit unrecognized outcome as recoverable")
    func treatsAnExplicitUnrecognizedOutcomeAsRecoverable() {
        #expect(parse(#"{"contractVersion":1,"status":"unrecognized"}"#) == .failed(.unrecognized))
    }

    @Test("rejects a suggestion with no usable name")
    func rejectsASuggestionWithNoUsableName() {
        let body = #"{"contractVersion":1,"suggestion":{"name":"   ","category":"Power Tools","tags":["dewalt","18v"],"confidence":0.92}}"#
        #expect(parse(body) == .failed(.unrecognized))
    }

    @Test("discards suggestions below the confidence floor")
    func discardsSuggestionsBelowTheConfidenceFloor() {
        let floor = minimumRecognitionConfidence - 0.01
        let body = #"{"contractVersion":1,"suggestion":{"name":"Cordless Drill","category":"Power Tools","tags":[],"confidence":\#(floor)}}"#
        #expect(parse(body) == .failed(.lowConfidence))
    }

    @Test("drops junk values instead of passing them to the editor")
    func dropsJunkValuesInsteadOfPassingThemToTheEditor() throws {
        let body = #"{"contractVersion":1,"suggestion":{"name":"Drill","category":42,"tags":["ok",17,null,"  ","fine"],"confidence":0.8}}"#
        let suggestion = try #require(suggestionOf(parse(body)))
        #expect(suggestion.category == nil)
        #expect(suggestion.tags == ["ok", "fine"])
    }

    @Test("caps the number of tags")
    func capsTheNumberOfTags() throws {
        let tags = (0..<40).map { "\"tag\($0)\"" }.joined(separator: ",")
        let body = #"{"contractVersion":1,"suggestion":{"name":"Cordless Drill","tags":[\#(tags)],"confidence":0.92}}"#
        let suggestion = try #require(suggestionOf(parse(body)))
        #expect(suggestion.tags.count == 8)
        #expect(suggestion.tags == (0..<8).map { "tag\($0)" })
    }

    // MARK: Native additions (05 §10.4, §19)

    @Test("rejects a boolean contract version or confidence, as JS typeof does")
    func rejectsBooleansWhereJSWantsNumbers() {
        #expect(parse(#"{"contractVersion":true,"suggestion":\#(validSuggestion)}"#) == .failed(.malformedResponse))
        let body = #"{"contractVersion":1,"suggestion":{"name":"Drill","tags":[],"confidence":true}}"#
        #expect(parse(body) == .failed(.malformedResponse))
    }

    @Test("accepts contractVersion 1.0, which is the number 1")
    func acceptsContractVersionOnePointZero() {
        #expect(suggestionOf(parse(#"{"contractVersion":1.0,"suggestion":\#(validSuggestion)}"#)) != nil)
    }

    @Test("rejects a numeric-string contract version as malformed, not unsupported")
    func rejectsStringContractVersion() {
        #expect(parse(#"{"contractVersion":"1","suggestion":\#(validSuggestion)}"#) == .failed(.malformedResponse))
    }

    @Test("lets exactly the confidence floor through")
    func letsTheFloorThrough() {
        let body = #"{"contractVersion":1,"suggestion":{"name":"Drill","tags":[],"confidence":0.35}}"#
        #expect(suggestionOf(parse(body))?.confidence == 0.35)
    }

    @Test("checks confidence before the name")
    func checksConfidenceBeforeTheName() {
        let body = #"{"contractVersion":1,"suggestion":{"name":"   ","tags":[],"confidence":-0.5}}"#
        #expect(parse(body) == .failed(.malformedResponse))
    }

    @Test("a missing name with a weak confidence is unrecognized, not low confidence")
    func missingNameBeatsLowConfidence() {
        let body = #"{"contractVersion":1,"suggestion":{"tags":[],"confidence":0.1}}"#
        #expect(parse(body) == .failed(.unrecognized))
    }

    @Test("rejects an array body and an array suggestion")
    func rejectsArrays() {
        #expect(parse("[]") == .failed(.malformedResponse))
        #expect(parse(#"{"contractVersion":1,"suggestion":[]}"#) == .failed(.malformedResponse))
    }

    @Test("a body that is not JSON is malformed")
    func notJSONIsMalformed() {
        #expect(parse("<html>502</html>") == .failed(.malformedResponse))
        #expect(parse("") == .failed(.malformedResponse))
    }

    @Test("trims with JS rules, keeps inner spacing, and does not re-trim after the cut")
    func trimsLikeJS() throws {
        // U+FEFF is JS white space; U+0085 is not.
        let body = #"{"contractVersion":1,"suggestion":{"name":"﻿  Angle  grinder \u0085","category":"  Tools  ","tags":["  a  "],"confidence":0.9}}"#
        let suggestion = try #require(suggestionOf(parse(body)))
        #expect(suggestion.name == "Angle  grinder \u{85}")
        #expect(suggestion.category == "Tools")
        #expect(suggestion.tags == ["a"])

        let cut = String(repeating: "a", count: 79) + " b"
        let cutBody = #"{"contractVersion":1,"suggestion":{"name":"\#(cut)","tags":[],"confidence":0.9}}"#
        let cutName = try #require(suggestionOf(parse(cutBody))?.name)
        #expect(cutName == String(repeating: "a", count: 79) + " ")
    }

    @Test("cuts at 80 UTF-16 units and drops a split surrogate pair")
    func cutsAtEightyUTF16Units() throws {
        let emoji = "\u{1F527}"  // two UTF-16 units
        let name = String(repeating: "x", count: 79) + emoji
        let body = #"{"contractVersion":1,"suggestion":{"name":"\#(name)","tags":[],"confidence":0.9}}"#
        let parsed = try #require(suggestionOf(parse(body))?.name)
        #expect(parsed == String(repeating: "x", count: 79))

        let fits = String(repeating: "x", count: 78) + emoji
        let fitsBody = #"{"contractVersion":1,"suggestion":{"name":"\#(fits)","tags":[],"confidence":0.9}}"#
        #expect(suggestionOf(parse(fitsBody))?.name == fits)
    }

    @Test("ignores tags that are not an array")
    func ignoresNonArrayTags() throws {
        let body = #"{"contractVersion":1,"suggestion":{"name":"Drill","tags":"a,b","confidence":0.9}}"#
        #expect(try #require(suggestionOf(parse(body))).tags.isEmpty)
    }
}
