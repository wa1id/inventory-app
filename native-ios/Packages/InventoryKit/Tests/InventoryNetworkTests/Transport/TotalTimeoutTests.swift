import Foundation
import Testing
@testable import InventoryNetwork

/// A clock whose sleeps end at once: the deadline is always already past.
private struct ImmediateClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
    }
}

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
    func usesTheInjectedClock() async {
        await #expect(throws: DeadlineExceeded.self) {
            try await withTotalTimeout(.seconds(3600), clock: ImmediateClock()) {
                try await Task.sleep(for: .seconds(10))
                return 1
            }
        }
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

    @Test("telemetry names URLSession's errors URLError")
    func errorClass() {
        #expect(errorClassName(URLError(.timedOut)) == "URLError")
        #expect(errorClassName(NSError(domain: NSURLErrorDomain, code: -1009)) == "URLError")
        #expect(errorClassName(CancellationError()) == "CancellationError")
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

    @Test("HTTPResponse reads headers case-insensitively")
    func headerLookup() {
        let response = HTTPResponse(status: 200, headers: ["X-Snapshot-Schema-Version": "7"])
        #expect(response.header("x-snapshot-schema-version") == "7")
        #expect(response.header("X-SNAPSHOT-SCHEMA-VERSION") == "7")
        #expect(response.isSuccess)
        #expect(!HTTPResponse(status: 304).isSuccess)
    }
}
