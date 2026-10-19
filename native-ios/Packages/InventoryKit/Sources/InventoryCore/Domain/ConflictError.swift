// RN: src/core/conflict.ts. Thrown by a local `items.update` whose
// `expectedUpdatedAt` no longer matches, and by the household client on HTTP 409.
// Both stores throw this one type.

/// Two devices edited the same row from different `updatedAt` values (RN `ConflictError`).
public struct ConflictError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The row's current `updatedAt`, when known (the 409 body carries it only when finite).
    public let updatedAt: Int64?

    public init(updatedAt: Int64? = nil) {
        self.updatedAt = updatedAt
    }

    /// HTTP status the error stands for: 409.
    public var status: Int { 409 }

    /// Machine-readable code: `conflict`.
    public var code: String { "conflict" }

    /// RN `error.message`: `conflict`.
    public var description: String { "conflict" }
}
