import Foundation
import Security

/// The keychain, read and written with exactly the coordinates expo-secure-store 57.0.1 uses
/// with default options, so the items the React Native build left behind are found in place and
/// an RN TestFlight build installed over this one still finds ours (DECISIONS D-3, 02 §4.3).
///
/// Generic password, service `app:no-auth`, account and generic attribute both `Data(key.utf8)`,
/// `kSecAttrAccessibleWhenUnlocked`, no access group, not synchronizable.
/// RN: node_modules/expo-secure-store/ios/SecureStoreModule.swift:43-51, 69-192.
public struct ExpoCompatibleKeychain: KeychainStore {
    /// The three services expo-secure-store knows. Only `noAuth` is ever written.
    public enum Service: String, CaseIterable, Sendable {
        case noAuth = "app:no-auth"
        case auth = "app:auth"
        case legacy = "app"
    }

    public init() {}

    /// expo's `query(with:options:requireAuthentication:)` with default options: exactly four
    /// attributes, the key as `Data` (not a String) in both account and generic.
    static func query(forKey key: String, service: Service) -> [String: Any] {
        let encodedKey = Data(key.utf8)
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.rawValue,
            kSecAttrGeneric as String: encodedKey,
            kSecAttrAccount as String: encodedKey,
        ]
    }

    /// Reads `app:no-auth`, then the legacy `app` service. `app:auth` items cannot exist (no call
    /// site ever passed `requireAuthentication`), and skipping that probe rules out a biometric
    /// prompt (02 §4.3). A status other than success or not-found throws at once, like expo.
    public func string(forKey key: String) throws(KeychainError) -> String? {
        guard KeychainKey.isValid(key) else { throw .invalidKey }
        for service in [Service.noAuth, .legacy] {
            var query = Self.query(forKey: key, service: service)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecReturnData as String] = kCFBooleanTrue
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                // A non-Data result moves on to the next service (SecureStoreModule.swift:157-161).
                guard let data = item as? Data else { continue }
                // Invalid UTF-8 reads as nil without trying further services (:73-75).
                return String(data: data, encoding: .utf8)
            case errSecItemNotFound:
                continue
            default:
                throw .status(status)
            }
        }
        return nil
    }

    /// `SecItemAdd` on `app:no-auth`; on success the legacy and `app:auth` variants are deleted;
    /// on a duplicate only `kSecValueData` is updated, leaving accessibility alone (:89-144).
    public func set(_ value: String, forKey key: String) throws(KeychainError) {
        guard KeychainKey.isValid(key) else { throw .invalidKey }
        let data = Data(value.utf8)
        var add = Self.query(forKey: key, service: .noAuth)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            SecItemDelete(Self.query(forKey: key, service: .legacy) as CFDictionary)
            SecItemDelete(Self.query(forKey: key, service: .auth) as CFDictionary)
        case errSecDuplicateItem:
            let update = [kSecValueData as String: data]
            let updated = SecItemUpdate(
                Self.query(forKey: key, service: .noAuth) as CFDictionary, update as CFDictionary)
            guard updated == errSecSuccess else { throw .status(updated) }
        default:
            throw .status(status)
        }
    }

    /// Deletes `app`, then `app:auth`, then `app:no-auth`, ignoring every status (:43-51).
    public func delete(forKey key: String) {
        guard KeychainKey.isValid(key) else { return }
        for service in [Service.legacy, .auth, .noAuth] {
            SecItemDelete(Self.query(forKey: key, service: service) as CFDictionary)
        }
    }
}
