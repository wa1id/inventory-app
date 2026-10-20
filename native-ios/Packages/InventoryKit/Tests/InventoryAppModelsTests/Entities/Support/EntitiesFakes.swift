import CoreGraphics
import Foundation
import InventoryCore
import InventoryServices
import Synchronization
import Testing
@testable import InventoryAppModels

// Test doubles for the entity logic's tests. Every name carries the Entities prefix so it never
// collides with another area's helpers in this target.

/// Something a fake repository was told to fail with.
struct EntitiesFailure: Error, Equatable, CustomStringConvertible {
    let name: String
    init(_ name: String = "boom") { self.name = name }
    var description: String { name }
}

/// Builders for the stored shapes the tests pass around.
enum EntitiesFixtures {
    static func item(
        id: String = "item-1",
        containerId: String = "box-a",
        name: String = "Cordless drill",
        category: String? = nil,
        quantity: Int = 1,
        notes: String? = nil,
        createdAt: Int64 = 1,
        updatedAt: Int64 = 100
    ) -> Item {
        Item(id: id, containerId: containerId, name: name, category: category, quantity: quantity, notes: notes, createdAt: createdAt, updatedAt: updatedAt)
    }

    static func context(
        id: String = "item-1",
        containerId: String = "box-a",
        name: String = "Cordless drill",
        category: String? = nil,
        tags: [String] = [],
        quantity: Int = 1,
        notes: String? = nil,
        createdAt: Int64 = 1,
        updatedAt: Int64 = 100,
        containerName: String? = "Box A",
        containerShortCode: String = "BOX-AAAA",
        spaceName: String = "Garage"
    ) -> ItemWithContext {
        ItemWithContext(
            item: item(id: id, containerId: containerId, name: name, category: category, quantity: quantity, notes: notes, createdAt: createdAt, updatedAt: updatedAt),
            photoId: nil,
            photoUri: nil,
            photoThumbUri: nil,
            tags: tags,
            spaceId: "space-1",
            spaceName: spaceName,
            spaceIcon: "🚗",
            spaceColor: "#5B8DEF",
            containerName: containerName,
            containerShortCode: containerShortCode
        )
    }

    static func option(
        _ id: String,
        name: String?? = nil,
        shortCode: String? = nil,
        visualType: ContainerVisualType = .box,
        spaceId: String = "kitchen",
        spaceName: String = "Kitchen",
        spaceColor: String = "#5B8DEF",
        spaceIcon: String = "🍳"
    ) -> PlaceOption {
        PlaceOption(
            id: id,
            name: name ?? "Container \(id)",
            shortCode: shortCode ?? "BOX-\(id.uppercased())",
            visualType: visualType,
            spaceId: spaceId,
            spaceName: spaceName,
            spaceColor: spaceColor,
            spaceIcon: spaceIcon,
            itemCount: 0
        )
    }
}

/// One `items.update` call as the fake saw it.
struct EntitiesUpdateCall: Sendable, Equatable {
    let id: String
    let input: UpdateItemInput
}

/// A scripted `ItemsRepository`: each call takes the next scripted answer, and every call is
/// recorded. `holdUpdates` makes each update wait until the test releases it.
actor EntitiesFakeItems: ItemsRepository {
    enum Answer<Value: Sendable>: Sendable {
        case value(Value)
        case failure(any Error)

        func get() throws -> Value {
            switch self {
            case .value(let value): value
            case .failure(let error): throw error
            }
        }
    }

    private var updateAnswers: [Answer<Item?>]
    private var readAnswers: [Answer<ItemWithContext?>]
    /// The answer once the scripted reads run out.
    private var lastRead: Answer<ItemWithContext?>
    private var unsortedAnswers: [Answer<[ItemWithContext]>]
    private var createAnswer: Answer<Item>
    private var deleteAnswer: Answer<DeletionResult>
    private var heldUpdates: [CheckedContinuation<Void, Never>] = []
    var holdUpdates = false
    /// Holds creates too (they join the same queue as held updates).
    var holdCreates = false

    private(set) var updates: [EntitiesUpdateCall] = []
    private(set) var reads: [String] = []
    private(set) var unsortedReads = 0
    private(set) var creates: [ItemDraft] = []
    private(set) var deletes: [String] = []

    init(
        updates: [Answer<Item?>] = [],
        reads: [Answer<ItemWithContext?>] = [],
        lastRead: Answer<ItemWithContext?> = .value(nil),
        unsorted: [Answer<[ItemWithContext]>] = [],
        create: Answer<Item> = .value(EntitiesFixtures.item(id: "new-item")),
        delete: Answer<DeletionResult> = .value(DeletionResult(deleted: true, orphanedPhotoUris: []))
    ) {
        updateAnswers = updates
        readAnswers = reads
        self.lastRead = lastRead
        unsortedAnswers = unsorted
        createAnswer = create
        deleteAnswer = delete
    }

    func script(updates: [Answer<Item?>], reads: [Answer<ItemWithContext?>] = []) {
        updateAnswers.append(contentsOf: updates)
        readAnswers.append(contentsOf: reads)
    }

    func setHoldUpdates(_ hold: Bool) {
        holdUpdates = hold
    }

    func setHoldCreates(_ hold: Bool) {
        holdCreates = hold
    }

    var heldCount: Int { heldUpdates.count }

    /// Lets the oldest held update go on to its scripted answer.
    func releaseNextUpdate() {
        guard !heldUpdates.isEmpty else { return }
        heldUpdates.removeFirst().resume()
    }

    /// The `expectedUpdatedAt` of every update, in order.
    var stamps: [Int64?] { updates.map(\.input.expectedUpdatedAt) }

    func update(_ id: String, _ input: UpdateItemInput) async throws -> Item? {
        updates.append(EntitiesUpdateCall(id: id, input: input))
        if holdUpdates {
            await withCheckedContinuation { heldUpdates.append($0) }
        }
        guard !updateAnswers.isEmpty else {
            Issue.record("unexpected update \(input)")
            throw EntitiesFailure("unexpected update")
        }
        return try updateAnswers.removeFirst().get()
    }

    func getById(_ id: String) async throws -> ItemWithContext? {
        reads.append(id)
        return try (readAnswers.isEmpty ? lastRead : readAnswers.removeFirst()).get()
    }

    func listUnsorted() async throws -> [ItemWithContext] {
        unsortedReads += 1
        guard !unsortedAnswers.isEmpty else { return [] }
        return try unsortedAnswers.removeFirst().get()
    }

    func create(_ draft: ItemDraft) async throws -> Item {
        creates.append(draft)
        if holdCreates {
            await withCheckedContinuation { heldUpdates.append($0) }
        }
        return try createAnswer.get()
    }

    func delete(_ id: String) async throws -> DeletionResult {
        deletes.append(id)
        return try deleteAnswer.get()
    }

    func listByContainer(_ containerId: String) async throws -> [ItemWithContext] { [] }
    func listRecent(limit: Int) async throws -> [ItemWithContext] { [] }
    func countUnsorted() async throws -> Int { 0 }
    func getPhotos(_ itemId: String) async throws -> [ItemPhoto] { [] }
    func countAll() async throws -> Int { 0 }

    /// Suspends the caller until `count` updates are held (bounded, so a bug fails instead of hanging).
    static func waitForHeld(_ fake: EntitiesFakeItems, count: Int) async {
        // A real-time limit, not a count of yields: a loaded Mac can hold the model's tasks back
        // for seconds. The wait ends as soon as the condition holds.
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            if await fake.heldCount >= count { return }
            await Task.yield()
        }
        Issue.record("expected \(count) held update(s)")
    }
}

/// One stored item with a real optimistic lock: a write over a stale stamp is refused, as the
/// RN test's `store` fake does (itemDetails.test.ts).
actor EntitiesLockedStore: ItemsRepository {
    private(set) var name: String
    private(set) var updatedAt: Int64
    private(set) var stamps: [Int64?] = []

    init(name: String, updatedAt: Int64) {
        self.name = name
        self.updatedAt = updatedAt
    }

    /// Something else writes it (recognition finishing, another phone).
    func write(name: String, updatedAt: Int64) {
        self.name = name
        self.updatedAt = updatedAt
    }

    private var row: ItemWithContext {
        EntitiesFixtures.context(name: name, updatedAt: updatedAt)
    }

    func update(_ id: String, _ input: UpdateItemInput) async throws -> Item? {
        stamps.append(input.expectedUpdatedAt)
        if let expected = input.expectedUpdatedAt, expected != updatedAt { throw ConflictError(updatedAt: updatedAt) }
        if let next = input.name { name = next }
        updatedAt += 1
        return row.item
    }

    func getById(_ id: String) async throws -> ItemWithContext? { row }
    func listByContainer(_ containerId: String) async throws -> [ItemWithContext] { [] }
    func listUnsorted() async throws -> [ItemWithContext] { [] }
    func listRecent(limit: Int) async throws -> [ItemWithContext] { [] }
    func countUnsorted() async throws -> Int { 0 }
    func create(_ draft: ItemDraft) async throws -> Item { row.item }
    func getPhotos(_ itemId: String) async throws -> [ItemPhoto] { [] }
    func delete(_ id: String) async throws -> DeletionResult { .notDeleted }
    func countAll() async throws -> Int { 0 }
}

/// Records the photo files the code under test deletes (RN's mocked `deleteStoredPhotos`).
final class EntitiesPhotoSpy: PhotoStoring {
    private let calls = Mutex<[[String?]]>([])

    /// Every `deleteStoredPhotos` call, oldest first.
    var deleted: [[String?]] { calls.withLock { $0 } }

    func deleteStoredPhotos(_ uris: [String?]) {
        calls.withLock { $0.append(uris) }
    }

    func storeItemPhoto(_ source: ImageSource, cropToAspect aspect: CGSize?) async throws -> StoredImage {
        throw EntitiesFailure("not used")
    }

    func writeStoredPhoto(photoId: String, bytes: Data) async throws -> StoredImage {
        throw EntitiesFailure("not used")
    }

    func readStoredPhoto(_ uri: String) async -> Data? { nil }
    func hasRoomForPhoto(estimatedBytes: Int64) -> Bool { true }
}

/// Spaces that answer `listWithCounts` from a script; nothing else is used.
actor EntitiesFakeSpaces: SpacesRepository {
    private var answers: [EntitiesFakeItems.Answer<[SpaceWithCounts]>]

    init(_ answers: [EntitiesFakeItems.Answer<[SpaceWithCounts]>] = [.value([])]) {
        self.answers = answers
    }

    func listWithCounts() async throws -> [SpaceWithCounts] {
        try (answers.count > 1 ? answers.removeFirst() : answers.first ?? .value([])).get()
    }

    func getById(_ id: String) async throws -> Space? { nil }
    func create(_ input: CreateSpaceInput) async throws -> Space { throw EntitiesFailure("not used") }
    func update(_ id: String, _ input: UpdateSpaceInput) async throws -> Space? { nil }
    func deletionImpact(_ id: String) async throws -> SpaceDeletionImpact {
        SpaceDeletionImpact(containerCount: 0, itemCount: 0, photoCount: 0, qrBindingCount: 0)
    }
    func delete(_ id: String) async throws -> DeletionResult { .notDeleted }
}

/// Containers that answer `listAllWithSpace` from a script; nothing else is used.
actor EntitiesFakeContainers: ContainersRepository {
    private var answers: [EntitiesFakeItems.Answer<[ContainerWithSpace]>]

    init(_ answers: [EntitiesFakeItems.Answer<[ContainerWithSpace]>] = [.value([])]) {
        self.answers = answers
    }

    func listAllWithSpace() async throws -> [ContainerWithSpace] {
        try (answers.count > 1 ? answers.removeFirst() : answers.first ?? .value([])).get()
    }

    func listBySpace(_ spaceId: String) async throws -> [ContainerWithCounts] { [] }
    func getById(_ id: String) async throws -> Container? { nil }
    func getWithCounts(_ id: String) async throws -> ContainerWithCounts? { nil }
    func create(_ input: CreateContainerInput) async throws -> Container { throw EntitiesFailure("not used") }
    func update(_ id: String, _ input: UpdateContainerInput) async throws -> Container? { nil }
    func deletionImpact(_ id: String) async throws -> ContainerDeletionImpact {
        ContainerDeletionImpact(itemCount: 0, photoCount: 0, hasQrBinding: false)
    }
    func delete(_ id: String) async throws -> DeletionResult { .notDeleted }
}

/// `Fixtures/entities/entities-vectors.json`, generated from the real TypeScript by
/// `Fixtures/entities/generator/entities-vectors.test.tsx`.
enum EntitiesVectors {
    static func load() throws -> [String: JSONValue] {
        let url = try #require(
            Bundle.module.url(forResource: "entities-vectors", withExtension: "json", subdirectory: "Fixtures/entities"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return try #require(JSONValue.parse(text)?.objectValue)
    }
}

/// The screen around a model: whether it is still in front, and how often it was closed.
@MainActor
final class EntitiesScreenStub {
    var focused = true
    var closes = 0
}

/// A wall clock in epoch milliseconds that only moves when a test moves it.
final class EntitiesNow: Sendable {
    private let value: Mutex<Int64>

    init(_ start: Int64) {
        value = Mutex(start)
    }

    var ms: Int64 { value.withLock { $0 } }

    func set(_ ms: Int64) {
        value.withLock { $0 = ms }
    }
}
