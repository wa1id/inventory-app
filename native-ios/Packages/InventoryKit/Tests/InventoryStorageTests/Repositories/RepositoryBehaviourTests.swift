import Foundation
import GRDB
import InventoryCore
import Synchronization
import Testing
@testable import InventoryStorage

/// Ports `src/services/sync/__tests__/photoSync.test.ts:164,178` (the v4 tombstone trigger)
/// and 01 §13.8 #7.
@Suite("deletion tombstones")
struct TombstoneTests {
    /// RN `seed()` in photoSync.test.ts.
    private func seed() async throws -> (repos: LocalRepositories, itemId: String, spaceId: String) {
        let repos = try freshRepos()
        let (space, container) = try await seedSpaceAndContainer(repos)
        let item = try await repos.items.create(ItemDraft(containerId: container.id, name: "Drill", quantity: 1))
        return (repos, item.id, space.id)
    }

    /// RN `addPhoto()` in photoSync.test.ts.
    private func addPhoto(_ store: DatabaseStore, itemId: String, photoId: String, synced: Bool = false) throws {
        let now = epochMillis()
        try store.queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO item_photos (id, item_id, uri, thumb_uri, byte_size, created_at, remote_synced_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    photoId, itemId,
                    "file:///documents/item-photos/\(photoId).webp",
                    "file:///documents/item-photos/\(photoId)-thumb.webp",
                    3, now, synced ? now : nil,
                ]
            )
        }
    }

    private func tombstones(_ store: DatabaseStore) throws -> [String] {
        try store.queue.read { db in try String.fetchAll(db, sql: "SELECT photo_id FROM sync_deletions") }
    }

    @Test("records a tombstone when a synced photo is deleted by cascade")
    func tombstoneOnCascade() async throws {
        let (repos, itemId, _) = try await seed()
        try addPhoto(repos.store, itemId: itemId, photoId: "photo-a", synced: true)

        // Deleting the item cascades to item_photos: no repository deletes that row explicitly.
        let result = try await repos.items.delete(itemId)

        #expect(result.orphanedPhotoUris == [
            "file:///documents/item-photos/photo-a.webp", "file:///documents/item-photos/photo-a-thumb.webp",
        ])
        #expect(try tombstones(repos.store) == ["photo-a"])
    }

    @Test("records no tombstone for a photo that was never uploaded")
    func noTombstoneForUnsynced() async throws {
        let (repos, itemId, _) = try await seed()
        try addPhoto(repos.store, itemId: itemId, photoId: "photo-a")

        _ = try await repos.items.delete(itemId)

        #expect(try tombstones(repos.store).isEmpty)
    }

    @Test("records a tombstone when deleting a space cascades down to a synced photo")
    func tombstoneOnSpaceCascade() async throws {
        let (repos, itemId, spaceId) = try await seed()
        try addPhoto(repos.store, itemId: itemId, photoId: "photo-a", synced: true)
        try addPhoto(repos.store, itemId: itemId, photoId: "photo-b")

        _ = try await repos.spaces.delete(spaceId)

        #expect(try tombstones(repos.store) == ["photo-a"])
    }

    @Test("records a tombstone when an update replaces a synced photo")
    func tombstoneOnPhotoReplace() async throws {
        let (repos, itemId, _) = try await seed()
        try addPhoto(repos.store, itemId: itemId, photoId: "photo-a", synced: true)

        _ = try await repos.items.update(itemId, UpdateItemInput(photo: .set(ItemPhotoInput(id: "ignored", uri: "file:///new.webp"))))

        #expect(try tombstones(repos.store) == ["photo-a"])
        let photos = try await repos.items.getPhotos(itemId)
        #expect(photos.count == 1)
        #expect(photos.first?.uri == "file:///new.webp")
        // An update always assigns a new id; any id in the input is ignored (01 §12.4).
        #expect(photos.first?.id != "ignored")
        #expect(photos.first?.id != "photo-a")
    }
}

/// Behaviours 01 §7 and §12 pin that the RN suites leave implicit (01 §13.8 #5, #8, #12, #13).
@Suite("repository behaviours")
struct RepositoryBehaviourTests {
    @Test("an unknown space retries ten times, then reports the short-code error (Q5 parity)")
    func unknownSpaceReportsShortCodeError() async throws {
        let attempts = Locked(0)
        let environment = RepositoryEnvironment(shortCode: { type in
            attempts.update { $0 += 1 }
            return generateShortCode(type)
        })
        let repos = try freshRepos(environment: environment)

        await #expect(throws: InventoryError.shortCodeExhausted) {
            try await repos.containers.create(CreateContainerInput(spaceId: "no-such-space", visualType: .box))
        }
        #expect(attempts.value == 10)
    }

    @Test("a short-code collision retries with a new code and a new id")
    func retriesOnCollision() async throws {
        let codes = Locked(["BOX-AAAA", "BOX-AAAA", "BOX-AAAA", "BOX-BBBB"])
        let environment = RepositoryEnvironment(shortCode: { _ in codes.update { $0.removeFirst() } })
        let repos = try freshRepos(environment: environment)
        let space = try await repos.spaces.create(CreateSpaceInput(name: "Shed", icon: "box", color: "#5B8DEF"))

        let first = try await repos.containers.create(CreateContainerInput(spaceId: space.id, visualType: .box))
        let second = try await repos.containers.create(CreateContainerInput(spaceId: space.id, visualType: .box))

        #expect(first.shortCode == "BOX-AAAA")
        #expect(second.shortCode == "BOX-BBBB")
        #expect(first.id != second.id)
        #expect(try count(repos.store, "containers") == 3)
    }

    @Test("ten collisions in a row give up")
    func tenCollisionsGiveUp() async throws {
        let environment = RepositoryEnvironment(shortCode: { _ in "BOX-AAAA" })
        let repos = try freshRepos(environment: environment)
        let space = try await repos.spaces.create(CreateSpaceInput(name: "Shed", icon: "box", color: "#5B8DEF"))
        _ = try await repos.containers.create(CreateContainerInput(spaceId: space.id, visualType: .box))

        await #expect(throws: InventoryError.shortCodeExhausted) {
            try await repos.containers.create(CreateContainerInput(spaceId: space.id, visualType: .box))
        }
    }

    @Test("an optimistic update of a row that vanished returns nil, not a conflict")
    func vanishedRowIsNotAConflict() async throws {
        let repos = try freshRepos()
        #expect(try await repos.items.update("missing", UpdateItemInput(quantity: 2, expectedUpdatedAt: 5)) == nil)
    }

    @Test("an update applies when expectedUpdatedAt matches")
    func matchingLockApplies() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        let item = try await repos.items.create(ItemDraft(containerId: container.id, name: "Drill"))
        let updated = try await repos.items.update(item.id, UpdateItemInput(quantity: 4, expectedUpdatedAt: item.updatedAt))
        #expect(updated?.quantity == 4)
    }

    @Test("a conflict writes nothing: tags and photo stay as they were")
    func conflictWritesNothing() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        let item = try await repos.items.create(ItemDraft(
            containerId: container.id, name: "Drill", tags: ["keep"], photo: ItemPhotoInput(uri: "file:///keep.webp")
        ))

        await #expect(throws: ConflictError.self) {
            try await repos.items.update(item.id, UpdateItemInput(
                name: "Changed", tags: ["lost"], photo: .clear, expectedUpdatedAt: item.updatedAt - 1
            ))
        }
        let stored = try await repos.items.getById(item.id)
        #expect(stored?.name == "Drill")
        #expect(stored?.tags == ["keep"])
        #expect(stored?.photoUri == "file:///keep.webp")
    }

    @Test("a container can be moved into the drop zone's space (no guard, 01 Q11)")
    func containerIntoDropZoneSpace() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        let moved = try await repos.containers.update(container.id, UpdateContainerInput(spaceId: DropZone.spaceId))
        #expect(moved?.spaceId == DropZone.spaceId)
    }

    @Test("binding to a missing container throws and keeps the previous bindings")
    func bindMissingContainerKeepsBindings() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        let binding = try await repos.qr.createAndBind(container.id)

        await #expect(throws: DatabaseError.self) {
            try await repos.qr.bind(token: binding.token, containerId: "no-such-container")
        }
        #expect(try await repos.qr.getByToken(binding.token) == binding)
    }

    @Test("the drop-zone rows refuse every change", arguments: [0, 1, 2, 3, 4])
    func dropZoneGuards(_ operation: Int) async throws {
        let repos = try freshRepos()
        await #expect(throws: InventoryError.systemRecord) {
            switch operation {
            case 0: _ = try await repos.spaces.update(DropZone.spaceId, UpdateSpaceInput(name: "Mine"))
            case 1: _ = try await repos.spaces.delete(DropZone.spaceId)
            case 2: _ = try await repos.containers.update(DropZone.containerId, UpdateContainerInput(name: .set("Mine")))
            case 3: _ = try await repos.containers.delete(DropZone.containerId)
            default: _ = try await repos.qr.createAndBind(DropZone.containerId)
            }
        }
        #expect(try await repos.spaces.getById(DropZone.spaceId)?.name == "Drop zone")
        #expect(try await repos.containers.getById(DropZone.containerId)?.name == "Drop zone")
        #expect(InventoryError.systemRecord.message == "system_record")
    }

    @Test("the drop zone stays readable by id and through getWithCounts")
    func dropZoneReadable() async throws {
        let repos = try freshRepos()
        _ = try await repos.items.create(ItemDraft(containerId: DropZone.containerId, name: "Cable"))
        let dropZone = try await repos.containers.getWithCounts(DropZone.containerId)
        #expect(dropZone?.itemCount == 1)
        #expect(dropZone?.shortCode == "DROP-ZONE")
        #expect(try await repos.containers.listAllWithSpace().isEmpty)
        #expect(try await repos.items.listRecent().map(\.name) == ["Cable"])
        #expect(try await repos.qr.unbind(DropZone.containerId) == false)
    }

    @Test("a provided blank space name is saved as an empty string")
    func blankSpaceName() async throws {
        let repos = try freshRepos()
        let space = try await repos.spaces.create(CreateSpaceInput(name: "Shed", icon: "box", color: "#5B8DEF"))
        let renamed = try await repos.spaces.update(space.id, UpdateSpaceInput(name: "  "))
        #expect(renamed?.name == "")
        #expect(try await repos.spaces.getById(space.id)?.name == "")
        #expect(try await repos.spaces.update("missing", UpdateSpaceInput(name: "x")) == nil)
    }

    @Test("a container keeps its short code when its type changes; name patches are tri-state")
    func containerPatch() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)

        let named = try await repos.containers.update(container.id, UpdateContainerInput(name: .set("  Tool chest "), visualType: .drawer))
        #expect(named?.name == "Tool chest")
        #expect(named?.visualType == .drawer)
        #expect(named?.shortCode == container.shortCode)

        let kept = try await repos.containers.update(container.id, UpdateContainerInput())
        #expect(kept?.name == "Tool chest")

        let blank = try await repos.containers.update(container.id, UpdateContainerInput(name: .set("   ")))
        #expect(blank?.name == nil)

        _ = try await repos.containers.update(container.id, UpdateContainerInput(name: .set("Again")))
        let cleared = try await repos.containers.update(container.id, UpdateContainerInput(name: .clear))
        #expect(cleared?.name == nil)
        #expect(try await repos.containers.getById(container.id)?.name == nil)
        #expect(try await repos.containers.update("missing", UpdateContainerInput()) == nil)
    }

    @Test("an unknown visual type round-trips unchanged")
    func unknownVisualType() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        try await repos.store.queue.write { db in
            try db.execute(sql: "UPDATE containers SET visual_type = 'Trunk' WHERE id = ?", arguments: [container.id])
        }
        let stored = try #require(try await repos.containers.getById(container.id))
        #expect(stored.visualType.rawValue == "Trunk")
        let renamed = try await repos.containers.update(container.id, UpdateContainerInput(name: .set("Old trunk")))
        #expect(renamed?.visualType.rawValue == "Trunk")
        #expect(try await repos.containers.getById(container.id)?.visualType.rawValue == "Trunk")
    }

    @Test("quantity is checked before the name")
    func quantityBeforeName() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        await #expect(throws: InventoryError.invalidQuantity) {
            try await repos.items.create(ItemDraft(containerId: container.id, name: "  ", quantity: -1))
        }
        let item = try await repos.items.create(ItemDraft(containerId: container.id, name: "Drill"))
        await #expect(throws: InventoryError.invalidQuantity) {
            try await repos.items.update(item.id, UpdateItemInput(name: "  ", quantity: -1))
        }
    }

    @Test("quantities above 9999 are stored unclamped")
    func noUpperBound() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        let item = try await repos.items.create(ItemDraft(containerId: container.id, name: "Screws", quantity: 12_345))
        #expect(try await repos.items.getById(item.id)?.quantity == 12_345)
    }

    @Test("category and notes: trimmed, blank stored as NULL, patches keep, clear or replace")
    func categoryAndNotes() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        let item = try await repos.items.create(ItemDraft(
            containerId: container.id, name: " Drill ", category: "  ", notes: " In the case "
        ))
        #expect(item.name == "Drill")
        #expect(item.category == nil)
        #expect(item.notes == "In the case")

        let set = try await repos.items.update(item.id, UpdateItemInput(category: .set(" Tools ")))
        #expect(set?.category == "Tools")
        #expect(set?.notes == "In the case")

        let cleared = try await repos.items.update(item.id, UpdateItemInput(category: .clear, notes: .set("   ")))
        #expect(cleared?.category == nil)
        #expect(cleared?.notes == nil)
        let stored = try #require(try await repos.items.getById(item.id))
        #expect(stored.category == nil)
        #expect(stored.notes == nil)
    }

    @Test("every update rewrites search_text with JS trimming and lowercasing")
    func searchTextRewritten() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        let item = try await repos.items.create(ItemDraft(containerId: container.id, name: "ÄRMEL ΟΔΟΣ", category: "\u{FEFF}Kleidung "))
        func searchText() throws -> String? {
            try repos.store.queue.read { db in
                try String.fetchOne(db, sql: "SELECT search_text FROM items WHERE id = ?", arguments: [item.id])
            }
        }
        #expect(try searchText() == itemSearchText(name: "ÄRMEL ΟΔΟΣ", category: "Kleidung"))
        #expect(try searchText() == "ärmel οδος kleidung")

        // A pre-v2 backfill left ASCII-only lowercase; a quantity tap rewrites it (01 §3.2 v2).
        try await repos.store.queue.write { db in
            try db.execute(sql: "UPDATE items SET search_text = 'Ärmel ΟΔΟΣ kleidung' WHERE id = ?", arguments: [item.id])
        }
        _ = try await repos.items.update(item.id, UpdateItemInput(quantity: 3))
        #expect(try searchText() == "ärmel οδος kleidung")
    }

    @Test("tags keep the first spelling ever saved and dedupe by their folded form")
    func tagSpelling() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        let first = try await repos.items.create(ItemDraft(containerId: container.id, name: "Drill", tags: ["DeWalt"]))
        let second = try await repos.items.create(ItemDraft(
            containerId: container.id, name: "Saw", tags: [" dewalt ", "DEWALT", "", "   ", "Bosch"]
        ))

        #expect(try await repos.items.getById(first.id)?.tags == ["DeWalt"])
        #expect(try await repos.items.getById(second.id)?.tags.sorted() == ["Bosch", "DeWalt"])
        #expect(try count(repos.store, "tags") == 2)

        // `[]` clears every link; the vocabulary stays.
        _ = try await repos.items.update(second.id, UpdateItemInput(tags: []))
        #expect(try await repos.items.getById(second.id)?.tags == [])
        #expect(try count(repos.store, "tags") == 2)
    }

    @Test("tag dedupe compares code points, like a JS Set")
    func tagDedupeByCodePoints() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        // Precomposed and decomposed é are equal Swift Strings but different JS strings.
        let item = try await repos.items.create(ItemDraft(
            containerId: container.id, name: "Mug", tags: ["caf\u{E9}", "cafe\u{301}"]
        ))
        let names = try await repos.store.queue.read { db in
            try String.fetchAll(db, sql: "SELECT normalized_name FROM tags ORDER BY rowid")
        }
        #expect(names.map { Array($0.unicodeScalars) } == [Array("caf\u{E9}".unicodeScalars), Array("cafe\u{301}".unicodeScalars)])
        #expect(try await repos.items.getById(item.id)?.tags.count == 2)
    }

    @Test("an omitted name is stored as an empty string")
    func omittedName() async throws {
        let repos = try freshRepos()
        let item = try await repos.items.create(ItemDraft(containerId: DropZone.containerId))
        #expect(item.name == "")
        #expect(item.quantity == 1)
        let named = try await repos.items.update(item.id, UpdateItemInput(name: " Cable ", expectedUpdatedAt: item.updatedAt))
        #expect(named?.name == "Cable")
    }

    @Test("a create photo keeps its given id; clearing the photo removes it")
    func photoIds() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        let item = try await repos.items.create(ItemDraft(
            containerId: container.id, name: "Drill",
            photo: ItemPhotoInput(id: "r2-object", uri: "r2:household/primary/photos/r2-object.webp", thumbUri: "t", width: 1, height: 2, byteSize: 3)
        ))
        let photos = try await repos.items.getPhotos(item.id)
        #expect(photos == [ItemPhoto(
            id: "r2-object", itemId: item.id, uri: "r2:household/primary/photos/r2-object.webp",
            thumbUri: "t", width: 1, height: 2, byteSize: 3, createdAt: item.createdAt
        )])

        _ = try await repos.items.update(item.id, UpdateItemInput(photo: .clear))
        #expect(try await repos.items.getPhotos(item.id).isEmpty)
        #expect(try await repos.items.getById(item.id)?.photoId == nil)
    }

    @Test("the earliest photo is the primary one")
    func earliestPhotoIsPrimary() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        let item = try await repos.items.create(ItemDraft(containerId: container.id, name: "Drill", photo: ItemPhotoInput(id: "first", uri: "file:///a.webp")))
        try await repos.store.queue.write { db in
            try db.execute(
                sql: "INSERT INTO item_photos (id, item_id, uri, created_at) VALUES ('later', ?, 'file:///b.webp', ?)",
                arguments: [item.id, item.createdAt + 10]
            )
        }
        let stored = try await repos.items.getById(item.id)
        #expect(stored?.photoId == "first")
        #expect(try await repos.items.getPhotos(item.id).map(\.id) == ["first", "later"])
    }

    @Test("listRecent clamps its limit to 1…100")
    func listRecentClamps() async throws {
        let clock = TickingClock()
        let repos = try freshRepos(environment: RepositoryEnvironment(now: { clock.now() }))
        let (_, container) = try await seedSpaceAndContainer(repos)
        for index in 0..<105 {
            _ = try await repos.items.create(ItemDraft(containerId: container.id, name: "Item \(index)"))
        }
        #expect(try await repos.items.listRecent(limit: 0).map(\.name) == ["Item 104"])
        #expect(try await repos.items.listRecent(limit: -5).count == 1)
        #expect(try await repos.items.listRecent(limit: 3).map(\.name) == ["Item 104", "Item 103", "Item 102"])
        #expect(try await repos.items.listRecent().count == 40)
        #expect(try await repos.items.listRecent(limit: 1000).count == 100)
        #expect(try await repos.items.countAll() == 105)
    }

    @Test("the injected clock and id source stamp the rows")
    func injectedEnvironment() async throws {
        final class Counting: RandomByteSource {
            let next = Locked<UInt8>(0)
            func randomBytes(count: Int) -> [UInt8] {
                next.update { value in
                    value &+= 1
                    return [UInt8](repeating: value, count: count)
                }
            }
        }
        let repos = try freshRepos(environment: RepositoryEnvironment(now: { 42 }, randomBytes: Counting()))
        let space = try await repos.spaces.create(CreateSpaceInput(name: "Shed", icon: "box", color: "#5B8DEF"))
        #expect(space.createdAt == 42)
        #expect(space.id == "01010101-0101-4101-8101-010101010101")
        let container = try await repos.containers.create(CreateContainerInput(spaceId: space.id, visualType: .box))
        let binding = try await repos.qr.createAndBind(container.id)
        #expect(binding.token == String(repeating: "03", count: 16))
    }

    @Test("repository cores compose inside one transaction and roll back together")
    func coresCompose() async throws {
        let repos = try freshRepos()
        struct Abort: Error {}
        #expect(throws: Abort.self) {
            try repos.store.queue.write { db in
                let space = try repos.spaces.create(CreateSpaceInput(name: "Attic", icon: "box", color: "#000000"), in: db)
                let container = try repos.containers.create(CreateContainerInput(spaceId: space.id, visualType: .box), in: db)
                _ = try repos.items.create(ItemDraft(containerId: container.id, name: "Lamp", tags: ["light"]), in: db)
                _ = try repos.qr.createAndBind(container.id, in: db)
                throw Abort()
            }
        }
        #expect(try count(repos.store, "spaces") == 1)
        #expect(try count(repos.store, "items") == 0)
        #expect(try count(repos.store, "tags") == 0)
        #expect(try count(repos.store, "qr_bindings") == 0)
    }

    @Test("deleting something already gone reports nothing deleted")
    func deleteMissing() async throws {
        let repos = try freshRepos()
        #expect(try await repos.items.delete("missing") == .notDeleted)
        #expect(try await repos.containers.delete("missing") == .notDeleted)
        #expect(try await repos.spaces.delete("missing") == .notDeleted)
        #expect(try await repos.spaces.deletionImpact("missing") == SpaceDeletionImpact(
            containerCount: 0, itemCount: 0, photoCount: 0, qrBindingCount: 0
        ))
        #expect(try await repos.containers.deletionImpact("missing") == ContainerDeletionImpact(
            itemCount: 0, photoCount: 0, hasQrBinding: false
        ))
    }

    @Test("orphaned photo URIs list full and thumbnail files, dropping NULL thumbnails")
    func orphanedUris() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        _ = try await repos.items.create(ItemDraft(
            containerId: container.id, name: "A", photo: ItemPhotoInput(uri: "file:///a.webp", thumbUri: "file:///a-thumb.webp")
        ))
        _ = try await repos.items.create(ItemDraft(containerId: container.id, name: "B", photo: ItemPhotoInput(uri: "file:///b.jpg")))
        #expect(try await repos.containers.deletionImpact(container.id) == ContainerDeletionImpact(
            itemCount: 2, photoCount: 2, hasQrBinding: false
        ))

        let result = try await repos.containers.delete(container.id)
        #expect(result.deleted)
        #expect(result.orphanedPhotoUris.sorted() == ["file:///a-thumb.webp", "file:///a.webp", "file:///b.jpg"])
    }
}
