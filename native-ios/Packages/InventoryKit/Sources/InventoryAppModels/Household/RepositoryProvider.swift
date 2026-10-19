import Observation
import InventoryCore
import InventoryServices
import InventoryStorage

/// The repositories screens read and write through (RN `useRepositories()`,
/// src/providers/DatabaseProvider.tsx:108-120; 09 §4.1).
///
/// - Unpaired: the local SQLite repositories.
/// - Paired: the household's HTTP repositories with this phone's writes mirrored into local
///   SQLite (``ShadowingRepositories``); mirror failures only log `household_shadow_failed`.
/// - Before the database is ready: nil (RN threw).
///
/// Both properties are computed from the household's session and the database's state on
/// every read, so a view that reads them follows both. Changing the session does not re-run
/// any query by itself: callers invalidate after pairing and leaving.
@MainActor
@Observable
public final class RepositoryProvider {
    private let household: HouseholdModel
    @ObservationIgnored private let local: @MainActor () -> LocalRepositories?
    @ObservationIgnored private let telemetry: TelemetryReporter

    /// - Parameters:
    ///   - localRepositories: the local repositories once the database is open, nil before
    ///     (the database model's state).
    ///   - telemetry: where mirror failures are reported.
    public init(
        household: HouseholdModel,
        localRepositories: @escaping @MainActor () -> LocalRepositories?,
        telemetry: TelemetryReporter = .shared
    ) {
        self.household = household
        self.local = localRepositories
        self.telemetry = telemetry
    }

    /// The raw local repositories, whatever the session (RN `useDatabase().state.repos`): what
    /// the join snapshot counts and the household import copies. Never shadowed.
    public var localRepositories: LocalRepositories? {
        local()
    }

    /// Local repositories while unpaired, shadowed household repositories while paired, nil
    /// until the database is ready.
    public var repositories: (any InventoryRepositories)? {
        guard let local = local() else { return nil }
        guard let remote = household.remoteRepositories else { return local }
        return ShadowingRepositories(remote: remote, local: local, telemetry: telemetry)
    }

    /// Whether ``repositories`` go to the home server.
    public var isPaired: Bool {
        household.session != nil
    }
}
