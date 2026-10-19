import Foundation

/// A string-valued secure store keyed by name, with expo-secure-store's semantics.
///
/// The live implementation is ``ExpoCompatibleKeychain``; tests use ``InMemoryKeychain``.
public protocol KeychainStore: Sendable {
    /// The stored value, or nil when there is none. Throws when the keychain refuses the read
    /// (for example while the device is locked).
    func string(forKey key: String) throws(KeychainError) -> String?
    /// Stores `value` under `key`, replacing any existing value.
    func set(_ value: String, forKey key: String) throws(KeychainError)
    /// Removes every stored variant of `key`. Never fails, like expo's delete.
    func delete(forKey key: String)
}

/// Why a keychain call failed.
public enum KeychainError: Error, Equatable, Sendable {
    /// A Security framework status other than success or "not found".
    case status(Int32)
    /// The key is empty or contains characters expo-secure-store rejects.
    case invalidKey
}

/// The keychain items the React Native build wrote. The names are part of the on-device format.
public enum KeychainKey {
    /// The backup recovery code (03 §3.7). RN: src/services/account/identity.ts:30.
    public static let recoveryCode = "sync.accountSecret.v1"
    /// The household session JSON (04 §5). RN: src/services/household/session.ts:5.
    public static let householdSession = "household.session.v1"

    /// expo-secure-store's key rules: JS `/^[\w.-]+$/` (SecureStore.ts:237-239), then native
    /// "not empty after trimming" (SecureStoreModule.swift:213-219), which the JS rule implies.
    static func isValid(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "_", ".", "-": true
            default: false
            }
        }
    }
}
