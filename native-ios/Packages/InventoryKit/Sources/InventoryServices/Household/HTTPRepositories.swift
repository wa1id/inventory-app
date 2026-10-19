import Foundation
import InventoryCore
import InventoryNetwork
import InventoryStorage

// RN: src/services/household/httpRepositories.ts (`createHttpRepositories`), method by
// method as 04 §6.1 lists them. While paired every read goes to the home server; nothing is
// read from local SQLite. The RN quirks are kept on purpose (00-index §5, 04 Q5): the QR
// binding's id is the container's, `countAll` leaves the drop zone out, `getByToken` and the
// location searches return nothing, `items.update` never sends a photo, and inventory ids go
// into paths without percent-encoding. RN's `db` stub (every method throws "Local SQLite is not
// used while paired") has no counterpart: the repository protocols have no `db`.

/// The five repositories over the home server's API (RN `createHttpRepositories(session)`).
///
/// Screens get these wrapped in ``ShadowingRepositories``, which mirrors this phone's own
/// writes into local SQLite. 404 answers read as "gone" (`nil`, `deleted: false`, `false`),
/// a 409 throws ``ConflictError``, everything else throws ``HouseholdHttpError``.
public struct HTTPRepositories: InventoryRepositories {
    /// The session every request is made with.
    public let session: HouseholdSession
    public let spaces: HTTPSpacesRepository
    public let containers: HTTPContainersRepository
    public let items: HTTPItemsRepository
    public let qr: HTTPQrRepository
    public let search: HTTPSearchRepository

    /// - Parameters:
    ///   - session: the paired session; requests go to its origin with its token.
    ///   - client: carries the transport, the reachability hub and the clock; it is re-aimed at
    ///     the session (``HouseholdClient/forSession(_:)``).
    ///   - photos: reads a local capture's bytes for the item-create upload (RN `readStoredPhoto`).
    ///   - photoCache: where household photos become local files (hydration and the
    ///     post-create copy).
    public init(session: HouseholdSession, client: HouseholdClient, photos: any PhotoStoring, photoCache: HouseholdPhotoCache) {
        self.session = session
        let sessionClient = client.forSession(session)
        let hydration = HouseholdPhotoHydration(client: sessionClient, cache: photoCache)
        spaces = HTTPSpacesRepository(client: sessionClient)
        containers = HTTPContainersRepository(client: sessionClient)
        items = HTTPItemsRepository(client: sessionClient, photos: photos, photoCache: photoCache, hydration: hydration)
        qr = HTTPQrRepository(client: sessionClient)
        search = HTTPSearchRepository(client: sessionClient, hydration: hydration)
    }
}

// MARK: - Spaces

/// Spaces on the home server (RN `createHttpRepositories(...).spaces`).
public struct HTTPSpacesRepository: SpacesRepository {
    let client: HouseholdClient

    /// `GET /v1/spaces`: normal spaces with counts, by name; a missing list reads as empty.
    public func listWithCounts() async throws -> [SpaceWithCounts] {
        try await client.listSpaces()
    }

    /// `GET /v1/spaces/{id}`; nil on 404.
    public func getById(_ id: String) async throws -> Space? {
        try await client.space(id: id)
    }

    /// `POST /v1/spaces` with the input verbatim; the server trims the name.
    public func create(_ input: CreateSpaceInput) async throws -> Space {
        try await client.createSpace(HouseholdBody.NewSpace(name: input.name, icon: input.icon, color: input.color))
    }

    /// `PATCH /v1/spaces/{id}` with the given fields; nil on 404.
    public func update(_ id: String, _ input: UpdateSpaceInput) async throws -> Space? {
        try await client.updateSpace(id: id, HouseholdBody.SpacePatch(name: input.name, icon: input.icon, color: input.color))
    }

    /// The space's counts from the space list; photo and label counts are not known here, so 0
    /// (RN httpRepositories.ts:142-153). A space that is gone reads all zeros.
    public func deletionImpact(_ id: String) async throws -> SpaceDeletionImpact {
        let space = try await getById(id)
        let rows = space == nil ? [] : try await listWithCounts()
        let row = rows.first { $0.id == id }
        return SpaceDeletionImpact(
            containerCount: row?.containerCount ?? 0,
            itemCount: row?.itemCount ?? 0,
            photoCount: 0,
            qrBindingCount: 0
        )
    }

    /// `DELETE /v1/spaces/{id}`; `deleted: false` on 404. Orphaned URIs are the server's `r2:` strings.
    public func delete(_ id: String) async throws -> DeletionResult {
        DeletionResult(try await client.deleteSpace(id: id))
    }
}

// MARK: - Containers

/// Containers on the home server (RN `createHttpRepositories(...).containers`).
public struct HTTPContainersRepository: ContainersRepository {
    let client: HouseholdClient

    /// `GET /v1/containers?spaceId=`: a space's containers, newest first.
    public func listBySpace(_ spaceId: String) async throws -> [ContainerWithCounts] {
        try await client.listContainers(spaceId: spaceId)
    }

    /// `GET /v1/containers/{id}`; nil on 404 (RN returns the with-counts body).
    public func getById(_ id: String) async throws -> Container? {
        try await client.container(id: id)?.container
    }

    /// `GET /v1/containers/{id}`; nil on 404.
    public func getWithCounts(_ id: String) async throws -> ContainerWithCounts? {
        try await client.container(id: id)
    }

    /// `POST /v1/containers` with `{spaceId, visualType, name}`; the server makes the id and short code.
    public func create(_ input: CreateContainerInput) async throws -> Container {
        try await client.createContainer(HouseholdBody.NewContainer(spaceId: input.spaceId, visualType: input.visualType, name: input.name))
    }

    /// `PATCH /v1/containers/{id}` with `{name, visualType, spaceId}` (absent keys omitted, a
    /// cleared name sent as `null`); nil on 404.
    public func update(_ id: String, _ input: UpdateContainerInput) async throws -> Container? {
        try await client.updateContainer(id: id, HouseholdBody.ContainerPatch(name: input.name, visualType: input.visualType, spaceId: input.spaceId))
    }

    /// The container's item count and whether it has a label; photos are not counted here
    /// (RN httpRepositories.ts:198-205). JS `Boolean(qrToken)`: an empty token is no label.
    public func deletionImpact(_ id: String) async throws -> ContainerDeletionImpact {
        let container = try await getWithCounts(id)
        return ContainerDeletionImpact(
            itemCount: container?.itemCount ?? 0,
            photoCount: 0,
            hasQrBinding: !(container?.qrToken ?? "").isEmpty
        )
    }

    /// `DELETE /v1/containers/{id}`; `deleted: false` on 404.
    public func delete(_ id: String) async throws -> DeletionResult {
        DeletionResult(try await client.deleteContainer(id: id))
    }

    /// `GET /v1/containers`: every normal container with its space name (the place picker).
    public func listAllWithSpace() async throws -> [ContainerWithSpace] {
        try await client.listAllContainers()
    }
}

// MARK: - QR labels

/// Labels on the home server (RN `createHttpRepositories(...).qr`).
public struct HTTPQrRepository: QrRepository {
    let client: HouseholdClient

    /// `POST /v1/qr/scan` with `{raw}`.
    public func resolveScan(_ raw: String) async throws -> ScanOutcome {
        try await client.resolveScan(raw)
    }

    /// The container's newest label, from `GET /v1/containers/{id}`; nil on 404 or without a
    /// token (RN httpRepositories.ts:322-337).
    ///
    /// RN quirk kept: the binding's `id` is the container's id, and its timestamps are the
    /// container's; `containerId` is the argument.
    public func getByContainer(_ containerId: String) async throws -> QrBinding? {
        guard let container = try await client.container(id: containerId),
              let token = container.qrToken, !token.isEmpty
        else { return nil }
        return QrBinding(
            id: container.id,
            token: token,
            containerId: containerId,
            createdAt: container.createdAt,
            updatedAt: container.updatedAt
        )
    }

    /// Not supported by the household API: always nil (RN httpRepositories.ts:338-340).
    public func getByToken(_ token: String) async throws -> QrBinding? {
        nil
    }

    /// `POST /v1/qr/bind` with `{token, containerId}`.
    public func bind(token: String, containerId: String) async throws -> QrBinding {
        try await client.bindLabel(token: token, containerId: containerId)
    }

    /// `POST /v1/containers/{id}/qr` with no body: a new label.
    public func createAndBind(_ containerId: String) async throws -> QrBinding {
        try await client.createAndBindLabel(containerId: containerId)
    }

    /// `DELETE /v1/containers/{id}/qr`: true on 204, false on 404.
    public func unbind(_ containerId: String) async throws -> Bool {
        try await client.unbindLabel(containerId: containerId)
    }
}

// MARK: - Search

/// Search on the home server, which runs the shared TS search (RN `createHttpRepositories(...).search`).
public struct HTTPSearchRepository: SearchRepository {
    let client: HouseholdClient
    let hydration: HouseholdPhotoHydration

    /// `GET /v1/search?q=`, with each item's thumbnail made local; `items` that are not an
    /// array read as none.
    public func search(_ rawQuery: String) async throws -> SearchResults {
        var results = try await client.search(rawQuery)
        let hydrated = await hydration.thumbnails(results.items.map(\.item))
        for index in results.items.indices {
            results.items[index].item = hydrated[index]
        }
        return results
    }

    /// Locations come inside ``search(_:)``: always empty (RN httpRepositories.ts:364-369).
    public func searchSpaces(_ terms: [String]) async throws -> [LocationSearchResult] {
        []
    }

    /// Locations come inside ``search(_:)``: always empty.
    public func searchContainers(_ terms: [String]) async throws -> [LocationSearchResult] {
        []
    }
}

extension DeletionResult {
    /// The repository result for a household delete.
    init(_ result: HouseholdDeleteResult) {
        self.init(deleted: result.deleted, orphanedPhotoUris: result.orphanedPhotoUris)
    }
}
