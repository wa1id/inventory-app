// RN: src/db/repositories.ts (`Repositories`) and the five repository objects
// in src/repositories/*.ts. Three implementations share these protocols: the
// local GRDB repositories (InventoryStorage), the household HTTP repositories
// and the shadowing decorator (04 §6-7). Each method keeps the TS semantics;
// the local implementation documents the SQL.
//
// No method invalidates anything. Callers bump the data revision after a write
// (01 §9.1).

/// Spaces: rooms, a garage, an attic (RN `SpacesRepository`).
public protocol SpacesRepository: Sendable {
    /// User spaces (not the drop zone) with container and item counts, by name (ASCII case-insensitive).
    func listWithCounts() async throws -> [SpaceWithCounts]
    /// Any space by id, including the drop zone's.
    func getById(_ id: String) async throws -> Space?
    func create(_ input: CreateSpaceInput) async throws -> Space
    /// The merged space, or `nil` when it does not exist. Throws ``InventoryError/systemRecord`` for the drop zone.
    func update(_ id: String, _ input: UpdateSpaceInput) async throws -> Space?
    func deletionImpact(_ id: String) async throws -> SpaceDeletionImpact
    /// Deletes the space and everything in it. Throws ``InventoryError/systemRecord`` for the drop zone.
    func delete(_ id: String) async throws -> DeletionResult
}

/// Containers: boxes, drawers, shelves (RN `ContainersRepository`).
public protocol ContainersRepository: Sendable {
    /// A space's user containers, newest first, with item counts and newest label token.
    func listBySpace(_ spaceId: String) async throws -> [ContainerWithCounts]
    /// Any container by id, including the drop zone.
    func getById(_ id: String) async throws -> Container?
    /// Any container by id with its counts, including the drop zone.
    func getWithCounts(_ id: String) async throws -> ContainerWithCounts?
    /// Creates a container with a fresh unique short code.
    func create(_ input: CreateContainerInput) async throws -> Container
    /// The merged container, or `nil` when it does not exist. Throws ``InventoryError/systemRecord`` for the drop zone.
    func update(_ id: String, _ input: UpdateContainerInput) async throws -> Container?
    func deletionImpact(_ id: String) async throws -> ContainerDeletionImpact
    /// Deletes the container and its items. Throws ``InventoryError/systemRecord`` for the drop zone.
    func delete(_ id: String) async throws -> DeletionResult
    /// Every user container with its space name, by space name then newest first (the place picker).
    func listAllWithSpace() async throws -> [ContainerWithSpace]
}

/// Items (RN `ItemsRepository`).
public protocol ItemsRepository: Sendable {
    /// A container's items, newest first.
    func listByContainer(_ containerId: String) async throws -> [ItemWithContext]
    /// Everything waiting in the drop zone, newest first.
    func listUnsorted() async throws -> [ItemWithContext]
    /// The newest items anywhere (drop zone included); `limit` is clamped to 1…100.
    func listRecent(limit: Int) async throws -> [ItemWithContext]
    func countUnsorted() async throws -> Int
    func getById(_ id: String) async throws -> ItemWithContext?
    /// Creates the item with its photo and tags atomically.
    func create(_ draft: ItemDraft) async throws -> Item
    /// The merged item, or `nil` when it no longer exists.
    /// Throws ``ConflictError`` when `expectedUpdatedAt` no longer matches.
    func update(_ id: String, _ input: UpdateItemInput) async throws -> Item?
    /// An item's photos, oldest first.
    func getPhotos(_ itemId: String) async throws -> [ItemPhoto]
    func delete(_ id: String) async throws -> DeletionResult
    func countAll() async throws -> Int
}

extension ItemsRepository {
    /// The 40 newest items (RN `listRecent()` default).
    public func listRecent() async throws -> [ItemWithContext] {
        try await listRecent(limit: 40)
    }
}

/// Printed QR labels (RN `QrRepository`).
public protocol QrRepository: Sendable {
    /// What a scanned string means: a bound container, an unbound token of ours, or not ours.
    func resolveScan(_ raw: String) async throws -> ScanOutcome
    /// The container's newest binding.
    func getByContainer(_ containerId: String) async throws -> QrBinding?
    /// The binding with exactly this token (not lowercased).
    func getByToken(_ token: String) async throws -> QrBinding?
    /// Binds `token` to `containerId`, replacing any binding on either side.
    /// Throws ``InventoryError/systemRecord`` for the drop zone.
    func bind(token: String, containerId: String) async throws -> QrBinding
    /// Binds a fresh token (the on-screen label).
    func createAndBind(_ containerId: String) async throws -> QrBinding
    /// Removes the container's label; `true` when there was one.
    func unbind(_ containerId: String) async throws -> Bool
}

/// Keyword search (RN `SearchRepository`).
public protocol SearchRepository: Sendable {
    /// Every term must match the item or its location; items matching on their own fields rank first.
    func search(_ rawQuery: String) async throws -> SearchResults
    /// User spaces whose name matches every term.
    func searchSpaces(_ terms: [String]) async throws -> [LocationSearchResult]
    /// User containers whose name or short code matches every term.
    func searchContainers(_ terms: [String]) async throws -> [LocationSearchResult]
}

/// The five repositories screens read and write through (RN `Repositories`, minus `db`).
///
/// Backup, restore and photo sync always use the local database directly, even
/// while paired (01 §2.4).
public protocol InventoryRepositories: Sendable {
    associatedtype Spaces: SpacesRepository
    associatedtype Containers: ContainersRepository
    associatedtype Items: ItemsRepository
    associatedtype Qr: QrRepository
    associatedtype Search: SearchRepository

    var spaces: Spaces { get }
    var containers: Containers { get }
    var items: Items { get }
    var qr: Qr { get }
    var search: Search { get }
}
