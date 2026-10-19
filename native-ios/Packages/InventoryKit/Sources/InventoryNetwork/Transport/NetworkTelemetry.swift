import InventoryCore

/// Where the clients report their telemetry events.
///
/// The default, ``standard``, is InventoryCore's ``Telemetry/logEvent(_:_:)`` and
/// ``Telemetry/logError(_:_:)`` with their allowlist redaction, exactly as RN's
/// clients call `logEvent` / `logError`. Tests inject a recorder so assertions
/// never race the process-wide sink.
public struct NetworkTelemetry: Sendable {
    public var event: @Sendable (_ name: String, _ payload: TelemetryPayload) -> Void
    public var error: @Sendable (_ name: String, _ payload: TelemetryPayload) -> Void

    public init(
        event: @escaping @Sendable (_ name: String, _ payload: TelemetryPayload) -> Void,
        error: @escaping @Sendable (_ name: String, _ payload: TelemetryPayload) -> Void
    ) {
        self.event = event
        self.error = error
    }

    /// InventoryCore's process-wide telemetry.
    public static let standard = NetworkTelemetry(
        event: { Telemetry.logEvent($0, $1) },
        error: { Telemetry.logError($0, $1) }
    )
}
