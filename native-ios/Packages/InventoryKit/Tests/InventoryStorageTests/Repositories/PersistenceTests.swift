import Foundation
import GRDB
import InventoryCore
import InventoryTestSupport
import Testing
@testable import InventoryStorage

// Ports `src/db/__tests__/persistence.test.ts` (spaces, drop zone, containers,
// items, qr bindings, data durability). The migrations suite is in MigrationTests.

@Suite("spaces")
struct SpacesPersistenceTests {
    @Test("creates, reads back, and updates without changing identity")
    func createReadUpdate() async throws {
        let repos = try freshRepos()
        let created = try await repos.spaces.create(CreateSpaceInput(name: "  Attic  ", icon: "box", color: "#E4572E"))

        #expect(created.name == "Attic")

        let renamed = try await repos.spaces.update(created.id, UpdateSpaceInput(name: "Loft", color: "#2E9E4F"))

        #expect(renamed?.id == created.id)
        #expect(renamed?.name == "Loft")
        #expect(renamed?.createdAt == created.createdAt)

        let fetched = try await repos.spaces.getById(created.id)
        #expect(fetched?.name == "Loft")
    }

    @Test("reports container and item counts on the dashboard query")
    func dashboardCounts() async throws {
        let repos = try freshRepos()
        let (space, container) = try await seedSpaceAndContainer(repos)
        _ = try await repos.items.create(ItemDraft(containerId: container.id, name: "Hammer"))
        _ = try await repos.items.create(ItemDraft(containerId: container.id, name: "Wrench"))

        let dashboard = try await repos.spaces.listWithCounts().first

        #expect(dashboard?.id == space.id)
        #expect(dashboard?.containerCount == 1)
        #expect(dashboard?.itemCount == 2)
    }

    @Test("describes deletion impact before deleting")
    func deletionImpact() async throws {
        let repos = try freshRepos()
        let (space, container) = try await seedSpaceAndContainer(repos)
        _ = try await repos.items.create(ItemDraft(
            containerId: container.id,
            name: "Drill",
            photo: ItemPhotoInput(uri: "file:///photos/drill.jpg")
        ))
        _ = try await repos.qr.createAndBind(container.id)

        let impact = try await repos.spaces.deletionImpact(space.id)

        #expect(impact == SpaceDeletionImpact(containerCount: 1, itemCount: 1, photoCount: 1, qrBindingCount: 1))
    }

    @Test("cascades deletion to containers, items, photos, and QR bindings")
    func cascadesDeletion() async throws {
        let repos = try freshRepos()
        let (space, container) = try await seedSpaceAndContainer(repos)
        _ = try await repos.items.create(ItemDraft(
            containerId: container.id,
            name: "Drill",
            photo: ItemPhotoInput(uri: "file:///photos/drill.jpg")
        ))
        _ = try await repos.qr.createAndBind(container.id)

        let result = try await repos.spaces.delete(space.id)

        #expect(result.deleted)
        #expect(result.orphanedPhotoUris == ["file:///photos/drill.jpg"])
        // The system drop-zone container is seeded by migration 3 and survives.
        #expect(try count(repos.store, "containers") == 1)
        #expect(try count(repos.store, "items") == 0)
        #expect(try count(repos.store, "item_photos") == 0)
        #expect(try count(repos.store, "qr_bindings") == 0)
    }
}

@Suite("drop zone")
struct DropZonePersistenceTests {
    @Test("collects items captured without a container and keeps them out of the dashboard")
    func collectsUnsorted() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)

        _ = try await repos.items.create(ItemDraft(containerId: DropZone.containerId, name: "Mystery cable"))
        _ = try await repos.items.create(ItemDraft(containerId: container.id, name: "Drill"))

        #expect(try await repos.items.countUnsorted() == 1)
        #expect(try await repos.items.listUnsorted().map(\.name) == ["Mystery cable"])

        // The holding area is not a place you browse to.
        let spaces = try await repos.spaces.listWithCounts()
        #expect(!spaces.map(\.id).contains("drop-zone-space"))
    }

    @Test("empties as items are moved into a real container")
    func emptiesOnMove() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        let item = try await repos.items.create(ItemDraft(containerId: DropZone.containerId, name: "Mystery cable"))

        _ = try await repos.items.update(item.id, UpdateItemInput(containerId: container.id))

        #expect(try await repos.items.countUnsorted() == 0)
        #expect(try await repos.items.listByContainer(container.id).map(\.name).contains("Mystery cable"))
    }

    @Test("files an unnamed capture without demanding a name first")
    func filesUnnamedCapture() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        let item = try await repos.items.create(ItemDraft(containerId: DropZone.containerId))

        // Moving must not re-validate a name the item was never given.
        let moved = try await repos.items.update(item.id, UpdateItemInput(containerId: container.id))
        #expect(moved?.containerId == container.id)
        #expect(moved?.name == "")
        #expect(try await repos.items.countUnsorted() == 0)
    }

    @Test("still rejects an explicitly blank name on update")
    func rejectsBlankNameOnUpdate() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        let item = try await repos.items.create(ItemDraft(containerId: container.id, name: "Drill"))

        await #expect(throws: InventoryError.nameRequired) {
            try await repos.items.update(item.id, UpdateItemInput(name: "  "))
        }
        #expect(InventoryError.nameRequired.message.contains("name is required"))
    }

    @Test("survives deleting every user space")
    func survivesDeletingSpaces() async throws {
        let repos = try freshRepos()
        let (space, _) = try await seedSpaceAndContainer(repos)
        _ = try await repos.items.create(ItemDraft(containerId: DropZone.containerId, name: "Mystery cable"))

        _ = try await repos.spaces.delete(space.id)

        #expect(try await repos.items.countUnsorted() == 1)
    }
}

@Suite("containers")
struct ContainersPersistenceTests {
    @Test("assigns a unique, human-friendly short code")
    func uniqueShortCodes() async throws {
        let repos = try freshRepos()
        let space = try await repos.spaces.create(CreateSpaceInput(name: "Shed", icon: "box", color: "#5B8DEF"))

        let first = try await repos.containers.create(CreateContainerInput(spaceId: space.id, visualType: .box))
        let second = try await repos.containers.create(CreateContainerInput(spaceId: space.id, visualType: .drawer))

        #expect(first.shortCode.wholeMatch(of: /BOX-[A-Z0-9]{4}/) != nil)
        #expect(second.shortCode.wholeMatch(of: /DRW-[A-Z0-9]{4}/) != nil)
        #expect(first.shortCode != second.shortCode)
    }

    @Test("stores a blank name as null rather than an empty string")
    func blankNameIsNull() async throws {
        let repos = try freshRepos()
        let space = try await repos.spaces.create(CreateSpaceInput(name: "Shed", icon: "box", color: "#5B8DEF"))

        let container = try await repos.containers.create(
            CreateContainerInput(spaceId: space.id, name: "   ", visualType: .box)
        )

        #expect(container.name == nil)
        let stored = try await repos.containers.getById(container.id)
        #expect(stored?.name == nil)
    }

    @Test("refuses to attach a container to a space that does not exist")
    func refusesUnknownSpace() async throws {
        let repos = try freshRepos()

        await #expect(throws: (any Error).self) {
            try await repos.containers.create(CreateContainerInput(spaceId: "no-such-space", visualType: .box))
        }
    }

    @Test("moves a container to another space")
    func movesToAnotherSpace() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        let target = try await repos.spaces.create(CreateSpaceInput(name: "Basement", icon: "box", color: "#2E9E4F"))

        let moved = try await repos.containers.update(container.id, UpdateContainerInput(spaceId: target.id))

        #expect(moved?.spaceId == target.id)
        let inTarget = try await repos.containers.listBySpace(target.id)
        #expect(inTarget.count == 1)
    }

    @Test("keeps item counts current as items come and go")
    func itemCountsFollow() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)

        let item = try await repos.items.create(ItemDraft(containerId: container.id, name: "Saw"))
        #expect(try await repos.containers.getWithCounts(container.id)?.itemCount == 1)

        _ = try await repos.items.delete(item.id)
        #expect(try await repos.containers.getWithCounts(container.id)?.itemCount == 0)
    }
}

@Suite("items")
struct ItemsPersistenceTests {
    @Test("creates an item with photo and tags atomically")
    func createsWithPhotoAndTags() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)

        let item = try await repos.items.create(ItemDraft(
            containerId: container.id,
            name: "Cordless Drill",
            category: "Tools",
            quantity: 2,
            notes: "Charger in side pocket",
            tags: ["power tool", "DeWalt", "power tool"],
            photo: ItemPhotoInput(uri: "file:///photos/drill.jpg", width: 1024, height: 768, byteSize: 210_000)
        ))

        let stored = try await repos.items.getById(item.id)

        #expect(stored?.name == "Cordless Drill")
        #expect(stored?.quantity == 2)
        #expect(stored?.photoUri == "file:///photos/drill.jpg")
        #expect(stored?.photoId?.wholeMatch(of: /[0-9a-f-]{36}/) != nil)
        // Duplicate tag names collapse to one link.
        #expect(stored?.tags.sorted() == ["DeWalt", "power tool"])
        #expect(stored?.spaceName == "Garage")
    }

    @Test("accepts quantity 0 so an item can stay filed with none currently there")
    func acceptsZeroQuantity() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)

        let item = try await repos.items.create(ItemDraft(containerId: container.id, name: "Nails", quantity: 0))
        #expect(item.quantity == 0)
        #expect(try await repos.items.getById(item.id)?.quantity == 0)

        let updated = try await repos.items.update(item.id, UpdateItemInput(quantity: 1))
        #expect(updated?.quantity == 1)
        let emptied = try await repos.items.update(item.id, UpdateItemInput(quantity: 0))
        #expect(emptied?.quantity == 0)
    }

    @Test("rejects a negative quantity")
    func rejectsNegativeQuantity() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)

        await #expect(throws: InventoryError.invalidQuantity) {
            try await repos.items.create(ItemDraft(containerId: container.id, name: "Nails", quantity: -1))
        }
        #expect(InventoryError.invalidQuantity.message.contains("0 or more"))
    }

    @Test("rejects an empty name")
    func rejectsEmptyName() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)

        await #expect(throws: InventoryError.nameRequired) {
            try await repos.items.create(ItemDraft(containerId: container.id, name: "   "))
        }
    }

    @Test("rolls the whole draft back when part of it fails")
    func rollsBackWholeDraft() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        let now = epochMillis()

        // A CHECK violation inside the transaction must leave nothing behind (01 §13.8 #12).
        #expect(throws: DatabaseError.self) {
            try repos.store.queue.write { db in
                _ = try repos.items.create(ItemDraft(containerId: container.id, name: "Valid Item"), in: db)
                try db.execute(
                    sql: """
                        INSERT INTO items (id, container_id, name, quantity, created_at, updated_at, search_text)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: ["bad", container.id, "Bad Item", -5, now, now, "bad item"]
                )
            }
        }

        #expect(try count(repos.store, "items") == 0)
    }

    @Test("updates fields and replaces tags without changing identity")
    func updatesAndReplacesTags() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        let item = try await repos.items.create(ItemDraft(containerId: container.id, name: "Drill", tags: ["old"]))

        let updated = try await repos.items.update(item.id, UpdateItemInput(name: "Impact Drill", tags: ["new"]))

        #expect(updated?.id == item.id)
        #expect(updated?.createdAt == item.createdAt)
        let stored = try await repos.items.getById(item.id)
        #expect(stored?.tags == ["new"])
    }

    @Test("rejects an update when expectedUpdatedAt does not match")
    func rejectsStaleUpdate() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        let item = try await repos.items.create(ItemDraft(containerId: container.id, name: "Drill"))
        let once = try #require(try await repos.items.update(item.id, UpdateItemInput(name: "Once")))

        do {
            _ = try await repos.items.update(item.id, UpdateItemInput(name: "Twice", expectedUpdatedAt: 1))
            Issue.record("expected a ConflictError")
        } catch let error as ConflictError {
            #expect(error.status == 409)
            #expect(error.code == "conflict")
            #expect(error.updatedAt == once.updatedAt)
        }

        #expect(try await repos.items.getById(item.id)?.name == "Once")
    }

    @Test("removes photo and tag rows when an item is deleted")
    func deleteRemovesPhotoAndTagRows() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        let item = try await repos.items.create(ItemDraft(
            containerId: container.id,
            name: "Drill",
            tags: ["tools"],
            photo: ItemPhotoInput(uri: "file:///photos/drill.jpg")
        ))

        let result = try await repos.items.delete(item.id)

        #expect(result.deleted)
        #expect(result.orphanedPhotoUris == ["file:///photos/drill.jpg"])
        #expect(try count(repos.store, "item_photos") == 0)
        #expect(try count(repos.store, "item_tags") == 0)
        // The tag vocabulary itself survives for reuse by other items.
        #expect(try count(repos.store, "tags") == 1)
    }

    @Test("cannot be created in a container that does not exist")
    func refusesUnknownContainer() async throws {
        let repos = try freshRepos()

        await #expect(throws: DatabaseError.self) {
            try await repos.items.create(ItemDraft(containerId: "nope", name: "Ghost"))
        }
        #expect(try count(repos.store, "items") == 0)
    }
}

@Suite("qr bindings")
struct QrPersistenceTests {
    @Test("resolves a bound token to its container")
    func resolvesBoundToken() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        let binding = try await repos.qr.createAndBind(container.id)

        let outcome = try await repos.qr.resolveScan("inventory://c/\(binding.token)")

        guard case .bound(let bound, let token) = outcome else {
            Issue.record("expected bound, got \(outcome)")
            return
        }
        #expect(bound.id == container.id)
        #expect(token == binding.token)
    }

    @Test("reports an unknown but well-formed token so it can be bound")
    func reportsUnknownToken() async throws {
        let repos = try freshRepos()
        let outcome = try await repos.qr.resolveScan(String(repeating: "a", count: 32))
        #expect(outcome == .unknown(token: String(repeating: "a", count: 32)))
    }

    @Test("rejects codes that are not ours")
    func rejectsForeignCodes() async throws {
        let repos = try freshRepos()
        #expect(try await repos.qr.resolveScan("https://example.com") == .invalid(raw: "https://example.com"))
        #expect(try await repos.qr.resolveScan("") == .invalid(raw: ""))
    }

    @Test("replaces the previous binding when a token is rebound")
    func rebindsToken() async throws {
        let repos = try freshRepos()
        let (space, container) = try await seedSpaceAndContainer(repos)
        let other = try await repos.containers.create(CreateContainerInput(spaceId: space.id, visualType: .bin))
        let binding = try await repos.qr.createAndBind(container.id)

        _ = try await repos.qr.bind(token: binding.token, containerId: other.id)

        let outcome = try await repos.qr.resolveScan(binding.token)
        guard case .bound(let bound, _) = outcome else {
            Issue.record("expected bound, got \(outcome)")
            return
        }
        #expect(bound.id == other.id)
        // Exactly one binding survives: the label points at one container only.
        #expect(try count(repos.store, "qr_bindings") == 1)
    }

    @Test("replaces a container previous token when a new one is bound to it")
    func replacesContainerToken() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        let first = try await repos.qr.createAndBind(container.id)
        let second = try await repos.qr.createAndBind(container.id)

        #expect(try await repos.qr.resolveScan(first.token) == .unknown(token: first.token))
        guard case .bound = try await repos.qr.resolveScan(second.token) else {
            Issue.record("expected the second token to be bound")
            return
        }
    }

    @Test("unbinding keeps the container and its items")
    func unbindKeepsContainer() async throws {
        let repos = try freshRepos()
        let (_, container) = try await seedSpaceAndContainer(repos)
        _ = try await repos.items.create(ItemDraft(containerId: container.id, name: "Drill"))
        _ = try await repos.qr.createAndBind(container.id)

        #expect(try await repos.qr.unbind(container.id))

        #expect(try await repos.containers.getById(container.id) != nil)
        #expect(try count(repos.store, "items") == 1)
        #expect(try count(repos.store, "qr_bindings") == 0)
        #expect(try await repos.qr.unbind(container.id) == false)
    }
}

@Suite("data durability")
struct DurabilityTests {
    @Test("keeps inventory after closing and reopening the database file")
    func survivesReopen() async throws {
        let scratch = try TemporaryDirectory()
        let path = scratch.path("inventory-test.db")

        let first = try await LocalRepositories.initialize(DatabaseStore(path: path))
        let (_, container) = try await seedSpaceAndContainer(first)
        _ = try await first.items.create(ItemDraft(containerId: container.id, name: "Survivor"))
        try first.store.close()

        // Simulates process death followed by a cold start.
        let reopened = try await LocalRepositories.initialize(DatabaseStore(path: path))
        let items = try await reopened.items.listByContainer(container.id)

        #expect(items.map(\.name) == ["Survivor"])
        try reopened.store.close()
    }
}
