import Foundation
import Security
import Testing
@testable import InventoryStorage

// The real keychain is exercised by the simulator-hosted AppTests/Adoption suite. These tests run
// on the macOS host and never touch the login keychain.

@Suite("ExpoCompatibleKeychain coordinates")
struct ExpoCompatibleKeychainQueryTests {
    @Test("the query dictionary has exactly four keys, Data account and generic, service app:no-auth")
    func noAuthQuery() throws {
        let query = ExpoCompatibleKeychain.query(forKey: KeychainKey.householdSession, service: .noAuth)
        #expect(query.count == 4)
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "app:no-auth")
        let account = try #require(query[kSecAttrAccount as String] as? Data)
        let generic = try #require(query[kSecAttrGeneric as String] as? Data)
        #expect(account == Data("household.session.v1".utf8))
        #expect(generic == account)
        // A String account would be a different item; expo stored Data.
        #expect(query[kSecAttrAccount as String] as? String == nil)
        #expect(query[kSecAttrAccessGroup as String] == nil)
        #expect(query[kSecAttrSynchronizable as String] == nil)
    }

    @Test("the three services are expo's", arguments: [
        (ExpoCompatibleKeychain.Service.noAuth, "app:no-auth"),
        (.auth, "app:auth"),
        (.legacy, "app"),
    ])
    func services(service: ExpoCompatibleKeychain.Service, raw: String) {
        let query = ExpoCompatibleKeychain.query(forKey: KeychainKey.recoveryCode, service: service)
        #expect(query[kSecAttrService as String] as? String == raw)
    }

    @Test("account bytes match the hex in 02 §4.2", arguments: [
        (KeychainKey.recoveryCode, "73796e632e6163636f756e745365637265742e7631"),
        (KeychainKey.householdSession, "686f757365686f6c642e73657373696f6e2e7631"),
    ])
    func accountBytes(key: String, hex: String) throws {
        let query = ExpoCompatibleKeychain.query(forKey: key, service: .noAuth)
        let account = try #require(query[kSecAttrAccount as String] as? Data)
        #expect(account.map { String(format: "%02x", $0) }.joined() == hex)
    }

    @Test("keys expo-secure-store rejects are refused before the keychain is touched", arguments: [
        "", " ", "has space", "slash/key", "ключ", "tab\tkey",
    ])
    func invalidKeys(key: String) {
        let keychain = ExpoCompatibleKeychain()
        #expect(throws: KeychainError.invalidKey) { try keychain.string(forKey: key) }
        #expect(throws: KeychainError.invalidKey) { try keychain.set("x", forKey: key) }
        keychain.delete(forKey: key)  // a no-op, never a crash
    }

    @Test("the app's keys are valid", arguments: [KeychainKey.recoveryCode, KeychainKey.householdSession, "a_b-c.d"])
    func validKeys(key: String) {
        #expect(KeychainKey.isValid(key))
    }
}

@Suite("InMemoryKeychain")
struct InMemoryKeychainTests {
    @Test("fail-next switches fail exactly once")
    func failSwitches() throws {
        let keychain = InMemoryKeychain(["k": "v"])
        keychain.failNextRead()
        #expect(throws: InMemoryKeychain.simulatedFailure) { try keychain.string(forKey: "k") }
        #expect(try keychain.string(forKey: "k") == "v")

        keychain.failNextWrite()
        #expect(throws: InMemoryKeychain.simulatedFailure) { try keychain.set("w", forKey: "k") }
        #expect(keychain.values == ["k": "v"])
        try keychain.set("w", forKey: "k")
        #expect(keychain.values == ["k": "w"])

        keychain.delete(forKey: "k")
        #expect(try keychain.string(forKey: "k") == nil)
    }
}
