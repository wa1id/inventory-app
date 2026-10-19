import Foundation
import Testing
@testable import InventoryStorage

/// RN has no tests for `session.ts`; these pin its rules (02 §11.2 #5) and the parity vectors
/// produced by the real `loadHouseholdSession` / `saveHouseholdSession`.
@Suite("HouseholdSessionStore")
struct HouseholdSessionStoreTests {
    struct Session: Decodable, Equatable {
        let origin, token, deviceId, deviceName, householdName: String
    }

    struct Vectors: Decodable {
        struct Decode: Decodable { let input: String; let expected: Session? }
        struct Encode: Decodable { let session: Session; let json: String }
        let decode: [Decode]
        let encode: [Encode]
    }

    static func vectors() throws -> Vectors {
        try AdoptionFixtures.decode(Vectors.self, from: "household-session-vectors.json")
    }

    static func stored(_ session: Session) -> StoredHouseholdSession {
        StoredHouseholdSession(
            origin: session.origin, token: session.token, deviceId: session.deviceId,
            deviceName: session.deviceName, householdName: session.householdName)
    }

    @Test("decodes exactly like loadHouseholdSession (TS vectors)")
    func decodeVectors() throws {
        for vector in try Self.vectors().decode {
            let stored: String? = vector.input == "<absent>" ? nil : vector.input
            let keychain = InMemoryKeychain(stored.map { [KeychainKey.householdSession: $0] } ?? [:])
            let loaded = HouseholdSessionStore(keychain: keychain).load()
            #expect(loaded == vector.expected.map(Self.stored), "input: \(vector.input)")
        }
    }

    @Test("encodes exactly like JSON.stringify(session) (TS vectors)")
    func encodeVectors() throws {
        for vector in try Self.vectors().encode {
            #expect(Self.stored(vector.session).jsonString == vector.json)
            let keychain = InMemoryKeychain()
            try HouseholdSessionStore(keychain: keychain).save(Self.stored(vector.session))
            #expect(keychain.values[KeychainKey.householdSession] == vector.json)
            #expect(HouseholdSessionStore(keychain: keychain).load() == Self.stored(vector.session))
        }
    }

    @Test("missing names fall back to the hard-coded RN literals; missing or non-string ids are no session")
    func specCases() {
        func decode(_ json: String) -> StoredHouseholdSession? { StoredHouseholdSession.decode(json) }
        #expect(decode(#"{"origin":"o","token":"t","deviceId":"d","householdName":"H"}"#)?.deviceName == "This phone")
        #expect(decode(#"{"origin":"o","token":"t","deviceId":"d","deviceName":"N"}"#)?.householdName == "Home")
        #expect(decode(#"{"origin":"o","deviceId":"d"}"#) == nil)
        #expect(decode(#"{"origin":"o","token":"t","deviceId":7}"#) == nil)
        #expect(decode("{nope") == nil)
        #expect(decode("") == nil)
        #expect(StoredHouseholdSession.decode(nil) == nil)
        // JSON.parse does not skip a byte-order mark.
        #expect(decode("\u{FEFF}{\"origin\":\"o\",\"token\":\"t\",\"deviceId\":\"d\"}") == nil)
    }

    @Test("writes the keys in the order origin, token, deviceId, deviceName, householdName")
    func keyOrder() {
        let session = StoredHouseholdSession(
            origin: "https://inventory.wystudio.be", token: "tok", deviceId: "dev", deviceName: "Phone",
            householdName: "Home")
        #expect(session.jsonString
            == #"{"origin":"https://inventory.wystudio.be","token":"tok","deviceId":"dev","deviceName":"Phone","householdName":"Home"}"#)
    }

    @Test("a keychain read failure reads as not joined, without deleting the item")
    func readFailure() throws {
        let session = StoredHouseholdSession(origin: "o", token: "t", deviceId: "d", deviceName: "n", householdName: "h")
        let keychain = InMemoryKeychain([KeychainKey.householdSession: session.jsonString])
        let store = HouseholdSessionStore(keychain: keychain)
        keychain.failNextRead()
        #expect(store.load() == nil)
        #expect(store.load() == session)
        keychain.failNextRead()
        #expect(throws: KeychainError.self) { try store.loadReportingErrors() }
    }

    @Test("a corrupt item reads as not joined but is kept")
    func corruptKept() {
        let keychain = InMemoryKeychain([KeychainKey.householdSession: "garbage"])
        #expect(HouseholdSessionStore(keychain: keychain).load() == nil)
        #expect(keychain.values[KeychainKey.householdSession] == "garbage")
    }

    @Test("save propagates a keychain failure; clear removes the item")
    func saveAndClear() throws {
        let keychain = InMemoryKeychain([KeychainKey.recoveryCode: "code"])
        let store = HouseholdSessionStore(keychain: keychain)
        let session = StoredHouseholdSession(origin: "o", token: "t", deviceId: "d", deviceName: "n", householdName: "h")
        keychain.failNextWrite()
        #expect(throws: KeychainError.self) { try store.save(session) }
        try store.save(session)
        store.clear()
        #expect(store.load() == nil)
        #expect(keychain.values == [KeychainKey.recoveryCode: "code"])
    }
}
