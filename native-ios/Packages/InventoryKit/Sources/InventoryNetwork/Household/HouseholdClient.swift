import Foundation
import InventoryCore

/// One request to the home server, before the client adds its headers.
public struct HouseholdRequest: Sendable {
    /// What goes in the body.
    public enum Body: Sendable {
        case none
        /// JSON text, sent as `Content-Type: application/json`.
        case json(Data)
        /// Raw bytes, sent as `Content-Type: application/octet-stream`.
        case bytes(Data)

        /// `value` as JSON the way `JSON.stringify` writes it.
        public static func encodedJSON(_ value: some Encodable) throws -> Body {
            .json(try wireJSONEncoder().encode(value))
        }
    }

    /// The path, query included, appended to the origin as is.
    public var path: String
    public var method: String
    public var body: Body
    /// The total deadline; nil means the client's default (20 s).
    public var timeout: Duration?
    /// Whether to send the session token. Pairing and the health ping do not.
    public var authenticated: Bool

    public init(path: String, method: String = "GET", body: Body = .none, timeout: Duration? = nil, authenticated: Bool = true) {
        self.path = path
        self.method = method
        self.body = body
        self.timeout = timeout
        self.authenticated = authenticated
    }
}

/// Typed client for the household API of the home server (RN: src/services/household/client.ts,
/// devices.ts and the HTTP calls of httpRepositories.ts, photoCache.ts and importHousehold.ts).
///
/// Requests carry `Authorization: Bearer <device token>` and never `x-inventory-key`
/// (09 §8.3). Failures throw ``HouseholdHttpError`` with RN's codes (`offline`,
/// `timeout`, `invalid_json`, `invalid_response`, `http_NNN` or the server's own
/// `error`), or ``ConflictError`` for a 409. Every exchange also reports to the
/// ``ReachabilityHub``. There are no retries.
public struct HouseholdClient: Sendable {
    /// RN `householdFetch` default.
    public static let defaultTimeout: Duration = .seconds(20)
    /// Item-create photo uploads, the import and each import photo (RN 60 000 ms).
    public static let uploadTimeout: Duration = .seconds(60)
    /// The offline health ping (RN `HEALTH_TIMEOUT_MS`).
    public static let healthTimeout: Duration = .seconds(5)

    /// The session origin (or, before pairing, the build's household origin).
    public let origin: String
    private let token: String?
    private let transport: any HTTPTransport
    private let reachability: ReachabilityHub?
    private let clock: any Clock<Duration>
    private let telemetry: NetworkTelemetry
    private let makeId: @Sendable () -> String

    /// - Parameters:
    ///   - origin: used verbatim as the URL prefix (RN `${session.origin}${path}`).
    ///   - token: the device token; nil before pairing.
    ///   - reachability: where every exchange reports; nil reports nowhere.
    ///   - makeId: the photo-id source for item-create uploads (RN `newId()`).
    public init(
        origin: String,
        token: String?,
        transport: any HTTPTransport = URLSessionTransport.shared,
        reachability: ReachabilityHub? = nil,
        clock: any Clock<Duration> = ContinuousClock(),
        telemetry: NetworkTelemetry = .standard,
        makeId: @escaping @Sendable () -> String = { newId() }
    ) {
        self.origin = origin
        self.token = token
        self.transport = transport
        self.reachability = reachability
        self.clock = clock
        self.telemetry = telemetry
        self.makeId = makeId
    }

    /// The same transport, hub, clock and telemetry against another origin and token,
    /// for example the session a pairing returned.
    public func withSession(origin: String, token: String?) -> HouseholdClient {
        HouseholdClient(
            origin: origin, token: token, transport: transport, reachability: reachability,
            clock: clock, telemetry: telemetry, makeId: makeId
        )
    }

    /// A fresh photo id for an upload.
    func newPhotoId() -> String { makeId() }

    // MARK: - householdFetch

    /// RN `householdFetch`: sends the request under its total deadline and reports
    /// reachability; any HTTP status is returned, not thrown.
    ///
    /// - Throws: ``HouseholdHttpError`` `(0, "timeout")` when the deadline fires and
    ///   `(0, "offline")` for any transport failure, both reported as `offline`;
    ///   `CancellationError` when the calling task was cancelled, which reports nothing.
    public func send(_ request: HouseholdRequest) async throws -> HTTPResponse {
        let bearer = request.authenticated ? token.flatMap { $0.isEmpty ? nil : $0 } : nil
        let deadline = request.timeout ?? Self.defaultTimeout
        do {
            let response = try await withTotalTimeout(deadline, clock: clock) { [self] in
                try await transport.send(try makeURLRequest(request, bearer: bearer, deadline: deadline))
            }
            reachability?.report(.of(status: response.status, hadToken: bearer != nil))
            return response
        } catch {
            switch TransportFailure.classify(error) {
            case .cancelled:
                // RN never cancels a request; a view going away is not the server going away.
                throw CancellationError()
            case .deadline:
                reachability?.report(.offline)
                throw HouseholdHttpError(status: 0, code: "timeout")
            case .offline, .other:
                reachability?.report(.offline)
                telemetry.error("household_fetch_failed", ["errorClass": .string(errorClass(of: error))])
                throw HouseholdHttpError(status: 0, code: "offline")
            }
        }
    }

    private func makeURLRequest(_ request: HouseholdRequest, bearer: String?, deadline: Duration) throws -> URLRequest {
        guard let url = URL(string: origin + request.path) else { throw URLError(.badURL) }
        var urlRequest = URLRequest(url: url, method: request.method, deadline: deadline)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        switch request.body {
        case .none:
            break
        case .json(let data):
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = data
        case .bytes(let data):
            urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = data
        }
        if let bearer {
            urlRequest.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        return urlRequest
    }

    // MARK: - householdRequest

    /// RN `householdRequest` followed by a decode of the body.
    ///
    /// A 2xx body that does not decode as `T` throws `HouseholdHttpError(status, "invalid_response")`,
    /// so it reads as a server problem rather than a crash (04 §4).
    public func request<T: Decodable>(_ request: HouseholdRequest, as type: T.Type = T.self) async throws -> T {
        let answer = try await object(request)
        do {
            return try JSONDecoder().decode(T.self, from: answer.data)
        } catch {
            throw HouseholdHttpError(status: answer.status, code: "invalid_response")
        }
    }

    /// RN `householdRequest`: the 2xx body as a JSON object or array (`{}` for a 204,
    /// an empty body or any other value), after RN's error mapping. `data` is the
    /// body to decode keyed shapes from: the object's JSON, or `{}`.
    ///
    /// 1. A non-empty body must parse as JSON (`JSON.parse`, exactly), whatever the status,
    ///    or it is `(status, "invalid_json")`: a Cloudflare HTML 52x page is `(530, "invalid_json")`.
    /// 2. 409 throws ``ConflictError`` with JS `Number(body.updatedAt)` when finite.
    /// 3. Another non-2xx throws `(status, String(body.error))`, or `(status, "http_<status>")`
    ///    without an `error` key.
    ///
    /// `data` is the parsed object written back out (`JSON.stringify`), not the raw body, so
    /// the `Decodable` pass sees exactly what `JSON.parse` saw: the last of duplicate keys,
    /// numbers already rounded as JS rounds them, and a lone surrogate escape (which the
    /// servers write when `slice` cuts an emoji, and `JSONDecoder` refuses) already U+FFFD.
    func object(_ request: HouseholdRequest) async throws -> (status: Int, value: JSONValue, data: Data) {
        let response = try await send(request)
        if response.status == 204 { return (204, .object([:]), Self.emptyObject) }
        var parsed = JSONValue.object([:])
        if !response.body.isEmpty {
            guard let body = JSONValue.parse(response.body) else {
                throw HouseholdHttpError(status: response.status, code: "invalid_json")
            }
            parsed = body
        }
        if response.status == 409 {
            throw ConflictError(updatedAt: Self.conflictUpdatedAt(parsed))
        }
        guard response.isSuccess else {
            let code = parsed.objectValue?["error"].map(\.jsString) ?? "http_\(response.status)"
            throw HouseholdHttpError(status: response.status, code: code)
        }
        switch parsed {
        case .object:
            return (response.status, parsed, Data(parsed.jsonText.utf8))
        case .array:
            // `typeof [] === 'object'`, so RN returns the array itself; its keyed
            // reads (`body.spaces`) are undefined, which decoding `{}` reproduces.
            return (response.status, parsed, Self.emptyObject)
        default:
            return (response.status, .object([:]), Self.emptyObject)
        }
    }

    private static let emptyObject = Data("{}".utf8)

    /// RN: `'updatedAt' in body ? Number(body.updatedAt) : null`, kept when finite.
    /// `null` → 0, `"11"` → 11, junk → nil.
    static func conflictUpdatedAt(_ body: JSONValue) -> Int64? {
        guard let value = body.objectValue?["updatedAt"] else { return nil }
        return value.jsNumber?.truncatedInt64
    }

    /// `callIgnoring404`: nil when the server answers 404 (including Hono's plain-text 404).
    func ignoring404<T>(_ work: () async throws -> T) async throws -> T? {
        do {
            return try await work()
        } catch let error as HouseholdHttpError where error.status == 404 {
            return nil
        }
    }
}

extension HouseholdClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Leaves the device token out of `print`, `dump` and string interpolation.
    public var description: String { "HouseholdClient(origin: \(origin))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["origin": origin, "authenticated": token != nil], displayStyle: .struct)
    }
}
