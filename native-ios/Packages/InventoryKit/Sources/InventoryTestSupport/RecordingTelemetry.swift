import InventoryCore
import Synchronization

/// A `TelemetrySink` that records every event and error it is given, in order.
///
/// Inject it where the code under test takes a sink (or adapt it to a module's own telemetry
/// seam) rather than replacing the process-wide `Telemetry` sink, which other suites running
/// in parallel would race. It records payloads as given; a seam that stands in for
/// `Telemetry.logEvent` should pass them through `Telemetry.redact` first.
public final class RecordingTelemetry: TelemetrySink {
    public struct Entry: Sendable, Equatable, CustomStringConvertible {
        /// `"event"` or `"error"`.
        public var level: String
        public var name: String
        public var payload: TelemetryPayload

        public init(level: String, name: String, payload: TelemetryPayload = [:]) {
            self.level = level
            self.name = name
            self.payload = payload
        }

        public var description: String { "\(level) \(name) \(payload)" }
    }

    private let storage = Mutex<[Entry]>([])

    public init() {}

    /// Everything recorded so far, oldest first.
    public var entries: [Entry] { storage.withLock { $0 } }

    /// The `event`s only.
    public var events: [Entry] { entries.filter { $0.level == "event" } }

    /// The `error`s only.
    public var errors: [Entry] { entries.filter { $0.level == "error" } }

    /// The names of everything recorded, oldest first.
    public var names: [String] { entries.map(\.name) }

    /// Forgets what was recorded.
    public func reset() {
        storage.withLock { $0.removeAll() }
    }

    public func event(_ name: String, _ payload: TelemetryPayload) {
        storage.withLock { $0.append(Entry(level: "event", name: name, payload: payload)) }
    }

    public func error(_ name: String, _ payload: TelemetryPayload) {
        storage.withLock { $0.append(Entry(level: "error", name: name, payload: payload)) }
    }
}
