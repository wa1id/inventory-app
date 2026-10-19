// RN: optional `string | null` patch fields (src/repositories/items.ts:117-124,
// src/repositories/containers.ts:40-44). JS tells three states apart: a key that
// is `undefined` keeps the stored value, `null` clears it, a value replaces it.
// The household server distinguishes an absent key from `null` the same way
// (04 §3.7), so a Swift `Optional` is not enough.

/// A patch to one nullable field: keep it, set it, or clear it.
public enum FieldUpdate<Value: Sendable & Hashable>: Sendable, Hashable {
    /// Keep the stored value (JS `undefined`; the key is omitted from a household request).
    case unchanged
    /// Replace the stored value (the repository may still store `NULL` for a blank string).
    case set(Value)
    /// Store `NULL` (JS `null`).
    case clear

    /// `.clear` for `nil`, `.set` otherwise; for callers that always send the field.
    public init(_ value: Value?) {
        self = value.map(Self.set) ?? .clear
    }

    /// Whether the field is part of the patch (JS `value !== undefined`).
    public var isSpecified: Bool {
        if case .unchanged = self { return false }
        return true
    }

    /// The field after the patch, given its stored value.
    public func applied(to current: Value?) -> Value? {
        switch self {
        case .unchanged: current
        case .set(let value): value
        case .clear: nil
        }
    }
}
