import Foundation
import InventoryCore
import InventoryStorage
import Security

// RN: src/services/account/identity.ts (03 §3.6-3.7).
//
// There is no account system: "Turn on backup" generates 16 CSPRNG bytes, keeps them in the
// keychain as a 26-character Crockford base32 recovery code, and the Worker hashes that code
// into an account id. Holding the code *is* being the account, so losing it, overwriting it or
// minting a second one strands every backup written under it.

/// The device's claim on its own backups (RN `Account`).
///
/// `description`, `debugDescription` and the mirror leave both fields out: the code is the bearer
/// credential and must never reach a log line (RN src/services/sync/client.ts:20-30), and the
/// account id is never sent or logged either (03 §3.6).
public struct SyncAccount: Sendable, Hashable {
    /// 32 lowercase hex characters: the first 128 bits of SHA-256 over the secret. Derived,
    /// never stored; the app only compares it.
    public let id: String
    /// The code exactly as stored: 26 unformatted characters for every code this app writes.
    public let recoveryCode: String

    public init(id: String, recoveryCode: String) {
        self.id = id
        self.recoveryCode = recoveryCode
    }

    /// The account a stored code stands for, or nil when it does not decode to exactly 16 bytes
    /// (RN identity.ts:63-68). The code is kept as stored, not re-canonicalised.
    public init?(storedCode: String) {
        guard !storedCode.isEmpty, let secret = RecoveryCode.secret(from: storedCode) else { return nil }
        self.init(id: deriveAccountId(secret), recoveryCode: storedCode)
    }
}

extension SyncAccount: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "SyncAccount(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// What the keychain says about this device's account (03 B8).
///
/// RN folded a failed read into "no account" (identity.ts:52-61), and the Backup screen then
/// offered Turn on and Restore, both of which overwrote the hidden code (and a failed restore
/// deleted it). Natively an unreadable keychain is its own state, in which nothing writes or
/// deletes the item.
public enum SyncAccountLookup: Sendable, Equatable {
    /// A stored code that decodes to 16 bytes.
    case found(SyncAccount)
    /// Nothing stored, an empty value, or a value that does not decode to 16 bytes.
    case absent
    /// The keychain refused the read (for example `errSecInteractionNotAllowed` while protected
    /// data is unavailable). A code may well be there.
    case unreadable(KeychainError)
}

/// Why ``SyncAccountStore/create()`` made no account.
public enum SyncAccountError: Error, Sendable, Equatable {
    /// The keychain could not be read, so a code may exist; nothing was written (03 B8).
    case keychainUnreadable(KeychainError)
    /// The new code could not be stored (RN: the `setItemAsync` throw, identity.ts:82).
    case keychainWriteFailed(KeychainError)
    /// `SecRandomCopyBytes` failed. There is never a weaker fallback (03 §3.7).
    case randomUnavailable(Int32)
}

/// Why ``SyncAccountStore/importAccount(_:)`` adopted nothing (RN `ImportResult` failures).
public enum SyncAccountImportFailure: Error, Sendable, Equatable {
    /// The code does not decode to exactly 16 bytes. Nothing was written.
    case malformed
    /// The keychain could not be written, or could not be read first (03 B8). Nothing was written.
    case unavailable
}

/// The recovery-code account on this device: create, adopt, load and forget (RN identity.ts).
///
/// Keychain coordinates and RN's error mapping live in ``RecoveryCodeStore``; this type adds the
/// codec, the CSPRNG and the account id. Every method is synchronous keychain I/O; call them off
/// the main actor (``SyncCoordinator`` does).
public struct SyncAccountStore: Sendable {
    /// Source of secret bytes; throws rather than ever returning weaker randomness.
    public typealias RandomBytes = @Sendable (_ count: Int) throws -> [UInt8]

    private let codes: RecoveryCodeStore
    private let randomBytes: RandomBytes

    public init(codes: RecoveryCodeStore, randomBytes: @escaping RandomBytes = SyncAccountStore.secureRandomBytes) {
        self.codes = codes
        self.randomBytes = randomBytes
    }

    public init(keychain: any KeychainStore, randomBytes: @escaping RandomBytes = SyncAccountStore.secureRandomBytes) {
        self.init(codes: RecoveryCodeStore(keychain: keychain), randomBytes: randomBytes)
    }

    /// RN `loadAccount()`: the account, or nil when there is none, it does not decode, or the
    /// keychain read failed. Use ``lookup()`` to tell the last case apart.
    public func load() -> SyncAccount? {
        if case .found(let account) = lookup() { return account }
        return nil
    }

    /// The account, its absence, or an unreadable keychain (03 B8).
    public func lookup() -> SyncAccountLookup {
        do {
            guard let stored = try codes.loadReportingErrors(), let account = SyncAccount(storedCode: stored) else {
                return .absent
            }
            return .found(account)
        } catch {
            return .unreadable(error)
        }
    }

    /// RN `createAccount()`: a fresh 16-byte secret, stored as its canonical code.
    ///
    /// Unlike RN it never overwrites a real code (03 B8): when the keychain cannot be read it
    /// throws without writing, and when an account is already stored it returns that account
    /// instead of minting a second one over it. RN only offered Turn on with no account loaded,
    /// so a stored account here means the earlier read failed or has not finished.
    public func create() throws(SyncAccountError) -> SyncAccount {
        switch lookup() {
        case .found(let existing):
            return existing
        case .unreadable(let error):
            throw .keychainUnreadable(error)
        case .absent:
            break
        }
        let secret: [UInt8]
        do {
            secret = try randomBytes(RecoveryCode.secretByteCount)
        } catch let error as SyncAccountError {
            throw error
        } catch {
            throw .randomUnavailable(errSecParam)
        }
        guard secret.count == RecoveryCode.secretByteCount else { throw .randomUnavailable(errSecParam) }
        let code = CrockfordBase32.encode(secret)
        do {
            try codes.save(code)
        } catch {
            throw .keychainWriteFailed(error)
        }
        return SyncAccount(id: deriveAccountId(secret), recoveryCode: code)
    }

    /// RN `importAccount(code)`: adopts a typed code, storing its canonical form.
    ///
    /// Forgiving about shape (case, hyphens, surrounding white space, I/L/O look-alikes), strict
    /// about length. With an unreadable keychain nothing is written and the result is
    /// `.unavailable` (03 B8); RN wrote over whatever it could not read.
    public func importAccount(_ code: String) -> Result<SyncAccount, SyncAccountImportFailure> {
        guard let secret = RecoveryCode.secret(from: code) else { return .failure(.malformed) }
        if case .unreadable = lookup() { return .failure(.unavailable) }
        let canonical = CrockfordBase32.encode(secret)
        do {
            try codes.save(canonical)
        } catch {
            return .failure(.unavailable)
        }
        return .success(SyncAccount(id: deriveAccountId(secret), recoveryCode: canonical))
    }

    /// Stores `account`'s code (already canonical), overwriting what is there. Throws when the
    /// keychain refuses.
    func save(_ account: SyncAccount) throws(KeychainError) {
        try codes.save(account.recoveryCode)
    }

    /// RN `forgetAccount()`: deletes the code. Errors are swallowed. The server is not touched.
    public func forget() {
        codes.forget()
    }

    /// `SecRandomCopyBytes`, throwing ``SyncAccountError/randomUnavailable(_:)`` on failure
    /// (RN `getRandomBytesAsync`, never the sync variant with its `Math.random` fallback).
    public static let secureRandomBytes: RandomBytes = { count in
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else { throw SyncAccountError.randomUnavailable(status) }
        return bytes
    }
}
