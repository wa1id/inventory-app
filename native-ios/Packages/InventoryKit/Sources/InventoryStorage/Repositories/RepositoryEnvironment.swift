import InventoryCore

/// The clock and randomness the local repositories use, injectable for tests.
///
/// Production uses `Date.now()`-style epoch milliseconds, the system CSPRNG for ids and
/// QR tokens (RN `newId` / `newQrToken`) and random short codes (RN `generateShortCode`).
public struct RepositoryEnvironment: Sendable {
    /// Integer epoch milliseconds (RN `Date.now()`); read at the same points as the TS code.
    public var now: @Sendable () -> Int64
    /// Source of entity ids and QR tokens.
    public var randomBytes: any RandomByteSource
    /// A fresh `PREFIX-XXXX` code for a new container.
    public var shortCode: @Sendable (ContainerVisualType) -> String

    public init(
        now: @escaping @Sendable () -> Int64 = { epochMillis() },
        randomBytes: any RandomByteSource = SystemRandomByteSource(),
        shortCode: @escaping @Sendable (ContainerVisualType) -> String = { generateShortCode($0) }
    ) {
        self.now = now
        self.randomBytes = randomBytes
        self.shortCode = shortCode
    }

    /// The production environment.
    public static let live = RepositoryEnvironment()

    /// RN `newId()`.
    func makeId() -> String {
        newId(using: randomBytes)
    }

    /// RN `newQrToken()`.
    func makeQrToken() -> String {
        newQrToken(using: randomBytes)
    }
}
