import Foundation
import GRDB
import InventoryCore
import InventoryStorage

// RN: src/services/household/shadow.ts (`withLocalShadow`), 04 §7.

/// The household repositories with this phone's own writes mirrored into local SQLite
/// (RN `withLocalShadow(createHttpRepositories(session), localRepos)`): what screens use
/// while paired.
///
/// Every read, `deletionImpact`, `getPhotos`, `resolveScan`, the label reads and search go
/// straight to the home server. Each write goes to the home server first; only when it
/// succeeds is the result mirrored into the local database, so the phone backup still has
/// something to back up (K5) and leaving the household keeps this phone's own changes:
///
/// | Write | Mirror |
/// | --- | --- |
/// | `spaces.create`, `spaces.update` (when found) | upsert the space |
/// | `spaces.delete` (when deleted) | `DELETE FROM spaces` (cascades locally) |
/// | `containers.create`, `containers.update` (when found) | upsert the container |
/// | `containers.delete` (when deleted) | `DELETE FROM containers` |
/// | `items.create` | upsert the item with its space, container, photo and tags |
/// | `items.update` (when found) | upsert the item row only; tags are not mirrored |
/// | `items.delete` (when deleted) | `DELETE FROM items` |
/// | `qr.bind`, `qr.createAndBind` | replace the bindings on that token or container |
/// | `qr.unbind` (when there was one) | `DELETE FROM qr_bindings` for the container |
///
/// Writes made by other phones are never mirrored, and reads are never mirrored either. A
/// mirror that fails is logged (`household_shadow_failed`) and never fails the write. A write
/// and its mirror always run to the end, as RN's did: a caller whose task is cancelled neither
/// aborts the request nor skips the mirror (``HouseholdShadowMirror/complete(_:)``).
public struct ShadowingRepositories: InventoryRepositories {
    /// The household repositories every call goes to first.
    public let remote: HTTPRepositories
    /// The local repositories whose database receives the mirror.
    public let local: LocalRepositories
    public let spaces: ShadowingSpacesRepository
    public let containers: ShadowingContainersRepository
    public let items: ShadowingItemsRepository
    public let qr: ShadowingQrRepository

    /// Search is the household's, unchanged.
    public var search: HTTPSearchRepository { remote.search }

    /// - Parameters:
    ///   - now: epoch milliseconds for a mirrored photo's `remote_synced_at` and a new tag's
    ///     `created_at` (RN `Date.now()`).
    ///   - makeId: the id of a tag the mirror creates (RN `newId()`).
    public init(
        remote: HTTPRepositories,
        local: LocalRepositories,
        telemetry: TelemetryReporter = .shared,
        now: @escaping @Sendable () -> Int64 = { epochMillis() },
        makeId: @escaping @Sendable () -> String = { newId() }
    ) {
        self.remote = remote
        self.local = local
        let mirror = HouseholdShadowMirror(queue: local.store.queue, now: now, makeId: makeId, telemetry: telemetry)
        spaces = ShadowingSpacesRepository(remote: remote.spaces, mirror: mirror)
        containers = ShadowingContainersRepository(remote: remote.containers, mirror: mirror)
        items = ShadowingItemsRepository(remote: remote.items, mirror: mirror)
        qr = ShadowingQrRepository(remote: remote.qr, mirror: mirror)
    }
}

/// Household spaces with this phone's writes mirrored locally.
public struct ShadowingSpacesRepository: SpacesRepository {
    let remote: HTTPSpacesRepository
    let mirror: HouseholdShadowMirror

    public func listWithCounts() async throws -> [SpaceWithCounts] {
        try await remote.listWithCounts()
    }

    public func getById(_ id: String) async throws -> Space? {
        try await remote.getById(id)
    }

    public func create(_ input: CreateSpaceInput) async throws -> Space {
        let (remote, mirror) = (remote, mirror)
        return try await mirror.complete {
            let space = try await remote.create(input)
            await mirror.run { db in try HouseholdShadowMirror.upsertSpace(space, in: db) }
            return space
        }
    }

    public func update(_ id: String, _ input: UpdateSpaceInput) async throws -> Space? {
        let (remote, mirror) = (remote, mirror)
        return try await mirror.complete {
            let space = try await remote.update(id, input)
            if let space {
                await mirror.run { db in try HouseholdShadowMirror.upsertSpace(space, in: db) }
            }
            return space
        }
    }

    public func deletionImpact(_ id: String) async throws -> SpaceDeletionImpact {
        try await remote.deletionImpact(id)
    }

    public func delete(_ id: String) async throws -> DeletionResult {
        let (remote, mirror) = (remote, mirror)
        return try await mirror.complete {
            let result = try await remote.delete(id)
            if result.deleted {
                await mirror.run { db in try db.execute(sql: "DELETE FROM spaces WHERE id = ?", arguments: [id]) }
            }
            return result
        }
    }
}

/// Household containers with this phone's writes mirrored locally.
public struct ShadowingContainersRepository: ContainersRepository {
    let remote: HTTPContainersRepository
    let mirror: HouseholdShadowMirror

    public func listBySpace(_ spaceId: String) async throws -> [ContainerWithCounts] {
        try await remote.listBySpace(spaceId)
    }

    public func getById(_ id: String) async throws -> Container? {
        try await remote.getById(id)
    }

    public func getWithCounts(_ id: String) async throws -> ContainerWithCounts? {
        try await remote.getWithCounts(id)
    }

    public func create(_ input: CreateContainerInput) async throws -> Container {
        let (remote, mirror) = (remote, mirror)
        return try await mirror.complete {
            let container = try await remote.create(input)
            await mirror.run { db in try HouseholdShadowMirror.upsertContainer(container, in: db) }
            return container
        }
    }

    public func update(_ id: String, _ input: UpdateContainerInput) async throws -> Container? {
        let (remote, mirror) = (remote, mirror)
        return try await mirror.complete {
            let container = try await remote.update(id, input)
            if let container {
                await mirror.run { db in try HouseholdShadowMirror.upsertContainer(container, in: db) }
            }
            return container
        }
    }

    public func deletionImpact(_ id: String) async throws -> ContainerDeletionImpact {
        try await remote.deletionImpact(id)
    }

    public func delete(_ id: String) async throws -> DeletionResult {
        let (remote, mirror) = (remote, mirror)
        return try await mirror.complete {
            let result = try await remote.delete(id)
            if result.deleted {
                await mirror.run { db in try db.execute(sql: "DELETE FROM containers WHERE id = ?", arguments: [id]) }
            }
            return result
        }
    }

    public func listAllWithSpace() async throws -> [ContainerWithSpace] {
        try await remote.listAllWithSpace()
    }
}

/// Household items with this phone's writes mirrored locally.
public struct ShadowingItemsRepository: ItemsRepository {
    let remote: HTTPItemsRepository
    let mirror: HouseholdShadowMirror

    public func listByContainer(_ containerId: String) async throws -> [ItemWithContext] {
        try await remote.listByContainer(containerId)
    }

    public func listUnsorted() async throws -> [ItemWithContext] {
        try await remote.listUnsorted()
    }

    public func listRecent(limit: Int) async throws -> [ItemWithContext] {
        try await remote.listRecent(limit: limit)
    }

    public func countUnsorted() async throws -> Int {
        try await remote.countUnsorted()
    }

    public func getById(_ id: String) async throws -> ItemWithContext? {
        try await remote.getById(id)
    }

    /// Mirrors the whole graph the server answered with (RN shadow.ts:57-64). RN mirrored only
    /// the row when the answer lacked a string `spaceId`; a household answer without its context
    /// does not decode natively, so that branch cannot occur.
    public func create(_ draft: ItemDraft) async throws -> Item {
        let (remote, mirror) = (remote, mirror)
        return try await mirror.complete {
            let item = try await remote.createWithContext(draft)
            await mirror.run { db in try mirror.upsertItemGraph(item, in: db) }
            return item.item
        }
    }

    /// Mirrors the item row only: the server answers a bare `Item`, so tags are not mirrored
    /// on update (RN shadow.ts:65-69, 04 Q4).
    public func update(_ id: String, _ input: UpdateItemInput) async throws -> Item? {
        let (remote, mirror) = (remote, mirror)
        return try await mirror.complete {
            let item = try await remote.update(id, input)
            if let item {
                await mirror.run { db in try HouseholdShadowMirror.upsertItemRow(item, in: db) }
            }
            return item
        }
    }

    public func getPhotos(_ itemId: String) async throws -> [ItemPhoto] {
        try await remote.getPhotos(itemId)
    }

    public func delete(_ id: String) async throws -> DeletionResult {
        let (remote, mirror) = (remote, mirror)
        return try await mirror.complete {
            let result = try await remote.delete(id)
            if result.deleted {
                await mirror.run { db in try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [id]) }
            }
            return result
        }
    }

    public func countAll() async throws -> Int {
        try await remote.countAll()
    }
}

/// Household labels with this phone's writes mirrored locally.
public struct ShadowingQrRepository: QrRepository {
    let remote: HTTPQrRepository
    let mirror: HouseholdShadowMirror

    public func resolveScan(_ raw: String) async throws -> ScanOutcome {
        try await remote.resolveScan(raw)
    }

    public func getByContainer(_ containerId: String) async throws -> QrBinding? {
        try await remote.getByContainer(containerId)
    }

    public func getByToken(_ token: String) async throws -> QrBinding? {
        try await remote.getByToken(token)
    }

    public func bind(token: String, containerId: String) async throws -> QrBinding {
        let (remote, mirror) = (remote, mirror)
        return try await mirror.complete {
            let binding = try await remote.bind(token: token, containerId: containerId)
            await mirror.run { db in try HouseholdShadowMirror.upsertQr(binding, in: db) }
            return binding
        }
    }

    public func createAndBind(_ containerId: String) async throws -> QrBinding {
        let (remote, mirror) = (remote, mirror)
        return try await mirror.complete {
            let binding = try await remote.createAndBind(containerId)
            await mirror.run { db in try HouseholdShadowMirror.upsertQr(binding, in: db) }
            return binding
        }
    }

    public func unbind(_ containerId: String) async throws -> Bool {
        let (remote, mirror) = (remote, mirror)
        return try await mirror.complete {
            let unbound = try await remote.unbind(containerId)
            if unbound {
                await mirror.run { db in
                    try db.execute(sql: "DELETE FROM qr_bindings WHERE container_id = ?", arguments: [containerId])
                }
            }
            return unbound
        }
    }
}
