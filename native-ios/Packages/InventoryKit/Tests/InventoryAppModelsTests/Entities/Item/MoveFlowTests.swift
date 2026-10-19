import Foundation
import InventoryCore
import Testing
@testable import InventoryAppModels

/// `src/ui/item/__tests__/moveFlow.test.ts`.
private let entitiesBefore = MoveSubject(id: "item-1", containerId: "box-a", updatedAt: 100)

private func entitiesConflict(_ updatedAt: Int64) -> EntitiesFakeItems.Answer<Item?> {
    .failure(ConflictError(updatedAt: updatedAt))
}

@Suite("attemptMove (moveFlow.test.ts)")
struct EntitiesAttemptMoveTests {
    @Test("moves with the lock the item had")
    func movesWithLock() async {
        let items = EntitiesFakeItems(updates: [.value(EntitiesFixtures.item(updatedAt: 200))])
        let outcome = await MoveFlow.attemptMove(items, before: entitiesBefore, target: "box-b")
        guard case .moved(let updatedAt) = outcome else { Issue.record("\(outcome)"); return }
        #expect(updatedAt == 200)
        #expect(await items.updates == [EntitiesUpdateCall(id: "item-1", input: UpdateItemInput(containerId: "box-b", expectedUpdatedAt: 100))])
    }

    @Test("reports a null update as gone, never as moved")
    func nullIsGone() async {
        let items = EntitiesFakeItems(updates: [.value(nil)])
        guard case .gone = await MoveFlow.attemptMove(items, before: entitiesBefore, target: "box-b") else {
            Issue.record("expected gone"); return
        }
    }

    @Test("stops when another phone moved it first, and says where it is")
    func movedElsewhere() async {
        let fresh = EntitiesFixtures.context(containerId: "box-c", updatedAt: 150)
        let items = EntitiesFakeItems(updates: [entitiesConflict(150)], lastRead: .value(fresh))
        let outcome = await MoveFlow.attemptMove(items, before: entitiesBefore, target: "box-b")
        guard case .movedElsewhere(let where_) = outcome else { Issue.record("\(outcome)"); return }
        #expect(where_ == fresh)
        #expect(await items.updates.count == 1)
    }

    @Test("retries once with the new stamp when only something else changed")
    func retriesOnce() async {
        let items = EntitiesFakeItems(
            updates: [entitiesConflict(150), .value(EntitiesFixtures.item(updatedAt: 300))],
            lastRead: .value(EntitiesFixtures.context(containerId: "box-a", updatedAt: 150))
        )
        let outcome = await MoveFlow.attemptMove(items, before: entitiesBefore, target: "box-b")
        guard case .moved(let updatedAt) = outcome else { Issue.record("\(outcome)"); return }
        #expect(updatedAt == 300)
        #expect(await items.stamps == [100, 150])
    }

    @Test("gives up after one retry")
    func givesUp() async {
        let second = ConflictError(updatedAt: 160)
        let items = EntitiesFakeItems(
            updates: [entitiesConflict(150), .failure(second)],
            lastRead: .value(EntitiesFixtures.context(containerId: "box-a", updatedAt: 150))
        )
        let outcome = await MoveFlow.attemptMove(items, before: entitiesBefore, target: "box-b")
        guard case .failed(let cause) = outcome else { Issue.record("\(outcome)"); return }
        #expect(cause as? ConflictError == second)
        #expect(await items.updates.count == 2)
    }

    @Test("treats an item deleted between the conflict and the re-read as gone")
    func deletedBetween() async {
        let items = EntitiesFakeItems(updates: [entitiesConflict(150)], lastRead: .value(nil))
        guard case .gone = await MoveFlow.attemptMove(items, before: entitiesBefore, target: "box-b") else {
            Issue.record("expected gone"); return
        }
    }

    @Test("passes any other failure through without retrying")
    func passesFailureThrough() async {
        let offline = HouseholdHttpError(status: 0, code: "offline")
        let items = EntitiesFakeItems(updates: [.failure(offline)])
        let outcome = await MoveFlow.attemptMove(items, before: entitiesBefore, target: "box-b")
        guard case .failed(let cause) = outcome else { Issue.record("\(outcome)"); return }
        #expect(cause as? HouseholdHttpError == offline)
        #expect(await items.updates.count == 1)
        #expect(await items.reads.isEmpty)
    }
}

@Suite("attemptUndo (moveFlow.test.ts)")
struct EntitiesAttemptUndoTests {
    private let move = MoveResult(itemId: "item-1", from: "box-a", to: "box-b", updatedAt: 200)

    @Test("moves it back with the stamp the move left")
    func movesBack() async {
        let items = EntitiesFakeItems(updates: [.value(EntitiesFixtures.item(updatedAt: 250))])
        guard case .undone = await MoveFlow.attemptUndo(items, move: move) else { Issue.record("expected undone"); return }
        #expect(await items.updates == [EntitiesUpdateCall(id: "item-1", input: UpdateItemInput(containerId: "box-a", expectedUpdatedAt: 200))])
    }

    @Test("tells deleted, changed again and failed apart")
    func tellsApart() async {
        guard case .gone = await MoveFlow.attemptUndo(EntitiesFakeItems(updates: [.value(nil)]), move: move) else {
            Issue.record("expected gone"); return
        }
        guard case .conflict = await MoveFlow.attemptUndo(EntitiesFakeItems(updates: [entitiesConflict(260)]), move: move) else {
            Issue.record("expected conflict"); return
        }
        let offline = EntitiesFakeItems(updates: [.failure(HouseholdHttpError(status: 0, code: "offline"))])
        guard case .failed = await MoveFlow.attemptUndo(offline, move: move) else { Issue.record("expected failed"); return }
    }

    @Test("words each refusal differently")
    func words() {
        #expect(MoveFlow.undoFailedMessage(.gone)?.contains("deleted") == true)
        #expect(MoveFlow.undoFailedMessage(.conflict)?.contains("changed again") == true)
        #expect(MoveFlow.undoFailedMessage(.failed(HouseholdHttpError(status: 0, code: "offline")))?.contains("connection") == true)
        #expect(MoveFlow.undoFailedMessage(.undone) == nil)
    }

    @Test("only blames the connection when it was the connection")
    func onlyConnection() {
        for cause in [HouseholdHttpError(status: 500, code: "http_500") as any Error, EntitiesFailure("sqlite")] {
            let message = MoveFlow.undoFailedMessage(.failed(cause)) ?? ""
            #expect(!message.contains("connection"))
            #expect(message.contains("Try again"))
        }
    }
}

@Suite("move messages (moveFlow.test.ts)")
struct EntitiesMoveMessagesTests {
    @Test("names an unnamed container by its label code")
    func containerLabel() {
        #expect(MoveFlow.containerLabel(name: nil, shortCode: "CAB-J92R") == "CAB-J92R")
        #expect(MoveFlow.containerLabel(name: "Tool chest", shortCode: "CAB-J92R") == "Tool chest")
    }

    @Test("says moved, filed or everything filed")
    func moved() {
        func message(_ fromDropZone: Bool, _ filing: Bool, _ moreWaiting: Bool?) -> String {
            MoveFlow.movedMessage(fromDropZone: fromDropZone, filing: filing, moreWaiting: moreWaiting, container: "Tool chest", space: "Garage")
        }
        #expect(message(false, false, nil) == "Moved to Tool chest (Garage).")
        #expect(message(true, false, nil) == "Filed in Tool chest (Garage).")
        #expect(message(true, true, true) == "Filed in Tool chest (Garage).")
        #expect(message(true, true, false) == "Filed in Tool chest (Garage). Everything is filed.")
    }

    @Test("promises nothing about the run when the drop zone could not be read")
    func unknownRun() {
        #expect(
            MoveFlow.movedMessage(fromDropZone: true, filing: true, moreWaiting: nil, container: "Tool chest", space: "Garage")
                == "Filed in Tool chest (Garage).")
    }

    @Test("says where another phone moved it, never the drop zone code")
    func movedElsewhere() {
        #expect(
            MoveFlow.movedElsewhereMessage(EntitiesFixtures.context(containerId: "box-c", containerName: "Garage shelf", containerShortCode: "SHF-1"))
                == "Someone already moved it to Garage shelf on another device.")
        #expect(
            MoveFlow.movedElsewhereMessage(EntitiesFixtures.context(containerId: "box-c", containerName: nil, containerShortCode: "SHF-1"))
                == "Someone already moved it to SHF-1 on another device.")
        let dropZone = MoveFlow.movedElsewhereMessage(
            EntitiesFixtures.context(containerId: DropZone.containerId, containerName: "Drop zone", containerShortCode: "DROP-ZONE"))
        #expect(!dropZone.contains("DROP-ZONE"))
    }

    @Test("only blames the connection when it was the connection")
    func moveFailed() {
        #expect(MoveFlow.moveFailedMessage(HouseholdHttpError(status: 0, code: "offline")).contains("connection"))
        #expect(MoveFlow.moveFailedMessage(HouseholdHttpError(status: 502, code: "http_502")).contains("connection"))
        #expect(MoveFlow.moveFailedMessage(EntitiesFailure("SQLITE_BUSY")) == "It was not moved. Try again.")
    }
}

@Suite("nextInRun (moveFlow.test.ts)")
struct EntitiesNextInRunTests {
    @Test("takes the item after this one")
    func next() {
        #expect(MoveFlow.nextInRun(before: ["a", "b", "c"], currentId: "a", waiting: ["b", "c"]) == "b")
    }

    @Test("wraps round to the top")
    func wraps() {
        #expect(MoveFlow.nextInRun(before: ["a", "b", "c"], currentId: "c", waiting: ["a", "b"]) == "a")
    }

    @Test("skips items filed or deleted meanwhile")
    func skips() {
        #expect(MoveFlow.nextInRun(before: ["a", "b", "c", "d"], currentId: "a", waiting: ["c", "d"]) == "c")
    }

    @Test("never returns this item, even if it is still waiting")
    func neverCurrent() {
        #expect(MoveFlow.nextInRun(before: ["a", "b"], currentId: "a", waiting: ["a", "b"]) == "b")
        #expect(MoveFlow.nextInRun(before: ["a"], currentId: "a", waiting: ["a"]) == nil)
    }

    @Test("takes items that arrived meanwhile once the old ones are done")
    func arrivals() {
        #expect(MoveFlow.nextInRun(before: ["a", "b"], currentId: "a", waiting: ["z"]) == "z")
    }

    @Test("starts from the top when this item was not in the list")
    func fromTop() {
        #expect(MoveFlow.nextInRun(before: ["a", "b"], currentId: "x", waiting: ["b", "a"]) == "a")
    }

    @Test("ends the run when nothing is left")
    func ends() {
        #expect(MoveFlow.nextInRun(before: ["a", "b"], currentId: "a", waiting: []) == nil)
        #expect(MoveFlow.nextInRun(before: [], currentId: "a", waiting: []) == nil)
    }
}

@Suite("afterFiling (moveFlow.test.ts)")
struct EntitiesAfterFilingTests {
    @Test("words the toast from the same read the run goes on from")
    func sameRead() async {
        // A second Quick Snap item lands just after the first is filed.
        let items = EntitiesFakeItems(unsorted: [.value([EntitiesFixtures.context(id: "b")])])
        let after = await MoveFlow.afterFiling(items, itemId: "a")
        #expect(after == AfterFiling(waiting: ["b"], moreWaiting: true))
        #expect(await items.unsortedReads == 1)
        #expect(MoveFlow.nextInRun(before: ["a"], currentId: "a", waiting: after.waiting ?? []) == "b")
    }

    @Test("says everything is filed only when the run ends")
    func runEnds() async {
        let after = await MoveFlow.afterFiling(EntitiesFakeItems(unsorted: [.value([EntitiesFixtures.context(id: "a")])]), itemId: "a")
        #expect(after.moreWaiting == false)
        #expect(MoveFlow.nextInRun(before: ["a", "b"], currentId: "a", waiting: after.waiting ?? []) == nil)
    }

    @Test("leaves the run to the item screen when the read fails")
    func readFails() async {
        let items = EntitiesFakeItems(unsorted: [.failure(HouseholdHttpError(status: 0, code: "offline"))])
        #expect(await MoveFlow.afterFiling(items, itemId: "a") == AfterFiling(waiting: nil, moreWaiting: nil))
    }
}
