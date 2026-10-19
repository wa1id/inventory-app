import Foundation
import InventoryCore
import InventoryNetwork
import InventoryStorage

/// Items on the home server (RN `createHttpRepositories(...).items`, httpRepositories.ts:219-316).
public struct HTTPItemsRepository: ItemsRepository {
    let client: HouseholdClient
    let photos: any PhotoStoring
    let photoCache: HouseholdPhotoCache
    let hydration: HouseholdPhotoHydration

    /// `GET /v1/items?containerId=`: a container's items, newest first, thumbnails made local.
    public func listByContainer(_ containerId: String) async throws -> [ItemWithContext] {
        await hydration.thumbnails(try await client.listItems(containerId: containerId))
    }

    /// `GET /v1/items?unsorted=1`: the drop zone, thumbnails made local.
    public func listUnsorted() async throws -> [ItemWithContext] {
        await hydration.thumbnails(try await client.listUnsortedItems())
    }

    /// `GET /v1/items?recent=1&limit=N`; the server clamps `limit` to 1…100.
    public func listRecent(limit: Int) async throws -> [ItemWithContext] {
        await hydration.thumbnails(try await client.listRecentItems(limit: limit))
    }

    /// The drop zone's size, from `GET /v1/items?unsorted=1`.
    ///
    /// RN counted `listUnsorted()`, which also downloaded every thumbnail just to count
    /// them (04 §6.1, Q5); the count is the same without them.
    public func countUnsorted() async throws -> Int {
        try await client.listUnsortedItems().count
    }

    /// `GET /v1/items/{id}`; nil on 404. The full photo and its thumbnail are made local.
    public func getById(_ id: String) async throws -> ItemWithContext? {
        guard let item = try await client.item(id: id) else { return nil }
        return await hydration.fullPhoto(item)
    }

    /// ``createWithContext(_:)``, as the repository protocol returns it.
    public func create(_ draft: ItemDraft) async throws -> Item {
        try await createWithContext(draft).item
    }

    /// Creates the item on the home server and returns it with its context, as the server read
    /// it back (RN `items.create`, httpRepositories.ts:248-269).
    ///
    /// With a local photo, its bytes go first as `PUT /v1/photos/<new id>` (raw octets, 60 s),
    /// then `POST /v1/items` carries the uploaded photo's reference. The draft's own photo id,
    /// size and byte count are never sent; the server's answer decides them. The answer is not
    /// hydrated: its photo URIs are the server's `r2:` strings, which is what the shadow copy
    /// stores. Afterwards the local capture's files are copied into the photo cache under the
    /// server's photo id, so the item shows at once.
    ///
    /// - Throws: `HouseholdHttpError(0, "photo_missing")` when the local photo file is gone;
    ///   the upload's or the create's error otherwise.
    public func createWithContext(_ draft: ItemDraft) async throws -> ItemWithContext {
        var uploaded: HouseholdUploadedPhoto?
        // RN `draft.photo?.uri ? … : null`: an empty URI is no photo.
        if let uri = draft.photo?.uri, !uri.isEmpty {
            guard let bytes = await photos.readStoredPhoto(uri) else {
                throw HouseholdHttpError(status: 0, code: "photo_missing")
            }
            uploaded = try await client.uploadPhoto(bytes)
        }
        let created = try await client.createItem(HouseholdBody.NewItem(
            containerId: draft.containerId,
            name: draft.name,
            category: draft.category,
            quantity: draft.quantity,
            notes: draft.notes,
            tags: draft.tags,
            photo: uploaded?.reference
        ))
        // RN: `typeof created.photoId === 'string' ? created.photoId : photo?.id`, then a truthiness check.
        if let photoId = created.photoId ?? uploaded?.id, !photoId.isEmpty,
           let photo = draft.photo, !photo.uri.isEmpty
        {
            await photoCache.remember(photoId: photoId, sourceURI: photo.uri, thumbURI: photo.thumbUri)
        }
        return created
    }

    /// `PATCH /v1/items/{id}`: the item row only, with `updatedAt` as the optimistic lock when
    /// given; nil on 404.
    ///
    /// RN quirk kept: `input.photo` is never sent; the household has no photo replacement.
    ///
    /// - Throws: ``ConflictError`` when `expectedUpdatedAt` is stale (409).
    public func update(_ id: String, _ input: UpdateItemInput) async throws -> Item? {
        try await client.updateItem(id: id, HouseholdBody.ItemPatch(
            containerId: input.containerId,
            name: input.name,
            category: input.category,
            quantity: input.quantity,
            notes: input.notes,
            tags: input.tags,
            expectedUpdatedAt: input.expectedUpdatedAt
        ))
    }

    /// The item's photo, from ``getById(_:)`` (so its files are made local): none without a
    /// photo id and URI, otherwise one photo with the hydrated URIs (a cache `file://` URI, or
    /// the server's `r2:` string when the download failed), no size, and the item's `createdAt`
    /// (RN httpRepositories.ts:287-302).
    public func getPhotos(_ itemId: String) async throws -> [ItemPhoto] {
        guard let item = try await getById(itemId),
              let photoId = item.photoId, !photoId.isEmpty,
              let uri = item.photoUri, !uri.isEmpty
        else { return [] }
        return [ItemPhoto(
            id: photoId,
            itemId: itemId,
            uri: uri,
            thumbUri: item.photoThumbUri,
            width: nil,
            height: nil,
            byteSize: nil,
            createdAt: item.createdAt
        )]
    }

    /// `DELETE /v1/items/{id}`; `deleted: false` on 404. Orphaned URIs are the server's `r2:`
    /// strings, which the local file deleter skips.
    public func delete(_ id: String) async throws -> DeletionResult {
        DeletionResult(try await client.deleteItem(id: id))
    }

    /// The sum of the spaces' item counts from `GET /v1/spaces`.
    ///
    /// RN quirk kept: the drop zone is not a listed space, so its items are not counted,
    /// unlike the local count (04 §6.1).
    public func countAll() async throws -> Int {
        try await client.listSpaces().reduce(0) { $0 + $1.itemCount }
    }
}

// MARK: - Photo hydration

/// Rewrites a household item's `r2:` photo URIs to local cache files (RN `hydrateItem`,
/// `hydrateThumb`, `hydrateItems`; 04 §6.2). A photo that cannot be fetched keeps the server's
/// value, and the row shows its placeholder.
struct HouseholdPhotoHydration: Sendable {
    /// Downloads at a time when hydrating a list. RN fetched every thumbnail at once; the
    /// result is the same, but a long list no longer queues dozens of requests behind the
    /// connection limit while their 20 s deadlines run.
    static let listConcurrency = 6

    let client: HouseholdClient
    let cache: HouseholdPhotoCache

    /// The item screen's photo: full image and thumbnail together (RN `hydrateItem`).
    /// Nothing to do without a photo id or when the full URI is already a local file.
    func fullPhoto(_ item: ItemWithContext) async -> ItemWithContext {
        guard let photoId = item.photoId, !photoId.isEmpty, !Self.isLocalFile(item.photoUri) else { return item }
        async let full = cache.resolve(photoId, kind: .full, client: client)
        async let thumb = cache.resolve(photoId, kind: .thumb, client: client)
        var hydrated = item
        hydrated.photoUri = await full ?? item.photoUri
        hydrated.photoThumbUri = await thumb ?? item.photoThumbUri
        return hydrated
    }

    /// List rows show only the thumbnail, so only it is fetched and `photoUri` stays the
    /// server's (RN `hydrateThumb`, `4fa33a6`: downloading every 1400 px photo made first loads
    /// slow). Rows without a photo id, or whose thumbnail is already a local file, are left alone.
    /// Order is kept.
    func thumbnails(_ items: [ItemWithContext]) async -> [ItemWithContext] {
        let pending = items.indices.compactMap { index -> Pending? in
            let item = items[index]
            guard let photoId = item.photoId, !photoId.isEmpty, !Self.isLocalFile(item.photoThumbUri) else { return nil }
            return Pending(index: index, photoId: photoId)
        }
        guard !pending.isEmpty else { return items }
        let client = client
        let cache = cache
        let resolved = await withTaskGroup(of: Resolved.self, returning: [Int: String].self) { group in
            var queue = pending.makeIterator()
            func start(_ next: Pending) {
                group.addTask { Resolved(index: next.index, uri: await cache.resolve(next.photoId, kind: .thumb, client: client)) }
            }
            for _ in 0..<Self.listConcurrency {
                guard let next = queue.next() else { break }
                start(next)
            }
            var uris: [Int: String] = [:]
            while let done = await group.next() {
                if let uri = done.uri { uris[done.index] = uri }
                // A read nobody waits for anymore starts no new downloads.
                if !Task.isCancelled, let next = queue.next() { start(next) }
            }
            return uris
        }
        var hydrated = items
        for (index, uri) in resolved {
            hydrated[index].photoThumbUri = uri
        }
        return hydrated
    }

    private struct Pending: Sendable {
        let index: Int
        let photoId: String
    }

    private struct Resolved: Sendable {
        let index: Int
        let uri: String?
    }

    /// JS `uri?.startsWith('file:')`, code unit for code unit.
    static func isLocalFile(_ uri: String?) -> Bool {
        uri?.utf8.starts(with: "file:".utf8) ?? false
    }
}
