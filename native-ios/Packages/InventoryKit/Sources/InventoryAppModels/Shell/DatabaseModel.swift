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
/// - ``addStateObserver(_:)`` tells the composition root when the database opens (or reopens
///   after Try again) and when it goes back to loading, so the backup model starts its passes
///   without waiting for the gate (09 §3.2 step 4: `SyncModel.databaseReady(_:)`).
///
/// There is only ever one connection to the file (DECISIONS D-1): one open runs at a time, a
/// second call waits for the one in flight, and an open database is never reopened. The open is
/// not tied to the caller's task, so a view going away cannot cut a migration short.
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

    /// A registered state observer; pass it back to ``removeStateObserver(_:)``.
    public struct StateObservation: Hashable, Sendable {
        let id: Int
    }

    /// Opens and migrates the database (`DatabaseStore.openLive()` in the app).
    public typealias Opener = @Sendable () async throws -> DatabaseStore

    public private(set) var state: State = .loading
    /// Starts at 0; `&+= 1` per ``invalidate()``.
    public private(set) var revision = 0

    @ObservationIgnored private let opener: Opener
    @ObservationIgnored private let environment: RepositoryEnvironment
    @ObservationIgnored private let stopwatch: Stopwatch
    @ObservationIgnored private let telemetry: TelemetryReporter
    /// The open in flight; nil again in the same turn the open settles.
    @ObservationIgnored private var opening: Task<Void, Never>?
    @ObservationIgnored private var observers: [(id: Int, notify: @MainActor (State) -> Void)] = []
    @ObservationIgnored private var nextObserverID = 0

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
        stopwatch = Stopwatch(clock)
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
    ///
    /// Waits for an open already in flight rather than starting a second one, and does nothing
    /// once the database is open.
    public func open() async {
        if let opening {
            await opening.value
            return
        }
        if case .ready = state { return }
        let task = Task { await self.performOpen() }
        opening = task
        await task.value
    }

    /// Try again from the failure screen: shows loading and opens again.
    ///
    /// A tap while an open is running waits for that open, and an open database is left alone,
    /// so a double tap never puts a second connection on the file (two connections migrating
    /// at once would fail the newer one with `SQLITE_BUSY`). A failed open leaves no connection
    /// behind (`DatabaseStore.openLive` releases it), so there is nothing to close first; RN
    /// reran the open on expo-sqlite's cached connection (09 §2.4, §3.2).
    public func retry() async {
        if let opening {
            await opening.value
            return
        }
        guard case .failed = state else { return }
        await open()
    }

    /// After a write: every list on screen reads again (RN `revision + 1`).
    public func invalidate() {
        revision &+= 1
    }

    /// Calls `observer` on the main actor after every change of ``state`` (loading, ready with
    /// the repositories, failed), in registration order. It is not called with the current state.
    @discardableResult
    public func addStateObserver(_ observer: @escaping @MainActor (State) -> Void) -> StateObservation {
        nextObserverID += 1
        observers.append((nextObserverID, observer))
        return StateObservation(id: nextObserverID)
    }

    /// Stops calling an observer.
    public func removeStateObserver(_ observation: StateObservation) {
        observers.removeAll { $0.id == observation.id }
    }

    // MARK: Opening

    private func performOpen() async {
        apply(.loading)
        let startedAt = stopwatch.now
        let outcome: Result<DatabaseStore, any Error>
        do {
            outcome = .success(try await opener())
        } catch {
            outcome = .failure(error)
        }
        let durationMs = Stopwatch.milliseconds(stopwatch.now - startedAt)
        opening = nil
        switch outcome {
        case .success(let store):
            telemetry.event("database_ready", ["durationMs": .int(durationMs)])
            apply(.ready(LocalRepositories(store: store, environment: environment)))
        case .failure(let error):
            telemetry.event("database_open_failed", ["durationMs": .int(durationMs)])
            InventoryLog.db.error("database open failed: \(errorClass(of: error), privacy: .public)")
            apply(.failed)
        }
    }

    private func apply(_ next: State) {
        let unchanged: Bool = switch (state, next) {
        case (.loading, .loading), (.failed, .failed): true
        default: false
        }
        state = next
        guard !unchanged else { return }
        for observer in observers {
            observer.notify(next)
        }
    }
}
