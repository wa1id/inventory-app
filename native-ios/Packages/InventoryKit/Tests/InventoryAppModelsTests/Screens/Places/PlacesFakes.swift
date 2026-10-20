import Foundation
import InventoryCore
import InventoryTestSupport
import Synchronization
import Testing
@testable import InventoryAppModels

// Test doubles for the space and container screens' models. Every name carries the Places prefix
// so it never collides with another area's helpers in this target.

/// Something a fake repository was told to fail with (reads as a local failure).
struct PlacesFailure: Error, Equatable {
    let name: String
    init(_ name: String = "boom") { self.name = name }
}

/// The home server did not answer (reads as offline).
let placesOffline = HouseholdHttpError(status: 0, code: "offline")

/// A scripted answer.
enum PlacesAnswer<Value: Sendable>: Sendable {
    case value(Value)
    case failure(any Error)

    func get() throws -> Value {
        switch self {
        case .value(let value): value
        case .failure(let error): throw error
        }
    }
}

/// A gate a fake call waits at until the test opens it, to hold a write in flight.
actor PlacesGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    func pass() async {
        arrivals += 1
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        let resumed = waiting
        waiting = []
        for continuation in resumed { continuation.resume() }
    }

    /// Waits (bounded) until `count` calls have reached the gate.
    func waitForArrivals(_ count: Int) async {
        for _ in 0..<100_000 {
            if arrivals >= count { return }
            await Task.yield()
        }
        Issue.record("expected \(count) call(s) at the gate")
    }
}

enum PlacesFixtures {
    static func space(id: String = "garage", name: String = "Garage", icon: String = "🧰", color: String = "#5B8DEF") -> Space {
        Space(id: id, name: name, icon: icon, color: color, createdAt: 1, updatedAt: 1)
    }

    static func spaceRow(_ space: Space, containers: Int = 0, items: Int = 0) -> SpaceWithCounts {
        SpaceWithCounts(space: space, containerCount: containers, itemCount: items)
    }

    static func container(
        id: String = "chest",
        spaceId: String = "garage",
        name: String? = "Tool chest",
        visualType: ContainerVisualType = .cabinet,
        shortCode: String = "CAB-J92R"
    ) -> Container {
        Container(id: id, spaceId: spaceId, name: name, visualType: visualType, shortCode: shortCode, createdAt: 1, updatedAt: 1)
    }

    static func containerRow(_ container: Container, items: Int = 0, qrToken: String? = nil) -> ContainerWithCounts {
        ContainerWithCounts(container: container, itemCount: items, qrToken: qrToken)
    }

    static func item(
        id: String,
        name: String,
        category: String? = nil,
        createdAt: Int64 = 1,
        containerId: String = "chest",
        spaceId: String = "garage",
        spaceName: String = "Garage",
        spaceColor: String = "#5B8DEF"
    ) -> ItemWithContext {
        ItemWithContext(
            item: Item(id: id, containerId: containerId, name: name, category: category, quantity: 1, notes: nil, createdAt: createdAt, updatedAt: createdAt),
            photoId: nil,
            photoUri: nil,
            photoThumbUri: nil,
            tags: [],
            spaceId: spaceId,
            spaceName: spaceName,
            spaceIcon: "🧰",
            spaceColor: spaceColor,
            containerName: "Tool chest",
            containerShortCode: "CAB-J92R"
        )
    }
}

/// Spaces from a script; every write is recorded. `gate` holds creates and updates in flight.
actor PlacesFakeSpaces: SpacesRepository {
    var list: PlacesAnswer<[SpaceWithCounts]> = .value([])
    var byId: PlacesAnswer<Space?> = .value(nil)
    var createAnswer: PlacesAnswer<Space> = .value(PlacesFixtures.space(id: "new-space", name: "Loft"))
    var updateAnswer: PlacesAnswer<Space?> = .value(PlacesFixtures.space())
    var impactAnswer: PlacesAnswer<SpaceDeletionImpact> = .value(SpaceDeletionImpact(containerCount: 0, itemCount: 0, photoCount: 0, qrBindingCount: 0))
    var deleteAnswer: PlacesAnswer<DeletionResult> = .value(DeletionResult(deleted: true, orphanedPhotoUris: []))
    var gate: PlacesGate?

    private(set) var creates: [CreateSpaceInput] = []
    private(set) var updates: [UpdateSpaceInput] = []
    private(set) var deletes: [String] = []
    private(set) var reads: [String] = []

    func set(
        list: PlacesAnswer<[SpaceWithCounts]>? = nil,
        byId: PlacesAnswer<Space?>? = nil,
        create: PlacesAnswer<Space>? = nil,
        update: PlacesAnswer<Space?>? = nil,
        impact: PlacesAnswer<SpaceDeletionImpact>? = nil,
        delete: PlacesAnswer<DeletionResult>? = nil,
        gate: PlacesGate? = nil
    ) {
        if let list { self.list = list }
        if let byId { self.byId = byId }
        if let create { createAnswer = create }
        if let update { updateAnswer = update }
        if let impact { impactAnswer = impact }
        if let delete { deleteAnswer = delete }
        if let gate { self.gate = gate }
    }

    func listWithCounts() async throws -> [SpaceWithCounts] {
        reads.append("list")
        return try list.get()
    }

    func getById(_ id: String) async throws -> Space? {
        reads.append(id)
        return try byId.get()
    }

    func create(_ input: CreateSpaceInput) async throws -> Space {
        creates.append(input)
        if let gate { await gate.pass() }
        return try createAnswer.get()
    }

    func update(_ id: String, _ input: UpdateSpaceInput) async throws -> Space? {
        updates.append(input)
        if let gate { await gate.pass() }
        return try updateAnswer.get()
    }

    func deletionImpact(_ id: String) async throws -> SpaceDeletionImpact {
        try impactAnswer.get()
    }

    func delete(_ id: String) async throws -> DeletionResult {
        deletes.append(id)
        return try deleteAnswer.get()
    }
}

/// Containers from a script; every write is recorded. `gate` holds creates and updates in flight.
actor PlacesFakeContainers: ContainersRepository {
    var bySpace: PlacesAnswer<[ContainerWithCounts]> = .value([])
    var byId: PlacesAnswer<Container?> = .value(nil)
    var withCounts: PlacesAnswer<ContainerWithCounts?> = .value(nil)
    var createAnswer: PlacesAnswer<Container> = .value(PlacesFixtures.container(id: "new-box", name: nil, visualType: .box, shortCode: "BOX-9QQX"))
    var updateAnswer: PlacesAnswer<Container?> = .value(PlacesFixtures.container())
    var impactAnswer: PlacesAnswer<ContainerDeletionImpact> = .value(ContainerDeletionImpact(itemCount: 0, photoCount: 0, hasQrBinding: false))
    var deleteAnswer: PlacesAnswer<DeletionResult> = .value(DeletionResult(deleted: true, orphanedPhotoUris: []))
    var gate: PlacesGate?

    private(set) var creates: [CreateContainerInput] = []
    private(set) var updates: [UpdateContainerInput] = []
    private(set) var deletes: [String] = []

    func set(
        bySpace: PlacesAnswer<[ContainerWithCounts]>? = nil,
        byId: PlacesAnswer<Container?>? = nil,
        withCounts: PlacesAnswer<ContainerWithCounts?>? = nil,
        create: PlacesAnswer<Container>? = nil,
        update: PlacesAnswer<Container?>? = nil,
        impact: PlacesAnswer<ContainerDeletionImpact>? = nil,
        delete: PlacesAnswer<DeletionResult>? = nil,
        gate: PlacesGate? = nil
    ) {
        if let bySpace { self.bySpace = bySpace }
        if let byId { self.byId = byId }
        if let withCounts { self.withCounts = withCounts }
        if let create { createAnswer = create }
        if let update { updateAnswer = update }
        if let impact { impactAnswer = impact }
        if let delete { deleteAnswer = delete }
        if let gate { self.gate = gate }
    }

    func listBySpace(_ spaceId: String) async throws -> [ContainerWithCounts] { try bySpace.get() }
    func getById(_ id: String) async throws -> Container? { try byId.get() }
    func getWithCounts(_ id: String) async throws -> ContainerWithCounts? { try withCounts.get() }

    func create(_ input: CreateContainerInput) async throws -> Container {
        creates.append(input)
        if let gate { await gate.pass() }
        return try createAnswer.get()
    }

    func update(_ id: String, _ input: UpdateContainerInput) async throws -> Container? {
        updates.append(input)
        if let gate { await gate.pass() }
        return try updateAnswer.get()
    }

    func deletionImpact(_ id: String) async throws -> ContainerDeletionImpact { try impactAnswer.get() }

    func delete(_ id: String) async throws -> DeletionResult {
        deletes.append(id)
        return try deleteAnswer.get()
    }

    func listAllWithSpace() async throws -> [ContainerWithSpace] { [] }
}

/// A container's items from a script; nothing else is used.
actor PlacesFakeItems: ItemsRepository {
    var contents: PlacesAnswer<[ItemWithContext]> = .value([])
    /// Holds every contents read until opened.
    var gate: PlacesGate?

    func set(contents: PlacesAnswer<[ItemWithContext]>? = nil, gate: PlacesGate? = nil) {
        if let contents { self.contents = contents }
        if let gate { self.gate = gate }
    }

    func listByContainer(_ containerId: String) async throws -> [ItemWithContext] {
        if let gate { await gate.pass() }
        return try contents.get()
    }
    func listUnsorted() async throws -> [ItemWithContext] { [] }
    func listRecent(limit: Int) async throws -> [ItemWithContext] { [] }
    func countUnsorted() async throws -> Int { 0 }
    func getById(_ id: String) async throws -> ItemWithContext? { nil }
    func create(_ draft: ItemDraft) async throws -> Item { throw PlacesFailure("not used") }
    func update(_ id: String, _ input: UpdateItemInput) async throws -> Item? { nil }
    func getPhotos(_ itemId: String) async throws -> [ItemPhoto] { [] }
    func delete(_ id: String) async throws -> DeletionResult { .notDeleted }
    func countAll() async throws -> Int { 0 }
}

/// What a model asked the screen to do, and whether the screen is still in front.
@MainActor
final class PlacesScreenStub<Navigation> {
    var focused = true
    private(set) var navigations: [Navigation] = []

    var isFocused: @MainActor () -> Bool { { [self] in focused } }
    var navigate: @MainActor (Navigation) -> Void { { [self] in navigations.append($0) } }
}

/// Lets queued main-actor work and read tasks run.
@MainActor
func placesSettle(_ queries: any PlacesRefreshing...) async {
    for query in queries { await query.settled() }
}
