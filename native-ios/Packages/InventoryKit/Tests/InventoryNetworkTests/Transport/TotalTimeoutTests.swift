import Foundation
import InventoryCore
import InventoryTestSupport
import Testing
@testable import InventoryNetwork

@Suite("withTotalTimeout")
struct TotalTimeoutTests {
    @Test("returns the operation's value when it finishes in time")
    func returnsTheValue() async throws {
        let value = try await withTotalTimeout(.seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test("throws DeadlineExceeded when the clock wins, and cancels the operation")
    func deadlineWins() async {
        let started = ContinuousClock.now
        await #expect(throws: DeadlineExceeded.self) {
            try await withTotalTimeout(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(10))
                return 1
            }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("uses the injected clock")
    func usesTheInjectedClock() async throws {
        let clock = ManualClock()
        let exchange = Task {
            try await withTotalTimeout(.seconds(3600), clock: clock) {
                try await Task.sleep(for: .seconds(10))
                return 1
            }
        }
        try await clock.waitForSleepers()
        #expect(clock.nextDeadline == ManualClock.Instant(offset: .seconds(3600)))
        await clock.advance(by: .seconds(3599))
        #expect(clock.pendingSleeperCount == 1)
        await clock.advance(by: .seconds(1))
        await #expect(throws: DeadlineExceeded.self) { try await exchange.value }
    }

    @Test("a body still arriving when the clock runs out is a deadline, through a real URLSession")
    func coversTheBody() async throws {
        let server = StubServer(reply: .slowBody(status: 200, headers: [:], body: Data(count: 64), bodyDelay: .seconds(10)))
        let transport = server.transport
        let request = URLRequest(url: try #require(URL(string: "https://slow.example/body")), method: "GET", deadline: .milliseconds(200))
        let started = ContinuousClock.now
        await #expect(throws: DeadlineExceeded.self) {
            try await withTotalTimeout(.milliseconds(200)) { try await transport.send(request) }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("passes the operation's own error through")
    func passesErrorsThrough() async {
        await #expect(throws: URLError(.notConnectedToInternet)) {
            try await withTotalTimeout(.seconds(5)) { () -> Int in throw URLError(.notConnectedToInternet) }
        }
    }

    @Test("a cancelled caller is not a deadline")
    func cancellationIsNotADeadline() async {
        let task = Task {
            try await withTotalTimeout(.seconds(10)) {
                try await Task.sleep(for: .seconds(10))
                return 1
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected an error")
        } catch {
            #expect(!(error is DeadlineExceeded))
            #expect(error is CancellationError)
        }
    }
}

@Suite("TransportFailure.classify")
struct TransportFailureTests {
    @Test("our deadline is its own class")
    func deadline() {
        #expect(TransportFailure.classify(DeadlineExceeded()) == .deadline)
    }

    @Test("connectivity, DNS, TLS and URLSession timeouts read as offline", arguments: [
        URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
        .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed,
        .serverCertificateUntrusted, .serverCertificateHasBadDate, .clientCertificateRequired,
    ])
    func offline(code: URLError.Code) {
        #expect(TransportFailure.classify(URLError(code)) == .offline)
    }

    @Test("a broken server answer or a bad URL is something else", arguments: [
        URLError.Code.badServerResponse, .cannotParseResponse, .badURL, .unsupportedURL, .zeroByteResource,
    ])
    func other(code: URLError.Code) {
        #expect(TransportFailure.classify(URLError(code)) == .other)
    }

    @Test("a cancellation outside a cancelled task, and a file error, are something else")
    func otherErrors() {
        #expect(TransportFailure.classify(URLError(.cancelled)) == .other)
        #expect(TransportFailure.classify(CancellationError()) == .other)
        #expect(TransportFailure.classify(CocoaError(.fileReadNoSuchFile)) == .other)
    }

    @Test("a cancellation inside a cancelled task is the caller's")
    func cancelled() async {
        let task = Task {
            try? await Task.sleep(for: .seconds(10))
            return (TransportFailure.classify(URLError(.cancelled)), TransportFailure.classify(CancellationError()))
        }
        task.cancel()
        let (urlError, cancellation) = await task.value
        #expect(urlError == .cancelled)
        #expect(cancellation == .cancelled)
    }

    @Test("telemetry names a transport's bridged NSError URLError, through InventoryCore's errorClass")
    func urlErrorClass() async {
        let telemetry = RecordingTelemetry()
        let failing = ThrowingTransport(error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        let client = HouseholdClient(origin: "https://a.example", token: "t", transport: failing, telemetry: telemetry.telemetry)
        _ = try? await client.send(HouseholdRequest(path: "/v1/spaces"))
        #expect(telemetry.entries == [.init(level: "error", name: "household_fetch_failed", payload: ["errorClass": .string("URLError")])])
    }
}

@Suite("Wire helpers")
struct WireHelperTests {
    @Test("strips trailing slashes only", arguments: [
        ("https://a.example/", "https://a.example"), ("https://a.example///", "https://a.example"),
        ("https://a.example", "https://a.example"), ("/", ""), ("", ""), ("a/b/", "a/b"),
    ])
    func stripsTrailingSlashes(input: String, expected: String) {
        #expect(strippingTrailingSlashes(input) == expected)
    }

    @Test("an ephemeral session with no cache and no cookies")
    func sessionConfiguration() {
        let configuration = URLSessionTransport.makeConfiguration()
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.timeoutIntervalForRequest > 60)
    }

    @Test("requests never use a cache and their idle timeout outlasts the deadline")
    func requestDefaults() throws {
        let request = URLRequest(url: try #require(URL(string: "https://a.example")), method: "PUT", deadline: .seconds(60))
        #expect(request.httpMethod == "PUT")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.timeoutInterval == 90)
        let short = URLRequest(url: try #require(URL(string: "https://a.example")), method: "GET", deadline: .milliseconds(100))
        #expect(short.timeoutInterval == 60)
    }

    @Test("lone surrogate escapes read as U+FFFD; pairs, other escapes and plain text are untouched", arguments: [
        (#""\ud83d""#, "\u{FFFD}"), (#""\udc00""#, "\u{FFFD}"), (#""a\ud83d\u0041""#, "a\u{FFFD}A"),
        (#""\ud83d\ud83d\udd27""#, "\u{FFFD}\u{1F527}"), (#""\ud83d\udd27""#, "\u{1F527}"), (#""\\ud83d""#, #"\ud83d"#),
        (#""\"\ud83d""#, "\"\u{FFFD}"), (#""x\uD83D""#, "x\u{FFFD}"),
    ])
    func loneSurrogates(json: String, expected: String) {
        #expect(JSONValue.parse(Data(json.utf8)) == .string(expected), "\(json)")
    }

    @Test("a body that is broken for another reason stays broken")
    func otherBreakageStaysBroken() {
        #expect(JSONValue.parse(Data(#"{"a":"\ud83d"#.utf8)) == nil)
        #expect(JSONValue.parse(Data(#"{"a":"\ud83d"} x"#.utf8)) == nil)
        #expect(JSONValue.parse(Data(#"{"a":"\q"}"#.utf8)) == nil)
    }

    @Test("a body is read as response.json() reads it: a UTF-8 BOM is dropped, invalid UTF-8 is refused")
    func bodyDecoding() {
        #expect(JSONValue.parse(Data([0xEF, 0xBB, 0xBF]) + Data(#"{"a":1}"#.utf8)) == .object(["a": .number(1)]))
        #expect(JSONValue.parse(Data([0x22, 0xFF, 0x22])) == nil)
        #expect(JSONValue.parse(Data()) == nil)
    }

    @Test("HTTPResponse reads headers case-insensitively")
    func headerLookup() {
        let response = HTTPResponse(status: 200, headers: ["X-Snapshot-Schema-Version": "7"])
        #expect(response.header("x-snapshot-schema-version") == "7")
        #expect(response.header("X-SNAPSHOT-SCHEMA-VERSION") == "7")
        #expect(response.isSuccess)
        #expect(!HTTPResponse(status: 304).isSuccess)
    }
}
