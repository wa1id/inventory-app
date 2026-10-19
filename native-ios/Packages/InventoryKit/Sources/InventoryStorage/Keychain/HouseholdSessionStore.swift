import Foundation
import InventoryCore

/// The household session as persisted in the keychain under `household.session.v1` (04 §5):
/// the device's bearer token for the home server and the names shown in Settings.
public struct StoredHouseholdSession: Sendable, Equatable, Hashable {
    public var origin: String
    public var token: String
    public var deviceId: String
    public var deviceName: String
    public var householdName: String

    public init(origin: String, token: String, deviceId: String, deviceName: String, householdName: String) {
        self.origin = origin
        self.token = token
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.householdName = householdName
    }

    /// The fallbacks `loadHouseholdSession` applies. Hard-coded English in RN, not copy keys
    /// (DECISIONS U9). RN: src/services/household/session.ts:23-24.
    static let defaultDeviceName = "This phone"
    static let defaultHouseholdName = "Home"

    /// Decodes a stored value with RN's rules: it must parse as JSON with string `origin`,
    /// `token` and `deviceId`; a non-string `deviceName` becomes "This phone" and a non-string
    /// `householdName` becomes "Home"; anything else, including an empty value, is nil.
    /// RN: src/services/household/session.ts:7-29.
    public static func decode(_ stored: String?) -> StoredHouseholdSession? {
        guard let stored, !stored.isEmpty else { return nil }
        guard case .object(let object)? = JSONValue.parse(stored),
              case .string(let origin)? = object["origin"],
              case .string(let token)? = object["token"],
              case .string(let deviceId)? = object["deviceId"]
        else { return nil }
        var deviceName = defaultDeviceName
        if case .string(let name)? = object["deviceName"] { deviceName = name }
        var householdName = defaultHouseholdName
        if case .string(let name)? = object["householdName"] { householdName = name }
        return StoredHouseholdSession(
            origin: origin, token: token, deviceId: deviceId,
            deviceName: deviceName, householdName: householdName)
    }

    /// `JSON.stringify(session)` byte for byte, keys in the order `origin, token, deviceId,
    /// deviceName, householdName` (RN: session.ts:31-33, client.ts:94-100), so an RN TestFlight
    /// build installed over this one reads it unchanged.
    public var jsonString: String {
        let fields = [
            ("origin", origin), ("token", token), ("deviceId", deviceId),
            ("deviceName", deviceName), ("householdName", householdName),
        ]
        return "{" + fields.map { "\(JSONValue.quote($0.0)):\(JSONValue.quote($0.1))" }.joined(separator: ",") + "}"
    }
}

extension StoredHouseholdSession: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Leaves the device token out of `print`, `dump`, string interpolation and logs, like
    /// `HouseholdPairing` and `HouseholdClient` do.
    public var description: String {
        "HouseholdSession(origin: \(origin), deviceId: \(deviceId), householdName: \(householdName))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["origin": origin, "deviceId": deviceId, "deviceName": deviceName, "householdName": householdName])
    }
}

/// Reads and writes the household session item with RN's error handling.
public struct HouseholdSessionStore: Sendable {
    private let keychain: any KeychainStore

    public init(keychain: any KeychainStore) {
        self.keychain = keychain
    }

    /// The session, or nil when there is none, it does not decode, or the keychain read failed.
    /// A corrupt item reads as "not joined" but is not deleted (RN: session.ts:7-29).
    public func load() -> StoredHouseholdSession? {
        try? loadReportingErrors()
    }

    /// Like ``load()``, but a keychain failure throws instead of reading as "not joined", for a
    /// caller that wants to wait for protected data rather than run a paired phone as local
    /// (09 §3.2, 02 §4.4).
    public func loadReportingErrors() throws(KeychainError) -> StoredHouseholdSession? {
        StoredHouseholdSession.decode(try keychain.string(forKey: KeychainKey.householdSession))
    }

    /// Persists the session. Errors propagate, so a failed save fails the join (RN: session.ts:31-33).
    public func save(_ session: StoredHouseholdSession) throws(KeychainError) {
        try keychain.set(session.jsonString, forKey: KeychainKey.householdSession)
    }

    /// Forgets the session. Errors are swallowed (RN: session.ts:35-41).
    public func clear() {
        keychain.delete(forKey: KeychainKey.householdSession)
    }
}
