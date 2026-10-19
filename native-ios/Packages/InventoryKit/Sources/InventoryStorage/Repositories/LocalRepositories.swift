import GRDB
import InventoryCore

// RN: src/db/repositories.ts (`createRepositories`, `initializeRepositories`).

/// The five repositories over the local SQLite database (RN `createRepositories(db)`).
///
/// The household HTTP repositories and the shadowing decorator conform to the same
/// ``InventoryRepositories`` protocol. Backup, restore and photo sync use ``store`` directly.
public struct LocalRepositories: InventoryRepositories {
    public let store: DatabaseStore
    public let spaces: LocalSpacesRepository
    public let containers: LocalContainersRepository
    public let items: LocalItemsRepository
    public let qr: LocalQrRepository
    public let search: LocalSearchRepository

    /// Builds the repositories over an already migrated store.
    public init(store: DatabaseStore, environment: RepositoryEnvironment = .live) {
        self.store = store
        spaces = LocalSpacesRepository(queue: store.queue, environment: environment)
        containers = LocalContainersRepository(queue: store.queue, environment: environment)
        items = LocalItemsRepository(queue: store.queue, environment: environment)
        qr = LocalQrRepository(queue: store.queue, environment: environment)
        search = LocalSearchRepository(queue: store.queue)
    }

    /// Migrates the store, then builds the repositories (RN `initializeRepositories`).
    public static func initialize(
        _ store: DatabaseStore,
        environment: RepositoryEnvironment = .live
    ) async throws -> LocalRepositories {
        try await store.migrate()
        return LocalRepositories(store: store, environment: environment)
    }
}
