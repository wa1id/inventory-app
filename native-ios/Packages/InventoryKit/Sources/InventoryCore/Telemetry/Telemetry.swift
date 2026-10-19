import Synchronization
import os

/// A primitive telemetry value. Anything richer is dropped by `Telemetry.redact`.
public enum TelemetryValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
}

public typealias TelemetryPayload = [String: TelemetryValue]

/// Where events end up. No vendor is wired up; the default sink only logs in
/// debug builds, which is what the privacy screen promises.
public protocol TelemetrySink: Sendable {
    func event(_ name: String, _ payload: TelemetryPayload)
    func error(_ name: String, _ payload: TelemetryPayload)
}

/// Analytics and crash-reporting seam. Every event goes through the allowlist
/// in `redact`, so item names, notes, photo URIs and QR tokens can never reach
/// a log line, even by accident.
// RN: src/services/telemetry/index.ts
public enum Telemetry {
    /// Allowlist, not a denylist: anything not named here is dropped.
    public static let allowedKeys: Set<String> = [
        "durationMs", "latencyMs", "outcome", "errorClass", "contractVersion",
        "statusCode", "itemCount", "containerCount", "spaceCount", "resultCount",
        "termCount", "queryLength", "confidence", "source", "permission", "screen",
        "step", "schemaVersion", "byteSize", "attempt", "hasPhoto",
        "suggestionAccepted", "hinted",
    ]

    private static let sink = Mutex<any TelemetrySink>(DebugLogSink())

    /// Drops any key that is not explicitly allowed.
    public static func redact(_ payload: TelemetryPayload) -> TelemetryPayload {
        payload.filter { allowedKeys.contains($0.key) }
    }

    public static func setSink(_ next: any TelemetrySink) {
        sink.withLock { $0 = next }
    }

    public static func logEvent(_ name: String, _ payload: TelemetryPayload = [:]) {
        let current = sink.withLock { $0 }
        current.event(name, redact(payload))
    }

    public static func logError(_ name: String, _ payload: TelemetryPayload = [:]) {
        let current = sink.withLock { $0 }
        current.error(name, redact(payload))
    }
}

/// Prints events in debug builds and discards them in release builds.
public struct DebugLogSink: TelemetrySink {
    private static let logger = Logger(subsystem: "com.wystudio.inventory", category: "telemetry")

    public init() {}

    public func event(_ name: String, _ payload: TelemetryPayload) {
        #if DEBUG
        Self.logger.debug("[telemetry] \(name, privacy: .public) \(String(describing: payload), privacy: .public)")
        #endif
    }

    public func error(_ name: String, _ payload: TelemetryPayload) {
        #if DEBUG
        Self.logger.error("[telemetry:error] \(name, privacy: .public) \(String(describing: payload), privacy: .public)")
        #endif
    }
}
