import Foundation
import InventoryCore

// RN: src/services/ai/contract.ts. Versioned contract with our own recognition
// endpoint (server/); the app never talks to an AI provider directly.

/// RN `RECOGNITION_CONTRACT_VERSION`.
public let recognitionContractVersion = 1

/// Suggestions weaker than this are discarded rather than shown (RN `MIN_CONFIDENCE`); exactly 0.35 passes.
public let minimumRecognitionConfidence = 0.35

/// RN `MAX_TAGS`.
let maximumSuggestionTags = 8
/// RN `MAX_TEXT_LENGTH`, in UTF-16 units as JS `slice` counts.
let maximumSuggestionTextLength = 80

/// Why recognition produced no usable suggestion (RN `RecognitionFailureReason`).
public enum RecognitionFailureReason: String, Sendable, Hashable, CaseIterable {
    case notConfigured = "not_configured"
    case offline
    case timeout
    case rateLimited = "rate_limited"
    case serverError = "server_error"
    case malformedResponse = "malformed_response"
    case unsupportedVersion = "unsupported_version"
    case lowConfidence = "low_confidence"
    case unrecognized
}

/// An editable guess at what the photo shows (RN `RecognitionSuggestion`).
public struct RecognitionSuggestion: Sendable, Hashable {
    /// Never nil in a `.success` result; optional as in the RN type.
    public var name: String?
    public var category: String?
    public var tags: [String]
    /// 0…1.
    public var confidence: Double

    public init(name: String?, category: String?, tags: [String], confidence: Double) {
        self.name = name
        self.category = category
        self.tags = tags
        self.confidence = confidence
    }
}

/// What a recognition request came to (RN `RecognitionResult`). Never an error.
public enum RecognitionResult: Sendable, Hashable {
    case success(RecognitionSuggestion, contractVersion: Int)
    case failed(RecognitionFailureReason)

    /// RN telemetry `outcome`: `success` or the failure reason.
    var outcome: String {
        switch self {
        case .success: "success"
        case .failed(let reason): reason.rawValue
        }
    }
}

/// Validates and normalises an untrusted response body (RN `parseRecognitionResponse`).
///
/// A body that is not JSON reads as `malformed_response`, as `response.json()` throwing does in RN.
public func parseRecognitionResponse(_ body: Data) -> RecognitionResult {
    guard let value = JSONValue.parse(body) else { return .failed(.malformedResponse) }
    return parseRecognitionResponse(value)
}

/// RN `parseRecognitionResponse(body)`, in its order: the checks are not independent.
func parseRecognitionResponse(_ body: JSONValue) -> RecognitionResult {
    guard let payload = body.objectValue else { return .failed(.malformedResponse) }

    // typeof === 'number': a boolean or numeric string is malformed; 1.0 is 1.
    guard let version = payload["contractVersion"]?.numberValue else { return .failed(.malformedResponse) }
    guard version == Double(recognitionContractVersion) else { return .failed(.unsupportedVersion) }

    // The backend reports an image it could not interpret as an outcome, not an error status.
    if payload["status"] == .string("unrecognized") { return .failed(.unrecognized) }

    guard let raw = payload["suggestion"]?.objectValue else { return .failed(.malformedResponse) }

    // Confidence is checked before the name.
    guard let confidence = cleanNumber(raw["confidence"]), confidence <= 1 else {
        return .failed(.malformedResponse)
    }
    guard let name = cleanText(raw["name"]) else { return .failed(.unrecognized) }
    if confidence < minimumRecognitionConfidence { return .failed(.lowConfidence) }

    let tags: [String] = if case .array(let values)? = raw["tags"] {
        Array(values.compactMap(cleanText).prefix(maximumSuggestionTags))
    } else {
        []
    }

    return .success(
        RecognitionSuggestion(name: name, category: cleanText(raw["category"]), tags: tags, confidence: confidence),
        contractVersion: recognitionContractVersion
    )
}

/// RN `cleanText`: strings only, JS-trimmed, cut to 80 UTF-16 units (not re-trimmed); empty → nil.
private func cleanText(_ value: JSONValue?) -> String? {
    guard let string = value?.stringValue else { return nil }
    var units = Array(string.jsTrimmed().utf16.prefix(maximumSuggestionTextLength))
    // JS keeps a lone high surrogate when the cut splits a pair; a Swift String cannot hold one.
    if let last = units.last, UTF16.isLeadSurrogate(last) { units.removeLast() }
    return units.isEmpty ? nil : String(decoding: units, as: UTF16.self)
}

/// RN `cleanNumber`: a finite, non-negative JS number, else nil.
private func cleanNumber(_ value: JSONValue?) -> Double? {
    guard let number = value?.numberValue, number.isFinite, !(number < 0) else { return nil }
    return number
}
