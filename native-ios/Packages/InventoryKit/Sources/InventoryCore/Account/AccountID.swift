import CryptoKit
import Foundation

/// Account id = the first 128 bits of SHA-256 over the secret, as 32 lowercase hex characters
/// (RN `deriveAccountId`; must match `worker/src/auth.ts`).
///
/// The server derives it from the bearer code and uses it as a storage prefix;
/// the app never sends or stores it.
public func deriveAccountId(_ secret: some Sequence<UInt8>) -> String {
    let digest = SHA256.hash(data: Data(secret))
    return toHex(digest.prefix(16))
}
