import Foundation

/// The keychain half of the backup account (03 §3.7): the recovery code stored under
/// `sync.accountSecret.v1` as the 26-character canonical Crockford base32 string.
///
/// This type keeps RN's keychain error mapping. The account layer still decodes what ``load()``
/// returns and treats anything that does not decode to exactly 16 bytes as "no account"
/// (RN: src/services/account/identity.ts:64-66), and stores only canonical codes.
public struct RecoveryCodeStore: Sendable {
    private let keychain: any KeychainStore

    public init(keychain: any KeychainStore) {
        self.keychain = keychain
    }

    /// The stored code exactly as written, or nil when there is none or it is empty.
    /// Any keychain error also reads as nil: an unreadable keystore must never look like an
    /// invitation to mint a second account (RN: identity.ts:52-63).
    public func load() -> String? {
        try? loadReportingErrors()
    }

    /// Like ``load()``, but a keychain failure throws instead of reading as "no code", for a
    /// caller that wants to wait for protected data rather than treat the account as absent
    /// (09 §3.2).
    public func loadReportingErrors() throws(KeychainError) -> String? {
        guard let stored = try keychain.string(forKey: KeychainKey.recoveryCode), !stored.isEmpty else {
            return nil
        }
        return stored
    }

    /// Stores `code`, overwriting any existing one. Throws when the keychain refuses, so
    /// `createAccount` can propagate it and `importAccount` can report `unavailable`
    /// (RN: identity.ts:78-85, 104-108).
    public func save(_ code: String) throws(KeychainError) {
        try keychain.set(code, forKey: KeychainKey.recoveryCode)
    }

    /// Detaches this device from its account. Errors are swallowed (RN: identity.ts:115-121).
    public func forget() {
        keychain.delete(forKey: KeychainKey.recoveryCode)
    }
}
