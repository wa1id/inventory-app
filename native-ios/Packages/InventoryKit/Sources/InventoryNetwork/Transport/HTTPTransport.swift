import Foundation

/// A fully buffered HTTP response: status, headers and the whole body.
///
/// RN's `fetch` (the `whatwg-fetch` polyfill over XHR) resolves only once the
/// body has arrived, so every client here works with complete bodies too.
public struct HTTPResponse: Sendable, Equatable {
    public let status: Int
    /// Header fields with lowercased names.
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }

    /// `response.ok`: a status in 200–299.
    public var isSuccess: Bool { (200...299).contains(status) }

    /// A header value by case-insensitive name.
    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// Sends one request and returns once the whole response body is in memory.
///
/// The clients wrap every call in ``withTotalTimeout(_:clock:operation:)``, so a
/// transport only has to send and buffer. Tests swap the `URLSession` for one
/// whose configuration routes through a `URLProtocol` stub.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// The production transport: `URLSession.data(for:)`, which returns only after the full body.
public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    /// One shared session for every client, built from ``makeConfiguration()``.
    public static let shared = URLSessionTransport(
        session: URLSession(configuration: URLSessionTransport.makeConfiguration())
    )

    /// An ephemeral configuration with no `URLCache` and no cookies (03 §4.1).
    ///
    /// Photo GETs answer `cache-control: private, max-age=31536000, immutable`;
    /// with a disk cache those authenticated photos, and possibly whole database
    /// snapshots, would land in `Library/Caches`, and `GET /v1/backups/latest`
    /// could be answered from it. The idle timeouts are generous on purpose: the
    /// clients enforce RN's total wall-clock deadline themselves.
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

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            guard let name = name as? String else { continue }
            headers[name.lowercased()] = value as? String ?? String(describing: value)
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

extension URLRequest {
    /// A request that never consults a cache, with an idle timeout comfortably
    /// above `deadline` so URLSession's own timeout never pre-empts the client's
    /// total deadline (05 §10.5).
    init(url: URL, method: String, deadline: Duration) {
        let seconds = Double(deadline.components.seconds) + Double(deadline.components.attoseconds) / 1e18
        self.init(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: max(seconds + 30, 60))
        httpMethod = method
    }
}
