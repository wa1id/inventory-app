// RN: the `Error(message)` throws of src/repositories/*.ts (01 §7). The UI never
// shows the message; `describeError` reads any of these as a local failure. The
// messages are kept for logs and for parity with the home server, whose HTTP
// 400 bodies carry them.

/// A write the local repositories refused.
public enum InventoryError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The drop-zone space or container cannot be renamed, moved, deleted or labelled.
    case systemRecord
    /// An item name was provided but blank.
    case nameRequired
    /// A quantity below zero.
    case invalidQuantity
    /// Ten inserts in a row hit a constraint (01 §7.2: also what an unknown space reports, Q5).
    case shortCodeExhausted

    /// The RN message, verbatim.
    public var message: String {
        switch self {
        case .systemRecord: "system_record"
        case .nameRequired: "Item name is required."
        case .invalidQuantity: "Quantity must be a whole number of 0 or more."
        case .shortCodeExhausted: "Could not allocate a unique container code. Please try again."
        }
    }

    public var description: String { message }
}
