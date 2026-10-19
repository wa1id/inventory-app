#if canImport(Security)
import Security
#endif

// RN: src/core/id.ts. Entity ids and QR tokens come from a CSPRNG. RN injects
// the source at process start and throws when none is installed; natively the
// system CSPRNG is always available, and tests pass their own source.

/// A source of random bytes. Production code uses ``SystemRandomByteSource``; tests inject fixed bytes.
public protocol RandomByteSource: Sendable {
    /// Returns exactly `count` random bytes.
    func randomBytes(count: Int) -> [UInt8]
}

/// The system CSPRNG (`SystemRandomNumberGenerator`, which is `arc4random_buf` on Apple platforms).
public struct SystemRandomByteSource: RandomByteSource {
    public init() {}

    public func randomBytes(count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        while bytes.count < count {
            var word = generator.next()
            for _ in 0..<min(8, count - bytes.count) {
                bytes.append(UInt8(truncatingIfNeeded: word))
                word >>= 8
            }
        }
        return bytes
    }
}

/// A new entity id: RFC 4122 version-4 layout, lowercase, `8-4-4-4-12` (RN `newId`).
///
/// Bytes 0…15 give `00010203-0405-4607-8809-0a0b0c0d0e0f`.
public func newId(using source: some RandomByteSource) -> String {
    var bytes = source.randomBytes(count: 16)
    bytes[6] = (bytes[6] & 0x0F) | 0x40
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    let hex = Array(toHex(bytes).unicodeScalars)
    var out = String.UnicodeScalarView()
    for (index, scalar) in hex.enumerated() {
        if index == 8 || index == 12 || index == 16 || index == 20 { out.append("-") }
        out.append(scalar)
    }
    return String(out)
}

/// A new entity id from the system CSPRNG (RN `newId`).
public func newId() -> String {
    newId(using: SystemRandomByteSource())
}

/// An opaque QR token: 16 random bytes as 32 lowercase hex characters (RN `newQrToken`).
public func newQrToken(using source: some RandomByteSource) -> String {
    toHex(source.randomBytes(count: 16))
}

/// An opaque QR token from the system CSPRNG (RN `newQrToken`).
public func newQrToken() -> String {
    newQrToken(using: SystemRandomByteSource())
}

#if canImport(Security)
/// `SecRandomCopyBytes`, for secrets that must fail loudly rather than degrade (03 §3.7, the recovery code).
public enum SecureRandom {
    /// `SecRandomCopyBytes` returned something other than `errSecSuccess`.
    public struct Failure: Error, Sendable, Equatable {
        public let status: OSStatus
    }

    /// Returns `count` bytes from `SecRandomCopyBytes`, or throws; never falls back to a weaker source.
    public static func bytes(count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecSuccess }
            return SecRandomCopyBytes(nil, count, base)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return bytes
    }
}
#endif
