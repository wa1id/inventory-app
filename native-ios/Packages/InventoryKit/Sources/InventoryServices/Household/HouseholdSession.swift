import InventoryCore
import InventoryNetwork
import InventoryStorage

/// This phone's membership of the household: where the home server is, the device's bearer
/// token, and the two names the screens show (RN `HouseholdSession`, src/services/household/client.ts:62-68).
///
/// One type from the keychain to the screens. InventoryStorage's ``StoredHouseholdSession``
/// already carries session.ts's rules: it decodes `household.session.v1` (string `origin`,
/// `token` and `deviceId` required; `deviceName` defaults to the literal "This phone" and
/// `householdName` to "Home") and writes the same JSON the Expo build wrote, so a phone paired
/// by the RN build stays paired and an RN TestFlight build installed over this one still reads
/// the item (04 §5). A pairing (``HouseholdPairing``) becomes a session through
/// ``StoredHouseholdSession/init(pairing:)``.
///
/// Once paired, every household request goes to `origin` (the server's own answer to pairing),
/// never to the build's `AppConfig.householdOrigin`, which is only the pairing target.
public typealias HouseholdSession = StoredHouseholdSession

extension StoredHouseholdSession {
    /// The session a successful `POST /v1/pair` starts (RN `pairWithHousehold`'s result,
    /// client.ts:94-100): the server's origin without trailing slashes, the typed name trimmed,
    /// the household's name or "Home". ``HouseholdClient/pair(bootstrapSecret:deviceName:)``
    /// has already applied those rules.
    public init(pairing: HouseholdPairing) {
        self.init(
            origin: pairing.origin,
            token: pairing.token,
            deviceId: pairing.deviceId,
            deviceName: pairing.deviceName,
            householdName: pairing.householdName
        )
    }
}

extension HouseholdClient {
    /// This client's transport, reachability hub, clock and telemetry, aimed at the session's
    /// origin with its token: what every paired request goes through.
    public func forSession(_ session: HouseholdSession) -> HouseholdClient {
        withSession(origin: session.origin, token: session.token)
    }
}
