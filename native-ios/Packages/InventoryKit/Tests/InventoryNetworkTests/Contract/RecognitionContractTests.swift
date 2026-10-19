import Foundation
import Testing
@testable import InventoryNetwork

// RecognitionClient against answers recorded from server/api/recognize.ts with a
// scripted adapter (Fixtures/generator/recognition-contract.ts). The fixture also
// records what the server handed the adapter, which proves the real media type
// the client now sends (U6) reaches the provider call.

private func recognize(
    _ name: String,
    key: String?? = nil,
    hint: String? = nil,
    checkRequest: Bool = true,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> RecognitionResult {
    let contract = try RecognitionContract.load()
    let recorded = try contract.exchange(name)
    let server = StubServer(reply: recorded.reply)
    let image = try #require(Data(base64Encoded: contract.image))
    let client = RecognitionClient(
        endpoint: contract.endpoint,
        key: key ?? contract.appKey,
        transport: server.transport,
        readImage: { _ in image },
        telemetry: TelemetryRecorder().telemetry
    )
    let result = await client.recognize(imageAt: URL(fileURLWithPath: "/photo.webp"), nameHint: hint)
    if checkRequest {
        let sent = try #require(server.lastRequest, sourceLocation: sourceLocation)
        #expect(sent.method == "POST", sourceLocation: sourceLocation)
        #expect(sent.url == contract.endpoint, sourceLocation: sourceLocation)
        for (header, value) in recorded.request.headers {
            #expect(sent.header(header) == value, "header \(header)", sourceLocation: sourceLocation)
        }
        if key == .some(nil) {
            #expect(sent.header("x-inventory-key") == nil, sourceLocation: sourceLocation)
        }
        let json = try #require(recorded.request.json, sourceLocation: sourceLocation)
        #expect(sent.json == WireJSON.parse(Data(json.utf8)), "JSON body", sourceLocation: sourceLocation)
    }
    return result
}

@Suite("Recognition contract")
struct RecognitionContractTests {
    @Test("the server answers the native request with a suggestion, and saw the real media type")
    func success() async throws {
        let result = try await recognize("success")
        #expect(result == .success(
            RecognitionSuggestion(name: "Cordless Drill", category: "Power Tools", tags: ["dewalt", "18v"], confidence: 0.92),
            contractVersion: 1
        ))
        let contract = try RecognitionContract.load()
        let saw = try #require(try contract.exchange("success").adapterSaw)
        let image = try #require(Data(base64Encoded: contract.image))
        #expect(saw.mediaType == ImageMediaType.sniff(image))
        #expect(saw.mediaType == "image/webp")
        #expect(saw.byteLength == image.count)
        #expect(saw.nameHint == nil)
    }

    @Test("a hint is sent trimmed; the server collapses its spacing and names the item after it")
    func successHinted() async throws {
        let result = try await recognize("successHinted", hint: "  Angle   grinder ")
        guard case .success(let suggestion, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(suggestion.name == "Angle grinder")
        let saw = try #require(try RecognitionContract.load().exchange("successHinted").adapterSaw)
        #expect(saw.nameHint == "Angle grinder")
    }

    @Test("an image the model could not identify is unrecognized")
    func unrecognized() async throws {
        #expect(try await recognize("unrecognized") == .failed(.unrecognized))
    }

    @Test("429 is rate limited; the provider's timeout (504) and failures (502) are server errors")
    func providerFailures() async throws {
        #expect(try await recognize("rateLimited") == .failed(.rateLimited))
        #expect(try await recognize("providerTimeout") == .failed(.serverError))
        #expect(try await recognize("upstream") == .failed(.serverError))
    }

    @Test("a missing or wrong app key is refused with 401, a server error to the client")
    func credentials() async throws {
        #expect(try await recognize("missingKey", key: .some(nil)) == .failed(.serverError))
        #expect(try await recognize("wrongKey", key: "nope") == .failed(.serverError))
    }

    @Test("the server's request refusals all read as server errors")
    func refusals() async throws {
        for name in ["notJSON", "wrongVersion", "emptyImage", "tooLarge"] {
            #expect(try await recognize(name, checkRequest: false) == .failed(.serverError), "\(name)")
        }
    }

    @Test("every media type the client can sniff is accepted as sent")
    func mediaTypes() throws {
        let contract = try RecognitionContract.load()
        #expect(contract.mediaTypes.map(\.sent) == ["image/webp", "image/jpeg", "image/png", "image/gif"])
        for entry in contract.mediaTypes {
            #expect(entry.accepted == entry.sent)
        }
    }
}
