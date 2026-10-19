import Foundation
import Security
import Testing
import InventoryStorage

/// expo-secure-store 57.0.1's keychain code with the default options the RN app always used
/// (`{}`: keychainService nil → "app", requireAuthentication false, keychainAccessible
/// .whenUnlocked, no access group, no prompt), copied from
/// node_modules/expo-secure-store/ios/SecureStoreModule.swift:43-51, 69-192.
private enum ExpoSecureStore {
    struct KeyChainException: Error { let status: OSStatus }

    // query(with:options:requireAuthentication:) (:172-192)
    static func query(with key: String, requireAuthentication: Bool? = nil) -> [String: Any] {
        var service = "app"
        if let requireAuthentication {
            service.append(":\(requireAuthentication ? "auth" : "no-auth")")
        }
        let encodedKey = Data(key.utf8)
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrGeneric as String: encodedKey,
            kSecAttrAccount as String: encodedKey,
        ]
    }

    // get(with:options:) (:69-87)
    static func get(_ key: String) throws -> String? {
        if let item = try searchKeyChain(key, requireAuthentication: false) {
            return String(data: item, encoding: .utf8)
        }
        if let item = try searchKeyChain(key, requireAuthentication: true) {
            return String(data: item, encoding: .utf8)
        }
        if let item = try searchKeyChain(key) {
            return String(data: item, encoding: .utf8)
        }
        return nil
    }

    // set(value:with:options:) (:89-125) and update (:127-144)
    static func set(_ value: String, _ key: String) throws {
        var setItemQuery = query(with: key, requireAuthentication: false)
        // expo writes value.data(using: .utf8), which never fails for a Swift String.
        setItemQuery[kSecValueData as String] = Data(value.utf8)
        setItemQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(setItemQuery as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            SecItemDelete(query(with: key) as CFDictionary)
            SecItemDelete(query(with: key, requireAuthentication: true) as CFDictionary)
        case errSecDuplicateItem:
            let updateDictionary = [kSecValueData as String: Data(value.utf8)]
            let updated = SecItemUpdate(
                query(with: key, requireAuthentication: false) as CFDictionary, updateDictionary as CFDictionary)
            guard updated == errSecSuccess else { throw KeyChainException(status: updated) }
        default:
            throw KeyChainException(status: status)
        }
    }

    // deleteValueWithKeyAsync (:43-51)
    static func delete(_ key: String) {
        SecItemDelete(query(with: key) as CFDictionary)
        SecItemDelete(query(with: key, requireAuthentication: true) as CFDictionary)
        SecItemDelete(query(with: key, requireAuthentication: false) as CFDictionary)
    }

    // searchKeyChain(with:options:requireAuthentication:) (:146-170)
    static func searchKeyChain(_ key: String, requireAuthentication: Bool? = nil) throws -> Data? {
        var query = query(with: key, requireAuthentication: requireAuthentication)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = kCFBooleanTrue
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw KeyChainException(status: status)
        }
    }

    /// Adds an item under one exact service, the way an older expo-secure-store would have.
    static func seed(_ value: String, _ key: String, service: String) -> OSStatus {
        var add = query(with: key)
        add[kSecAttrService as String] = service
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil)
    }

    /// The stored attributes of the one item under `service`, or nil.
    static func attributes(_ key: String, service: String) -> [String: Any]? {
        var query = query(with: key)
        query[kSecAttrService as String] = service
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? [String: Any]
    }

    static func count(_ key: String) -> Int {
        ["app", "app:auth", "app:no-auth"].filter { attributes(key, service: $0) != nil }.count
    }
}

/// The real keychain on the simulator: items written exactly as expo-secure-store writes them are
/// read by ``ExpoCompatibleKeychain``, and the reverse (02 §11.2 #3, 00-index risk 3).
@Suite("Expo keychain interop", .serialized)
struct ExpoKeychainInteropTests {
    static let keys = [KeychainKey.recoveryCode, KeychainKey.householdSession, "adoption.test.v1"]

    init() {
        for key in Self.keys { ExpoSecureStore.delete(key) }
    }

    @Test("items written by expo-secure-store are read in place")
    func expoWritesNativeReads() throws {
        let session = StoredHouseholdSession(
            origin: "https://inventory.wystudio.be", token: "tok-123", deviceId: "dev-1",
            deviceName: "Anna’s iPhone", householdName: "Home")
        try ExpoSecureStore.set("89144GJ289144GJ289144GJ288", KeychainKey.recoveryCode)
        try ExpoSecureStore.set(session.jsonString, KeychainKey.householdSession)

        let keychain = ExpoCompatibleKeychain()
        #expect(try keychain.string(forKey: KeychainKey.recoveryCode) == "89144GJ289144GJ289144GJ288")
        #expect(RecoveryCodeStore(keychain: keychain).load() == "89144GJ289144GJ289144GJ288")
        #expect(HouseholdSessionStore(keychain: keychain).load() == session)
        for key in Self.keys { ExpoSecureStore.delete(key) }
    }

    @Test("items written natively are read by expo-secure-store")
    func nativeWritesExpoReads() throws {
        let keychain = ExpoCompatibleKeychain()
        try RecoveryCodeStore(keychain: keychain).save("041061050R3GG28A1C60T3GF20")
        let session = StoredHouseholdSession(
            origin: "http://192.168.1.5:8788", token: "t", deviceId: "d", deviceName: "Kitchen iPad",
            householdName: "Café")
        try HouseholdSessionStore(keychain: keychain).save(session)

        #expect(try ExpoSecureStore.get(KeychainKey.recoveryCode) == "041061050R3GG28A1C60T3GF20")
        #expect(try ExpoSecureStore.get(KeychainKey.householdSession) == session.jsonString)
        for key in Self.keys { ExpoSecureStore.delete(key) }
    }

    @Test("native items carry expo's attributes: Data account and generic, app:no-auth, WhenUnlocked")
    func attributes() throws {
        try ExpoCompatibleKeychain().set("value", forKey: "adoption.test.v1")
        let attributes = try #require(ExpoSecureStore.attributes("adoption.test.v1", service: "app:no-auth"))
        #expect(attributes[kSecAttrAccount as String] as? Data == Data("adoption.test.v1".utf8))
        #expect(attributes[kSecAttrGeneric as String] as? Data == Data("adoption.test.v1".utf8))
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlocked as String)
        #expect(ExpoSecureStore.count("adoption.test.v1") == 1)
        ExpoSecureStore.delete("adoption.test.v1")
    }

    @Test("a second write takes the update path in both directions and keeps one item")
    func updatePath() throws {
        let keychain = ExpoCompatibleKeychain()
        try ExpoSecureStore.set("first", "adoption.test.v1")
        try keychain.set("second", forKey: "adoption.test.v1")
        #expect(try ExpoSecureStore.get("adoption.test.v1") == "second")
        try keychain.set("third", forKey: "adoption.test.v1")
        #expect(try keychain.string(forKey: "adoption.test.v1") == "third")
        try ExpoSecureStore.set("fourth", "adoption.test.v1")
        #expect(try keychain.string(forKey: "adoption.test.v1") == "fourth")
        #expect(ExpoSecureStore.count("adoption.test.v1") == 1)
        let attributes = try #require(ExpoSecureStore.attributes("adoption.test.v1", service: "app:no-auth"))
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlocked as String)
        ExpoSecureStore.delete("adoption.test.v1")
    }

    @Test("an item under the legacy service app is still read, and a native write retires it")
    func legacyService() throws {
        #expect(ExpoSecureStore.seed("legacy", "adoption.test.v1", service: "app") == errSecSuccess)
        let keychain = ExpoCompatibleKeychain()
        #expect(try keychain.string(forKey: "adoption.test.v1") == "legacy")

        try keychain.set("current", forKey: "adoption.test.v1")
        #expect(ExpoSecureStore.attributes("adoption.test.v1", service: "app") == nil)
        #expect(try ExpoSecureStore.get("adoption.test.v1") == "current")
        ExpoSecureStore.delete("adoption.test.v1")
    }

    @Test("app:no-auth wins over the legacy service, as in expo's probe order")
    func probeOrder() throws {
        #expect(ExpoSecureStore.seed("legacy", "adoption.test.v1", service: "app") == errSecSuccess)
        #expect(ExpoSecureStore.seed("current", "adoption.test.v1", service: "app:no-auth") == errSecSuccess)
        #expect(try ExpoCompatibleKeychain().string(forKey: "adoption.test.v1") == "current")
        #expect(try ExpoSecureStore.get("adoption.test.v1") == "current")
        ExpoSecureStore.delete("adoption.test.v1")
    }

    @Test("delete removes every variant, and expo's delete removes native items")
    func deleteAllVariants() throws {
        for service in ["app", "app:auth", "app:no-auth"] {
            #expect(ExpoSecureStore.seed(service, "adoption.test.v1", service: service) == errSecSuccess)
        }
        #expect(ExpoSecureStore.count("adoption.test.v1") == 3)
        ExpoCompatibleKeychain().delete(forKey: "adoption.test.v1")
        #expect(ExpoSecureStore.count("adoption.test.v1") == 0)
        #expect(try ExpoCompatibleKeychain().string(forKey: "adoption.test.v1") == nil)

        try ExpoCompatibleKeychain().set("x", forKey: "adoption.test.v1")
        ExpoSecureStore.delete("adoption.test.v1")
        #expect(try ExpoCompatibleKeychain().string(forKey: "adoption.test.v1") == nil)
    }

    @Test("an item stored with a String account is a different item, invisible to both")
    func stringAccountIsDifferent() throws {
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app:no-auth",
            kSecAttrAccount as String: "adoption.test.v1",
            kSecValueData as String: Data("wrong".utf8),
        ]
        #expect(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
        #expect(try ExpoCompatibleKeychain().string(forKey: "adoption.test.v1") == nil)
        #expect(try ExpoSecureStore.get("adoption.test.v1") == nil)
        add.removeValue(forKey: kSecValueData as String)
        SecItemDelete(add as CFDictionary)
    }
}
