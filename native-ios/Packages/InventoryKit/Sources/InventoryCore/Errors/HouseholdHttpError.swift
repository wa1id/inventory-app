/// A household request that failed with an HTTP status or a transport code.
///
/// Lives in InventoryCore rather than InventoryNetwork so `describeError` and
/// the UI logic can classify it without depending on the network module.
/// `status` is 0 when no response arrived; `code` is the home server's error
/// code (`unauthorized`, `not_found`, …) or a client code such as `offline`,
/// `timeout` or `http_502`.
// RN: src/services/household/client.ts:5-13
public struct HouseholdHttpError: Error, Sendable, Equatable, CustomStringConvertible {
    public let status: Int
    public let code: String

    public init(status: Int, code: String) {
        self.status = status
        self.code = code
    }

    public var description: String { code }
}
