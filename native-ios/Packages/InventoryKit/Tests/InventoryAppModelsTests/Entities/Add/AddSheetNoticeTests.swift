import Foundation
import InventoryCore
import InventoryServices
import InventoryStrings
import Testing
@testable import InventoryAppModels

/// What the Add sheet says again when it happens again (RN app/item/new.tsx): the places
/// failure while Try again reads (RN's `useInventoryQuery` reported no cause until the current
/// read settled, :738-748), and a save problem or "Saved. Add the next one." after each save,
/// which RN cleared when the save started and set after it (:513-514, :531, :562). No RN tests
/// exist for these; they pin the RN behaviour.
@MainActor
@Suite("Add sheet notices said again (app/item/new.tsx)")
struct AddSheetNoticeTests {
    typealias Harness = EntitiesAddSheetModelTests.Harness

    private func until(_ condition: () async -> Bool) async {
        for _ in 0..<100_000 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("condition never held")
    }

    @Test("Try again hides the places failure while it reads, and a second failure shows it again")
    func placesRetry() async {
        let containers = AddPlacesGatedContainers()
        let harness = Harness(spaces: EntitiesFakeSpaces([.value([])]), containers: containers)
        let model = harness.makeModel()

        let first = Task { await model.loadPlaces() }
        await until { await containers.waiting == 1 }
        #expect(!model.showsPlacesFailed, "nothing to say while the first read runs")
        await containers.open()
        await first.value
        #expect(model.showsPlacesFailed)

        let retry = Task { await model.loadPlaces() }
        await until { await containers.waiting == 1 }
        #expect(!model.showsPlacesFailed, "the banner goes while Try again reads")
        #expect(model.entries == [.dropZone], "the drop zone still works")
        await containers.open()
        await retry.value
        #expect(model.showsPlacesFailed, "back, so it is seen and announced again")
        #expect(await containers.reads == 2)
    }

    @Test("each save that starts counts, so the same problem twice is a new notice; a blank name counts nothing")
    func saveProblemAgain() async {
        let cause = HouseholdHttpError(status: 0, code: "offline")
        let harness = Harness(items: EntitiesFakeItems(create: .failure(cause)))
        let model = harness.makeModel()
        model.start()

        await model.save(andAnother: false)
        #expect(model.saveAttempts == 0, "a blank name never starts a save")

        model.name = "Drill"
        await model.save(andAnother: false)
        let first = model.problem
        #expect(first == SaveNoticeCopy(cause: cause, subject: .container))
        #expect(model.saveAttempts == 1)

        await model.save(andAnother: false)
        #expect(model.problem == first, "the same words")
        #expect(model.saveAttempts == 2, "but a new attempt, so the sheet shows it as a new notice")
    }

    @Test("Save and add another twice says “Saved. Add the next one.” after each")
    func savedNextAgain() async {
        let harness = Harness()
        let model = harness.makeModel()
        model.start()

        model.name = "Drill bits"
        await model.save(andAnother: true)
        #expect(model.savedNext)
        let first = model.saveAttempts

        model.name = "Hole saw"
        #expect(!model.savedNext, "a new name hides it")
        await model.save(andAnother: true)
        #expect(model.savedNext)
        #expect(model.saveAttempts == first + 1)
        #expect(await harness.items.creates.map(\.name) == ["Drill bits", "Hole saw"])
    }
}

/// Containers whose every read waits until a test opens it, then fails.
actor AddPlacesGatedContainers: ContainersRepository {
    private var gates: [CheckedContinuation<Void, Never>] = []
    private(set) var reads = 0

    var waiting: Int { gates.count }

    /// Lets the oldest waiting read go on to its failure.
    func open() {
        guard !gates.isEmpty else { return }
        gates.removeFirst().resume()
    }

    func listAllWithSpace() async throws -> [ContainerWithSpace] {
        reads += 1
        await withCheckedContinuation { gates.append($0) }
        throw EntitiesFailure("db")
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
