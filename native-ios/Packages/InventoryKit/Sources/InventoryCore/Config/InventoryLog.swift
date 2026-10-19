import os

/// The app's loggers, one category per area (09 §11).
///
/// RN printed nothing but telemetry, and only in development builds, so:
/// - log at `.debug` with `privacy: .private` for any dynamic value that is not
///   an allowlisted telemetry measurement;
/// - in release builds emit nothing above `.debug` except unexpected-failure
///   `.error` lines without payloads;
/// - **never** log the recovery code, a household token, an `x-inventory-key`,
///   item names, notes, QR tokens or photo paths. The recovery code must never
///   appear in a URL, a log line or telemetry (RN src/services/sync/client.ts:20-30).
/// - for an error, log its type name (``errorClass(of:)``), never
///   `localizedDescription`, which can carry user text or paths.
///
/// Telemetry has its own `telemetry` category (`DebugLogSink`).
public enum InventoryLog {
    public static let subsystem = "com.wystudio.inventory"

    /// Boot sequence, legacy adoption and lifecycle.
    public static let boot = Logger(subsystem: subsystem, category: "boot")
    /// Database open, migrations, snapshots and restores.
    public static let db = Logger(subsystem: subsystem, category: "db")
    /// Household pairing, requests, shadow and photo cache.
    public static let household = Logger(subsystem: subsystem, category: "household")
    /// Backup and photo sync.
    public static let sync = Logger(subsystem: subsystem, category: "sync")
    /// Photo recognition requests.
    public static let recognition = Logger(subsystem: subsystem, category: "recognition")
}
