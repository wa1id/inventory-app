import Foundation
import InventoryCore
import Testing
@testable import InventoryNetwork

// RN: src/services/ai/__tests__/recognition.test.ts › recognizeItem, through a real
// URLSession whose requests a URLProtocol stub answers.

private let endpoint = "https://recognition.example.com/v1/identify"
private let validBody = #"{"contractVersion":1,"suggestion":{"name":"Cordless Drill","category":"Power Tools","tags":["dewalt","18v"],"confidence":0.92}}"#
/// "fake-image" with a WebP header, as the stored photos are.
private let webpBytes = Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 fake-image".utf8)
private let photoURL = URL(fileURLWithPath: "/photo.webp")

private func client(
    _ server: StubServer,
    endpoint: String? = endpoint,
    key: String? = nil,
    timeout: Duration = .seconds(5),
    image: Data = webpBytes,
    telemetry: TelemetryRecorder = TelemetryRecorder()
) -> RecognitionClient {
    RecognitionClient(
        endpoint: endpoint,
        key: key,
        timeout: timeout,
        transport: server.transport,
        readImage: { _ in image },
        telemetry: telemetry.telemetry
    )
}

@Suite("recognizeItem")
struct RecognitionClientTests {
    @Test("returns a suggestion on success")
    func returnsASuggestionOnSuccess() async {
        let server = StubServer(reply: .json(200, validBody))
        let result = await client(server).recognize(imageAt: photoURL)
        #expect(result == .success(
            RecognitionSuggestion(name: "Cordless Drill", category: "Power Tools", tags: ["dewalt", "18v"], confidence: 0.92),
            contractVersion: 1
        ))
    }

    @Test("never sends a provider credential from the client")
    func neverSendsAProviderCredentialFromTheClient() async throws {
        let server = StubServer(reply: .json(200, validBody))
        _ = await client(server, key: "app-key").recognize(imageAt: photoURL)
        let request = try #require(server.lastRequest)
        #expect(request.header("authorization") == nil)
        #expect(request.header("x-api-key") == nil)
    }

    @Test("classifies a timeout as recoverable")
    func classifiesATimeoutAsRecoverable() async {
        let server = StubServer(reply: .json(200, validBody, delay: .seconds(10)))
        let started = ContinuousClock.now
        let result = await client(server, timeout: .milliseconds(100)).recognize(imageAt: photoURL)
        #expect(result == .failed(.timeout))
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("classifies a network failure as offline")
    func classifiesANetworkFailureAsOffline() async {
        let server = StubServer(reply: .failure(.notConnectedToInternet, delay: nil))
        #expect(await client(server).recognize(imageAt: photoURL) == .failed(.offline))
    }

    @Test("classifies rate limiting distinctly from other server errors")
    func classifiesRateLimitingDistinctlyFromOtherServerErrors() async {
        let limited = StubServer(reply: .json(429, "{}"))
        #expect(await client(limited).recognize(imageAt: photoURL) == .failed(.rateLimited))
        let broken = StubServer(reply: .json(500, "{}"))
        #expect(await client(broken).recognize(imageAt: photoURL) == .failed(.serverError))
    }

    @Test("handles a body that is not JSON")
    func handlesABodyThatIsNotJSON() async {
        let server = StubServer(reply: .text(200, "Unexpected token <"))
        #expect(await client(server).recognize(imageAt: photoURL) == .failed(.malformedResponse))
    }

    @Test("omits nameHint entirely when the user has not corrected the name")
    func omitsNameHintEntirelyWhenTheUserHasNotCorrectedTheName() async throws {
        let server = StubServer(reply: .json(200, validBody))
        _ = await client(server).recognize(imageAt: photoURL)
        let body = try #require(server.lastRequest).jsonObject
        #expect(body["nameHint"] == nil)
        #expect(body["image"] != nil)
    }

    @Test("sends the corrected name so the backend re-derives for that item")
    func sendsTheCorrectedNameSoTheBackendReDerivesForThatItem() async throws {
        let server = StubServer(reply: .json(200, validBody))
        _ = await client(server).recognize(imageAt: photoURL, nameHint: "  Angle grinder  ")
        #expect(try #require(server.lastRequest).jsonObject["nameHint"] == .string("Angle grinder"))
    }

    @Test("treats a blank hint as no hint")
    func treatsABlankHintAsNoHint() async throws {
        let server = StubServer(reply: .json(200, validBody))
        _ = await client(server).recognize(imageAt: photoURL, nameHint: "   ")
        #expect(try #require(server.lastRequest).jsonObject["nameHint"] == nil)
    }

    @Test("reports not_configured when no endpoint is set, without calling fetch", arguments: [nil, ""] as [String?])
    func reportsNotConfiguredWhenNoEndpointIsSetWithoutCallingFetch(endpoint: String?) async {
        let server = StubServer(reply: .json(200, validBody))
        let telemetry = TelemetryRecorder()
        let result = await client(server, endpoint: endpoint, telemetry: telemetry).recognize(imageAt: photoURL)
        #expect(result == .failed(.notConfigured))
        #expect(server.requests.isEmpty)
        #expect(telemetry.entries == [.init(level: "event", name: "recognition_skipped", payload: ["outcome": .string("not_configured")])])
    }

    // MARK: Native additions (05 §10, §19)

    @Test("posts the v1 body with the sniffed media type and the contract headers")
    func postsTheV1Body() async throws {
        let server = StubServer(reply: .json(200, validBody))
        _ = await client(server, key: "app-key").recognize(imageAt: photoURL)
        let request = try #require(server.lastRequest)
        #expect(request.method == "POST")
        #expect(request.url == endpoint)
        #expect(request.header("content-type") == "application/json")
        #expect(request.header("x-contract-version") == "1")
        #expect(request.header("x-inventory-key") == "app-key")
        #expect(request.json == .object([
            "contractVersion": .number(1),
            "image": .object([
                "data": .string(webpBytes.base64EncodedString()),
                "encoding": .string("base64"),
                "mediaType": .string("image/webp"),
            ]),
        ]))
    }

    @Test("never prints the app key")
    func neverPrintsTheKey() {
        let recognition = RecognitionClient(endpoint: endpoint, key: "secret-app-key")
        var dumped = ""
        dump(recognition, to: &dumped)
        #expect(!String(describing: recognition).contains("secret-app-key"))
        #expect(!String(reflecting: recognition).contains("secret-app-key"))
        #expect(!dumped.contains("secret-app-key"))
    }

    @Test("sends no x-inventory-key when the key is missing or empty", arguments: [nil, ""] as [String?])
    func sendsNoKeyWhenUnset(key: String?) async throws {
        let server = StubServer(reply: .json(200, validBody))
        _ = await client(server, key: key).recognize(imageAt: photoURL)
        #expect(try #require(server.lastRequest).header("x-inventory-key") == nil)
    }

    @Test("writes base64 without escaped slashes or line breaks")
    func writesBase64WithoutEscapedSlashes() async throws {
        // 0xFF bytes encode to "////", which JSONEncoder would escape by default.
        let bytes = Data([0xFF, 0xD8, 0xFF] + [UInt8](repeating: 0xFF, count: 120))
        let server = StubServer(reply: .json(200, validBody))
        _ = await client(server, image: bytes).recognize(imageAt: photoURL)
        let text = try #require(server.lastRequest).body.utf8Text
        #expect(!text.contains("\\/"))
        #expect(!text.contains("\n"))
        #expect(text.contains(bytes.base64EncodedString()))
        #expect(text.contains(#""mediaType":"image/jpeg""#))
    }

    @Test("the deadline covers the response body, not just the headers")
    func theDeadlineCoversTheBody() async {
        let server = StubServer(reply: .slowBody(status: 200, headers: ["Content-Type": "application/json"], body: Data(validBody.utf8), bodyDelay: .seconds(10)))
        #expect(await client(server, timeout: .milliseconds(200)).recognize(imageAt: photoURL) == .failed(.timeout))
    }

    @Test("a name the server cut through an emoji is still a suggestion")
    func loneSurrogateFromTheServerCut() async throws {
        // server/src/prompt.ts cuts at 80 UTF-16 units; JSON.stringify writes the half pair as \ud83d.
        let name = String(repeating: "x", count: 79)
        let body = #"{"contractVersion":1,"suggestion":{"name":"\#(name)\ud83d","category":"Tools","tags":[],"confidence":0.9}}"#
        let server = StubServer(reply: .json(200, body))
        let result = await client(server).recognize(imageAt: photoURL)
        #expect(result == .success(
            RecognitionSuggestion(name: name + "\u{FFFD}", category: "Tools", tags: [], confidence: 0.9),
            contractVersion: 1
        ))
    }

    @Test("the deadline covers the file read")
    func theDeadlineCoversTheFileRead() async {
        let server = StubServer(reply: .json(200, validBody))
        let slowRead = RecognitionClient(
            endpoint: endpoint, key: nil, timeout: .milliseconds(100), transport: server.transport,
            readImage: { _ in
                try await Task.sleep(for: .seconds(10))
                return webpBytes
            },
            telemetry: TelemetryRecorder().telemetry
        )
        #expect(await slowRead.recognize(imageAt: photoURL) == .failed(.timeout))
        #expect(server.requests.isEmpty)
    }

    @Test("a photo that cannot be read is a server error")
    func unreadablePhotoIsServerError() async {
        let server = StubServer(reply: .json(200, validBody))
        let missing = RecognitionClient(
            endpoint: endpoint, key: nil, transport: server.transport,
            readImage: { try Data(contentsOf: $0) },
            telemetry: TelemetryRecorder().telemetry
        )
        #expect(await missing.recognize(imageAt: URL(fileURLWithPath: "/nonexistent/\(UUID()).webp")) == .failed(.serverError))
        #expect(server.requests.isEmpty)
    }

    @Test("maps transport failures to offline, as RN's 'Network request failed' did", arguments: [
        URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
        .dnsLookupFailed, .timedOut, .secureConnectionFailed, .dataNotAllowed, .internationalRoamingOff,
    ])
    func mapsTransportFailuresToOffline(code: URLError.Code) async {
        let server = StubServer(reply: .failure(code, delay: nil))
        #expect(await client(server).recognize(imageAt: photoURL) == .failed(.offline))
    }

    @Test("maps a broken server response to server_error")
    func mapsBadServerResponseToServerError() async {
        let recognition = RecognitionClient(
            endpoint: endpoint, key: nil, transport: ThrowingTransport(error: URLError(.badServerResponse)),
            readImage: { _ in webpBytes }, telemetry: TelemetryRecorder().telemetry
        )
        #expect(await recognition.recognize(imageAt: photoURL) == .failed(.serverError))
    }

    @Test("reads every non-2xx other than 429 as a server error, 504 included", arguments: [400, 401, 413, 500, 502, 504])
    func readsNon2xxAsServerError(status: Int) async {
        let server = StubServer(reply: .json(status, #"{"error":"x"}"#))
        #expect(await client(server).recognize(imageAt: photoURL) == .failed(.serverError))
    }

    @Test("reports the server's unrecognized and low-confidence answers")
    func reportsUnrecognized() async {
        let unrecognized = StubServer(reply: .json(200, #"{"contractVersion":1,"status":"unrecognized"}"#))
        #expect(await client(unrecognized).recognize(imageAt: photoURL) == .failed(.unrecognized))
    }

    @Test("logs completion with outcome, confidence and whether a hint was sent, never the text")
    func logsCompletion() async throws {
        let telemetry = TelemetryRecorder()
        let server = StubServer(reply: .json(200, validBody))
        _ = await client(server, telemetry: telemetry).recognize(imageAt: photoURL, nameHint: "Angle grinder")
        let entry = try #require(telemetry.entries.first)
        #expect(telemetry.entries.count == 1)
        #expect(entry.level == "event")
        #expect(entry.name == "recognition_completed")
        #expect(Set(entry.payload.keys) == ["outcome", "latencyMs", "contractVersion", "confidence", "hinted"])
        #expect(entry.payload["outcome"] == .string("success"))
        #expect(entry.payload["contractVersion"] == .int(1))
        #expect(entry.payload["confidence"] == .double(0.92))
        #expect(entry.payload["hinted"] == .bool(true))
    }

    @Test("logs a parsed failure as completed with a null confidence")
    func logsParsedFailure() async throws {
        let telemetry = TelemetryRecorder()
        let server = StubServer(reply: .json(200, #"{"contractVersion":1,"status":"unrecognized"}"#))
        _ = await client(server, telemetry: telemetry).recognize(imageAt: photoURL)
        let entry = try #require(telemetry.entries.first)
        #expect(entry.name == "recognition_completed")
        #expect(entry.payload["outcome"] == .string("unrecognized"))
        #expect(entry.payload["confidence"] == .null)
        #expect(entry.payload["hinted"] == .bool(false))
    }

    @Test("logs an HTTP failure as an error with its status")
    func logsHTTPFailure() async throws {
        let telemetry = TelemetryRecorder()
        let server = StubServer(reply: .json(429, #"{"error":"rate_limited"}"#))
        _ = await client(server, telemetry: telemetry).recognize(imageAt: photoURL)
        let entry = try #require(telemetry.entries.first)
        #expect(entry.level == "error")
        #expect(entry.name == "recognition_failed")
        #expect(Set(entry.payload.keys) == ["outcome", "statusCode", "latencyMs", "contractVersion", "hinted"])
        #expect(entry.payload["outcome"] == .string("rate_limited"))
        #expect(entry.payload["statusCode"] == .int(429))
    }

    @Test("logs a non-JSON body and a transport failure as errors without a status")
    func logsOtherFailures() async throws {
        let telemetry = TelemetryRecorder()
        _ = await client(StubServer(reply: .text(200, "nope")), telemetry: telemetry).recognize(imageAt: photoURL)
        _ = await client(StubServer(reply: .failure(.notConnectedToInternet, delay: nil)), telemetry: telemetry)
            .recognize(imageAt: photoURL)
        let entries = telemetry.entries
        #expect(entries.map(\.name) == ["recognition_failed", "recognition_failed"])
        #expect(entries.map { $0.payload["outcome"] } == [.string("malformed_response"), .string("offline")])
        #expect(entries.allSatisfy { $0.level == "error" && $0.payload["statusCode"] == nil })
    }
}

@Suite("ImageMediaType.sniff")
struct ImageMediaTypeTests {
    @Test("reads the magic numbers of the formats the server accepts", arguments: [
        ([0x52, 0x49, 0x46, 0x46, 0x10, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38], "image/webp"),
        ([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10], "image/jpeg"),
        ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00], "image/png"),
        (Array("GIF89a....".utf8), "image/gif"),
        (Array("GIF87a....".utf8), "image/gif"),
    ] as [([UInt8], String)])
    func readsMagicNumbers(bytes: [UInt8], expected: String) {
        #expect(ImageMediaType.sniff(Data(bytes)) == expected)
    }

    @Test("falls back to image/jpeg, what RN always declared", arguments: [
        [], [0x52, 0x49, 0x46, 0x46], Array("RIFF\0\0\0\0WAVE".utf8), Array("<html>".utf8), [0x89, 0x50, 0x4E],
    ] as [[UInt8]])
    func fallsBackToJPEG(bytes: [UInt8]) {
        #expect(ImageMediaType.sniff(Data(bytes)) == "image/jpeg")
    }

    @Test("reads a slice of a larger buffer by its own start")
    func readsASlice() {
        let buffer = Data([0x00, 0x00] + [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(ImageMediaType.sniff(buffer.dropFirst(2)) == "image/png")
    }
}
