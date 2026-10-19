import InventoryCore
import InventoryStorage
import Observation

/// The inventory database for the whole app: whether it is open, and the revision every
/// on-screen read follows (RN `DatabaseProvider`, src/providers/DatabaseProvider.tsx; 09 §4.1).
///
/// - ``open()`` opens `Documents/SQLite/inventory.db` in place and migrates it, off the main
///   actor, then reports `database_ready {durationMs}`, or `database_open_failed {durationMs}`
///   (an event, not an error, as in RN, 09 §9.2).
/// - The boot gate shows the failure screen first whenever ``status`` is `.failed`, even while
///   the rest of boot is still loading; its Try again calls ``retry()``.
/// - ``invalidate()`` bumps ``revision`` after every write; each focused ``InventoryQuery``
///   then reads again and the screens behind catch up when focused.
///
/// The raw failure is never shown; only its type name reaches the log.
@MainActor
@Observable
public final class DatabaseModel: InventoryInvalidating {
    /// RN `DatabaseState`, without the message (logged, never displayed).
    public enum State: Sendable {
        case loading
        /// Open and migrated; the local repositories over it.
        case ready(LocalRepositories)
        case failed
    }

    /// ``State`` without its payload, for the gate.
    public enum Status: Sendable, Hashable {
        case loading
        case ready
        case failed
    }

    /// Opens and migrates the database (`DatabaseStore.openLive()` in the app).
    public typealias Opener = @Sendable () async throws -> DatabaseStore

    public private(set) var state: State = .loading
    /// Starts at 0; `&+= 1` per ``invalidate()``.
    public private(set) var revision = 0

    @ObservationIgnored private let opener: Opener
    @ObservationIgnored private let environment: RepositoryEnvironment
    @ObservationIgnored private let stopwatch: ShellStopwatch
    @ObservationIgnored private let telemetry: TelemetryReporter
    /// Bumped per open, so the answer of an attempt that a retry superseded is dropped (RN `cancelled`).
    @ObservationIgnored private var attempt = 0

    /// - Parameters:
    ///   - open: opens and migrates the database; the live database by default.
    ///   - environment: the repositories' clock and randomness.
    ///   - clock: measures `durationMs`.
    ///   - telemetry: where `database_ready` / `database_open_failed` go.
    public init(
        open: @escaping Opener = { try await DatabaseStore.openLive() },
        environment: RepositoryEnvironment = .live,
        clock: any Clock<Duration> = ContinuousClock(),
        telemetry: TelemetryReporter = .shared
    ) {
        opener = open
        self.environment = environment
        stopwatch = ShellStopwatch(clock)
        self.telemetry = telemetry
    }

    /// ``state`` without the repositories.
    public var status: Status {
        switch state {
        case .loading: .loading
        case .ready: .ready
        case .failed: .failed
        }
    }

    /// The local repositories once the database is ready. Backup, restore and photo sync use
    /// these even while paired (01 §2.4); screens go through the repository provider.
    public var repositories: LocalRepositories? {
        if case .ready(let repositories) = state { return repositories }
        return nil
    }

    /// The open database once ready (snapshot, restore).
    public var store: DatabaseStore? { repositories?.store }

    /// Opens and migrates the database (boot step 2b). Returns once it is ready or failed.
    public func open() async {
        attempt &+= 1
        let current = attempt
        state = .loading
        let startedAt = stopwatch.now
        let outcome: Result<DatabaseStore, any Error>
        do {
            outcome = .success(try await opener())
        } catch {
            outcome = .failure(error)
        }
        let durationMs = ShellStopwatch.milliseconds(stopwatch.now - startedAt)
        guard current == attempt else {
            // A retry started meanwhile; never keep two connections to the same file.
            if case .success(let stale) = outcome { try? stale.close() }
            return
        }
        switch outcome {
        case .success(let store):
            telemetry.event("database_ready", ["durationMs": .int(durationMs)])
            state = .ready(LocalRepositories(store: store, environment: environment))
        case .failure(let error):
            telemetry.event("database_open_failed", ["durationMs": .int(durationMs)])
            InventoryLog.db.error("database open failed: \(errorClass(of: error), privacy: .public)")
            state = .failed
        }
    }

    /// Try again from the failure screen: closes the previous connection if there is one, shows
    /// loading, and opens again (RN reused expo-sqlite's cached connection; closing is cleaner).
    public func retry() async {
        if let store { try? store.close() }
        await open()
    }

    /// After a write: every list on screen reads again (RN `revision + 1`).
    public func invalidate() {
        revision &+= 1
    }
}
