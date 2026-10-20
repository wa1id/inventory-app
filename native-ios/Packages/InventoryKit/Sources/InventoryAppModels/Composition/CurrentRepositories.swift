import InventoryCore

/// The repositories in use at the moment of each call: this phone's SQLite while unpaired, the
/// household's (with the local shadow) while paired (RN `useRepositories()`; 09 §4.1).
///
/// A stable value for models that are created once and outlive a join or a leave (the camera,
/// the Quick Snap review, the Add and move sheets, the drop-zone read): every method asks the
/// ``RepositoryProvider`` again, so the next call after pairing already goes to the home server.
/// Before the database is ready a call throws ``CurrentRepositoriesNotReady`` (RN threw too),
/// which `describeError` reads as a local failure.
///
/// **Threading.** The provider is main-actor state, so each call hops to the main actor to
/// resolve the repositories (a few property reads, no I/O), then runs the repository method on
/// the caller's executor, off the main actor, exactly as calling the resolved repository would.
public struct CurrentRepositories: InventoryRepositories {
    /// Resolves the repositories in use now; throws before the database is ready.
    public typealias Resolve = @MainActor @Sendable () throws -> any InventoryRepositories

    public let spaces: CurrentSpacesRepository
    public let containers: CurrentContainersRepository
    public let items: CurrentItemsRepository
    public let qr: CurrentQrRepository
    public let search: CurrentSearchRepository

    public init(resolve: @escaping Resolve) {
        spaces = CurrentSpacesRepository(resolve: resolve)
        containers = CurrentContainersRepository(resolve: resolve)
        items = CurrentItemsRepository(resolve: resolve)
        qr = CurrentQrRepository(resolve: resolve)
        search = CurrentSearchRepository(resolve: resolve)
    }

    /// Follows `provider`.
    public init(provider: RepositoryProvider) {
        self.init {
            guard let repositories = provider.repositories else { throw CurrentRepositoriesNotReady() }
            return repositories
        }
    }
}

/// The database is not open yet, so there are no repositories to call.
public struct CurrentRepositoriesNotReady: Error, Sendable, Hashable, CustomStringConvertible {
    public init() {}
    public var description: String { "The inventory database is not ready." }
}

public struct CurrentSpacesRepository: SpacesRepository {
    let resolve: CurrentRepositories.Resolve

    public func listWithCounts() async throws -> [SpaceWithCounts] {
        try await resolve().spaces.listWithCounts()
    }

    public func getById(_ id: String) async throws -> Space? {
        try await resolve().spaces.getById(id)
    }

    public func create(_ input: CreateSpaceInput) async throws -> Space {
        try await resolve().spaces.create(input)
    }

    public func update(_ id: String, _ input: UpdateSpaceInput) async throws -> Space? {
        try await resolve().spaces.update(id, input)
    }

    public func deletionImpact(_ id: String) async throws -> SpaceDeletionImpact {
        try await resolve().spaces.deletionImpact(id)
    }

    public func delete(_ id: String) async throws -> DeletionResult {
        try await resolve().spaces.delete(id)
    }
}

public struct CurrentContainersRepository: ContainersRepository {
    let resolve: CurrentRepositories.Resolve

    public func listBySpace(_ spaceId: String) async throws -> [ContainerWithCounts] {
        try await resolve().containers.listBySpace(spaceId)
    }

    public func getById(_ id: String) async throws -> Container? {
        try await resolve().containers.getById(id)
    }

    public func getWithCounts(_ id: String) async throws -> ContainerWithCounts? {
        try await resolve().containers.getWithCounts(id)
    }

    public func create(_ input: CreateContainerInput) async throws -> Container {
        try await resolve().containers.create(input)
    }

    public func update(_ id: String, _ input: UpdateContainerInput) async throws -> Container? {
        try await resolve().containers.update(id, input)
    }

    public func deletionImpact(_ id: String) async throws -> ContainerDeletionImpact {
        try await resolve().containers.deletionImpact(id)
    }

    public func delete(_ id: String) async throws -> DeletionResult {
        try await resolve().containers.delete(id)
    }

    public func listAllWithSpace() async throws -> [ContainerWithSpace] {
        try await resolve().containers.listAllWithSpace()
    }
}

public struct CurrentItemsRepository: ItemsRepository {
    let resolve: CurrentRepositories.Resolve

    public func listByContainer(_ containerId: String) async throws -> [ItemWithContext] {
        try await resolve().items.listByContainer(containerId)
    }

    public func listUnsorted() async throws -> [ItemWithContext] {
        try await resolve().items.listUnsorted()
    }

    public func listRecent(limit: Int) async throws -> [ItemWithContext] {
        try await resolve().items.listRecent(limit: limit)
    }

    public func countUnsorted() async throws -> Int {
        try await resolve().items.countUnsorted()
    }

    public func getById(_ id: String) async throws -> ItemWithContext? {
        try await resolve().items.getById(id)
    }

    public func create(_ draft: ItemDraft) async throws -> Item {
        try await resolve().items.create(draft)
    }

    public func update(_ id: String, _ input: UpdateItemInput) async throws -> Item? {
        try await resolve().items.update(id, input)
    }

    public func getPhotos(_ itemId: String) async throws -> [ItemPhoto] {
        try await resolve().items.getPhotos(itemId)
    }

    public func delete(_ id: String) async throws -> DeletionResult {
        try await resolve().items.delete(id)
    }

    public func countAll() async throws -> Int {
        try await resolve().items.countAll()
    }
}

public struct CurrentQrRepository: QrRepository {
    let resolve: CurrentRepositories.Resolve

    public func resolveScan(_ raw: String) async throws -> ScanOutcome {
        try await resolve().qr.resolveScan(raw)
    }

    public func getByContainer(_ containerId: String) async throws -> QrBinding? {
        try await resolve().qr.getByContainer(containerId)
    }

    public func getByToken(_ token: String) async throws -> QrBinding? {
        try await resolve().qr.getByToken(token)
    }

    public func bind(token: String, containerId: String) async throws -> QrBinding {
        try await resolve().qr.bind(token: token, containerId: containerId)
    }

    public func createAndBind(_ containerId: String) async throws -> QrBinding {
        try await resolve().qr.createAndBind(containerId)
    }

    public func unbind(_ containerId: String) async throws -> Bool {
        try await resolve().qr.unbind(containerId)
    }
}

public struct CurrentSearchRepository: SearchRepository {
    let resolve: CurrentRepositories.Resolve

    public func search(_ rawQuery: String) async throws -> SearchResults {
        try await resolve().search.search(rawQuery)
    }

    public func searchSpaces(_ terms: [String]) async throws -> [LocationSearchResult] {
        try await resolve().search.searchSpaces(terms)
    }

    public func searchContainers(_ terms: [String]) async throws -> [LocationSearchResult] {
        try await resolve().search.searchContainers(terms)
    }
}
