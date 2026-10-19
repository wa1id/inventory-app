import Foundation
import InventoryCore
import Synchronization

/// A request as the stub server received it, after URLSession built it.
public struct RecordedRequest: Sendable {
    public let method: String
    public let url: String
    /// Header fields with lowercased names; the routing header is left out.
    public let headers: [String: String]
    public let body: Data

    public init(method: String, url: String, headers: [String: String], body: Data) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// The percent-encoded path, with the query when there is one.
    public var path: String {
        guard let components = URLComponents(string: url) else { return url }
        return components.percentEncodedPath + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
    }

    /// `METHOD url`, for readable expectations.
    public var line: String { "\(method) \(url)" }

    /// A header value by case-insensitive name.
    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// The body parsed as JSON (`JSON.parse`).
    public var json: JSONValue? { JSONValue.parse(body) }

    /// The body's members when it is a JSON object, otherwise empty.
    public var jsonObject: [String: JSONValue] { json?.objectValue ?? [:] }
}

/// What the stub answers.
public enum StubReply: Sendable {
    /// Status, headers and body at once, after an optional delay.
    case response(status: Int, headers: [String: String], body: Data, delay: Duration?)
    /// The load fails with this `URLError` code, after an optional delay.
    case failure(URLError.Code, delay: Duration?)
    /// The status and headers at once, then the body only after `bodyDelay`: what a slow
    /// download looks like, for checking that a deadline covers the body and not just the headers.
    case slowBody(status: Int, headers: [String: String], body: Data, bodyDelay: Duration)

    /// A JSON body with `Content-Type: application/json` (overridable through `headers`).
    public static func json(_ status: Int, _ text: String, headers: [String: String] = [:], delay: Duration? = nil) -> StubReply {
        var merged = ["Content-Type": "application/json"]
        merged.merge(headers) { _, new in new }
        return .response(status: status, headers: merged, body: Data(text.utf8), delay: delay)
    }

    /// A status with no headers and no body.
    public static func status(_ status: Int, delay: Duration? = nil) -> StubReply {
        .response(status: status, headers: [:], body: Data(), delay: delay)
    }

    /// Raw bytes.
    public static func bytes(_ status: Int, _ body: Data, headers: [String: String] = [:]) -> StubReply {
        .response(status: status, headers: headers, body: body, delay: nil)
    }

    /// A text body, plain text by default.
    public static func text(_ status: Int, _ text: String, contentType: String = "text/plain; charset=UTF-8") -> StubReply {
        .response(status: status, headers: ["Content-Type": contentType], body: Data(text.utf8), delay: nil)
    }
}

/// An in-process HTTP server for one test, reached through a real `URLSession` whose
/// configuration routes every request to ``StubURLProtocol``.
///
/// Each server registers under its own id, which its session sends in a routing header, so
/// tests stay independent and can run in parallel. It records every request it receives
/// (``requests``) and answers each with whatever its handler returns: one fixed reply, or a
/// script that looks at the request (or at how many came before).
public final class StubServer: Sendable {
    public typealias Handler = @Sendable (RecordedRequest) async -> StubReply

    public let id = UUID().uuidString
    private let handler: Handler
    private let recorded = Mutex<[RecordedRequest]>([])
    /// The session to hand to the code under test.
    public let session: URLSession

    /// - Parameters:
    ///   - configuration: the session configuration to start from (``makeConfiguration()``
    ///     by default); the stub protocol and routing header are added to it.
    ///   - handler: answers each request.
    public init(configuration base: URLSessionConfiguration = StubServer.makeConfiguration(), _ handler: @escaping Handler) {
        self.handler = handler
        // A copy, so a configuration the caller keeps is not rerouted behind its back.
        let configuration = (base.copy() as? URLSessionConfiguration) ?? base
        configuration.protocolClasses = [StubURLProtocol.self]
        var headers = configuration.httpAdditionalHeaders ?? [:]
        headers[StubURLProtocol.routeHeader] = id
        configuration.httpAdditionalHeaders = headers
        session = URLSession(configuration: configuration)
        StubRegistry.shared.register(self)
    }

    /// Answers every request with `reply`.
    public convenience init(configuration: URLSessionConfiguration = StubServer.makeConfiguration(), reply: StubReply) {
        self.init(configuration: configuration) { _ in reply }
    }

    deinit {
        StubRegistry.shared.unregister(id)
        session.finishTasksAndInvalidate()
    }

    /// An ephemeral configuration that never caches and never stores cookies, so every request
    /// reaches the handler, with idle timeouts long enough that the code under test, not
    /// URLSession, decides when a slow answer has taken too long.
    public static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3600
        return configuration
    }

    /// Every request received so far, oldest first.
    public var requests: [RecordedRequest] { recorded.withLock { $0 } }

    public var lastRequest: RecordedRequest? { requests.last }

    fileprivate func handle(_ request: RecordedRequest) async -> StubReply {
        recorded.withLock { $0.append(request) }
        return await handler(request)
    }
}

/// Routes stub requests to their server by id.
final class StubRegistry: Sendable {
    static let shared = StubRegistry()
    private let servers = Mutex<[String: WeakServer]>([:])

    private struct WeakServer: @unchecked Sendable {
        // A weak reference to a Sendable class; only read under the registry's lock.
        weak var server: StubServer?
    }

    func register(_ server: StubServer) {
        servers.withLock { $0[server.id] = WeakServer(server: server) }
    }

    func unregister(_ id: String) {
        _ = servers.withLock { $0.removeValue(forKey: id) }
    }

    func server(for id: String) -> StubServer? {
        servers.withLock { $0[id]?.server }
    }
}

/// Answers URLSession requests from the ``StubServer`` named by the routing header.
///
/// `@unchecked Sendable`: URLProtocol is an Objective-C class URLSession drives
/// from its own queue; the only mutable state, `work`, is guarded by a Mutex.
public final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    /// The header a ``StubServer``'s session sends to name its server.
    public static let routeHeader = "X-Stub-Route"

    private let work = Mutex<Task<Void, Never>?>(nil)

    override public class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: routeHeader) != nil
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override public func startLoading() {
        let request = self.request
        guard let id = request.value(forHTTPHeaderField: Self.routeHeader),
              let server = StubRegistry.shared.server(for: id),
              let url = request.url
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] where name.caseInsensitiveCompare(Self.routeHeader) != .orderedSame {
            headers[name.lowercased()] = value
        }
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            url: url.absoluteString,
            headers: headers,
            body: Self.body(of: request)
        )
        let target = ProtocolReference(base: self)
        let task = Task {
            let reply = await server.handle(recorded)
            let delay: Duration? = switch reply {
            case .response(_, _, _, let delay), .failure(_, let delay): delay
            case .slowBody: nil
            }
            if let delay {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard !Task.isCancelled else { return }
            if case .slowBody(let status, let headers, let body, let bodyDelay) = reply {
                guard target.base.deliverHead(status: status, headers: headers, url: url) else { return }
                do { try await Task.sleep(for: bodyDelay) } catch { return }
                guard !Task.isCancelled else { return }
                target.base.deliverBody(body)
                return
            }
            target.base.deliver(reply, url: url)
        }
        work.withLock { $0 = task }
    }

    private func deliver(_ reply: StubReply, url: URL) {
        switch reply {
        case .response(let status, let headers, let body, _), .slowBody(let status, let headers, let body, _):
            guard deliverHead(status: status, headers: headers, url: url) else { return }
            deliverBody(body)
        case .failure(let code, _):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    /// Sends the status line and headers; false (after failing the load) when they do not make a response.
    private func deliverHead(status: Int, headers: [String: String], url: URL) -> Bool {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return false
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        return true
    }

    private func deliverBody(_ body: Data) {
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Carries the protocol into its reply task.
    private struct ProtocolReference: @unchecked Sendable {
        // StubURLProtocol is @unchecked Sendable itself; the wrapper only keeps the
        // region checker from tying `self` to startLoading's task.
        let base: StubURLProtocol
    }

    override public func stopLoading() {
        work.withLock { $0?.cancel() }
    }

    /// URLSession hands a data task's body to protocols as a stream.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

extension Data {
    /// UTF-8 text, for readable expectations.
    public var utf8Text: String { String(decoding: self, as: UTF8.self) }
}
