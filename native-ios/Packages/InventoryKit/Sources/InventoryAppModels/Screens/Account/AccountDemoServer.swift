import Foundation
import Synchronization
import InventoryCore
import InventoryNetwork
import InventoryServices

/// The home server and the backup service in memory, for ``AccountDemoScenario``: a transport
/// that answers the requests the account screens make, by host, the way the real servers do
/// (04 §3.5, 03 §4.6). Every other household read answers an empty object, which the clients
/// read as empty lists.
///
/// - Home server (``householdOrigin``): `POST /v1/pair` (``householdCode`` accepted, anything
///   else 401), `GET /v1/health`, `GET /v1/devices`, `DELETE /v1/devices/:id`, `POST /v1/import`
///   and `PUT /v1/photos/:id`.
/// - Backup service (``syncEndpoint``): photos, `PUT /v1/backups` (stored, `capturedAt` the
///   device clock), `GET /v1/backups` and `GET /v1/backups/latest`.
public final class AccountDemoServer: HTTPTransport, Sendable {
    /// Where pairing and the demo household's requests go.
    public static let householdOrigin = "https://home.demo.invalid"
    /// The demo backup service.
    public static let syncEndpoint = "https://backup.demo.invalid"
    /// Configured so Settings and Privacy describe photo suggestions; never called here.
    public static let recognitionEndpoint = "https://suggestions.demo.invalid/v1/recognize"
    /// The household code the demo home server accepts (RN join.test.ts's `CODE`).
    public static let householdCode = "MMWKYM2H78ABCDEFGHJKMNPQRS"
    /// The demo backup account's recovery code (03 §3.8's first vector).
    public static let recoveryCode = "89144GJ289144GJ289144GJ288"
    /// This phone in the demo household.
    public static let thisPhoneId = "demo-this-phone"
    /// The session of a phone that joined the demo household.
    public static let session = HouseholdSession(
        origin: householdOrigin,
        token: "demo-session-token",
        deviceId: thisPhoneId,
        deviceName: "Kitchen iPhone",
        householdName: "Home"
    )

    /// How the phone list answers.
    public enum Devices: Sendable, Hashable {
        case answer
        /// Never answers (the client's 20 s deadline ends it).
        case hang
        /// `500 {"error":"server_error"}`.
        case fail
    }

    public struct Behaviour: Sendable, Hashable {
        /// False: every home-server request fails as if offline.
        public var householdReachable: Bool
        public var devices: Devices
        /// False: every backup-service request fails as if offline.
        public var backupServiceReachable: Bool
        /// `PUT /v1/backups` never answers (a first backup still uploading).
        public var backupsHang: Bool

        public init(householdReachable: Bool = true, devices: Devices = .answer, backupServiceReachable: Bool = true, backupsHang: Bool = false) {
            self.householdReachable = householdReachable
            self.devices = devices
            self.backupServiceReachable = backupServiceReachable
            self.backupsHang = backupsHang
        }
    }

    /// One snapshot the backup service holds. `bytes` nil: the sample inventory, made on first download.
    public struct StoredBackup: Sendable, Hashable {
        public var capturedAt: Int64
        public var schemaVersion: Int
        public var bytes: Data?

        public init(capturedAt: Int64, schemaVersion: Int = 7, bytes: Data? = nil) {
            self.capturedAt = capturedAt
            self.schemaVersion = schemaVersion
            self.bytes = bytes
        }
    }

    private struct State: Sendable {
        var behaviour: Behaviour
        var phones: [HouseholdDevice]
        var backups: [StoredBackup]
        var requests: [String] = []
    }

    private let state: Mutex<State>
    private let savedInventory: @Sendable () async throws -> Data
    private let now: @Sendable () -> Int64
    private let latency: Duration

    /// - Parameters:
    ///   - phones: the household's phones, in the order they joined.
    ///   - backups: what the backup account holds, oldest first.
    ///   - savedInventory: the bytes of a backup stored without any.
    ///   - latency: how long each answer takes, so spinners show as they would.
    public init(
        behaviour: Behaviour = Behaviour(),
        phones: [HouseholdDevice] = [],
        backups: [StoredBackup] = [],
        savedInventory: @escaping @Sendable () async throws -> Data = { Data() },
        now: @escaping @Sendable () -> Int64 = { epochMillis() },
        latency: Duration = .milliseconds(350)
    ) {
        state = Mutex(State(behaviour: behaviour, phones: phones, backups: backups))
        self.savedInventory = savedInventory
        self.now = now
        self.latency = latency
    }

    /// Anna's iPhone (joined first, last used 3 days ago), this phone, and the hall iPad (2 hours ago).
    public static func phones(now: Int64) -> [HouseholdDevice] {
        let day: Int64 = 86_400_000
        return [
            HouseholdDevice(id: "demo-anna", name: "Anna’s iPhone", createdAt: now - 40 * day, lastSeenAt: now - 3 * day),
            HouseholdDevice(id: thisPhoneId, name: session.deviceName, createdAt: now - 20 * day, lastSeenAt: now),
            HouseholdDevice(id: "demo-hall-ipad", name: "Hall iPad", createdAt: now - 10 * day, lastSeenAt: now - 2 * 3_600_000),
        ]
    }

    // MARK: - Inspection

    /// "METHOD /path" for every request so far.
    public var requests: [String] { state.withLock { $0.requests } }
    /// The household's phones now.
    public var phones: [HouseholdDevice] { state.withLock { $0.phones } }
    /// The backup account's snapshots now, oldest first.
    public var backups: [StoredBackup] { state.withLock { $0.backups } }

    /// Changes how the servers answer from the next request on.
    public func update(_ change: @Sendable (inout Behaviour) -> Void) {
        state.withLock { change(&$0.behaviour) }
    }

    // MARK: - HTTPTransport

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard let url = request.url else { throw URLError(.badURL) }
        let method = request.httpMethod ?? "GET"
        let path = url.path(percentEncoded: true)
        let behaviour = state.withLock { state in
            state.requests.append("\(method) \(path)")
            return state.behaviour
        }
        try await Task.sleep(for: latency)
        let origin = "\(url.scheme ?? "https")://\(url.host() ?? "")"
        if origin == Self.householdOrigin {
            guard behaviour.householdReachable else { throw URLError(.notConnectedToInternet) }
            return try await household(method: method, path: path, body: request.httpBody ?? Data(), behaviour: behaviour)
        }
        if origin == Self.syncEndpoint {
            guard behaviour.backupServiceReachable else { throw URLError(.notConnectedToInternet) }
            return try await backup(method: method, path: path, request: request, behaviour: behaviour)
        }
        throw URLError(.cannotFindHost)
    }

    // MARK: - Home server

    private func household(method: String, path: String, body: Data, behaviour: Behaviour) async throws -> HTTPResponse {
        switch (method, path) {
        case ("GET", "/v1/health"):
            return Self.json(200, #"{"ok":true,"contractVersion":1}"#)
        case ("POST", "/v1/pair"):
            let fields = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let secret = (fields?["bootstrapSecret"] as? String).map(normaliseCode) ?? ""
            guard secret == Self.householdCode else { return Self.json(401, #"{"error":"unauthorized"}"#) }
            let name = ((fields?["deviceName"] as? String) ?? "").jsTrimmed()
            let joinedAt = now()
            state.withLock { state in
                state.phones.removeAll { $0.id == Self.thisPhoneId }
                state.phones.append(HouseholdDevice(id: Self.thisPhoneId, name: name, createdAt: joinedAt, lastSeenAt: joinedAt))
            }
            return Self.json(200, #"{"token":"demo-session-token","deviceId":"\#(Self.thisPhoneId)","origin":"\#(Self.householdOrigin)","householdName":"Home","contractVersion":1}"#)
        case ("GET", "/v1/devices"):
            switch behaviour.devices {
            case .hang:
                try await Task.sleep(for: .seconds(3600))
                throw URLError(.timedOut)
            case .fail:
                return Self.json(500, #"{"error":"server_error"}"#)
            case .answer:
                let phones = state.withLock { $0.phones }
                let entries = phones.map { phone in
                    let lastSeen = phone.lastSeenAt.map(String.init) ?? "null"
                    return #"{"id":"\#(phone.id)","name":"\#(Self.escaped(phone.name))","createdAt":\#(phone.createdAt),"lastSeenAt":\#(lastSeen)}"#
                }
                return Self.json(200, #"{"devices":[\#(entries.joined(separator: ","))]}"#)
            }
        case ("POST", "/v1/import"):
            let dump = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let items = (dump?["items"] as? [Any])?.count ?? 0
            let photos = (dump?["photos"] as? [Any])?.count ?? 0
            return Self.json(200, #"{"ok":true,"items":\#(items),"photos":\#(photos)}"#)
        default:
            if method == "DELETE", path.hasPrefix("/v1/devices/") {
                let id = String(path.dropFirst("/v1/devices/".count)).removingPercentEncoding ?? ""
                let removed = state.withLock { state in
                    let before = state.phones.count
                    state.phones.removeAll { $0.id == id }
                    return state.phones.count < before
                }
                return removed ? HTTPResponse(status: 204) : Self.json(404, #"{"error":"not_found"}"#)
            }
            if method == "PUT", path.hasPrefix("/v1/photos/") {
                return Self.json(201, #"{"ok":true}"#)
            }
            // Every list the other screens read: no keys read as empty lists.
            return Self.json(200, "{}")
        }
    }

    // MARK: - Backup service

    private func backup(method: String, path: String, request: URLRequest, behaviour: Behaviour) async throws -> HTTPResponse {
        if path.hasPrefix("/v1/photos/") {
            switch method {
            case "PUT": return Self.json(201, #"{"id":"\#(path.dropFirst("/v1/photos/".count))","size":\#(request.httpBody?.count ?? 0)}"#)
            case "DELETE": return HTTPResponse(status: 204)
            default: return Self.json(404, #"{"error":"Not found."}"#)
            }
        }
        switch (method, path) {
        case ("PUT", "/v1/backups"):
            if behaviour.backupsHang {
                try await Task.sleep(for: .seconds(3600))
                throw URLError(.timedOut)
            }
            let bytes = request.httpBody ?? Data()
            let schema = Int(request.value(forHTTPHeaderField: "x-snapshot-schema-version") ?? "") ?? 0
            let stored = StoredBackup(capturedAt: now(), schemaVersion: schema, bytes: bytes)
            state.withLock { $0.backups.append(stored) }
            return Self.json(201, Self.summary(stored))
        case ("GET", "/v1/backups"):
            let backups = state.withLock { $0.backups }
            let entries = backups.reversed().map(Self.summary)
            return Self.json(200, #"{"contractVersion":1,"backups":[\#(entries.joined(separator: ","))]}"#)
        case ("GET", "/v1/backups/latest"):
            guard let newest = state.withLock({ $0.backups.last }) else {
                return Self.json(404, #"{"error":"No backups yet."}"#)
            }
            let bytes: Data
            if let stored = newest.bytes {
                bytes = stored
            } else {
                bytes = try await savedInventory()
            }
            return HTTPResponse(
                status: 200,
                headers: ["Content-Type": "application/vnd.sqlite3", "x-snapshot-schema-version": String(newest.schemaVersion)],
                body: bytes
            )
        default:
            return Self.json(404, #"{"error":"Not found."}"#)
        }
    }

    // MARK: - Wire

    private static func summary(_ backup: StoredBackup) -> String {
        #"{"id":"\#(backup.capturedAt)","size":\#(backup.bytes?.count ?? 0),"capturedAt":\#(backup.capturedAt),"schemaVersion":\#(backup.schemaVersion)}"#
    }

    private static func json(_ status: Int, _ body: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
