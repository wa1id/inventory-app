import Foundation
import InventoryCore
import InventoryStrings
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// The item screen (app/item/[id]/index.tsx; 07 §3.2) as a model. RN has no tests for the
/// screen; the run order (`nextInRun`, `afterFiling`) and the writes it relies on are tested in
/// MoveFlowTests, ItemDetailsTests and NameItModelTests.
@MainActor
@Suite("ItemDetailModel (app/item/[id]/index.tsx)")
struct ItemScreensDetailModelTests {
    @MainActor
    final class Harness {
        let items: EntitiesFakeItems
        let photos = EntitiesPhotoSpy()
        let log = ItemScreensEventLog()
        let toasts = SharedSeamsToastRecorder()
        let confirms: SharedSeamsConfirmScript
        let haptics = SharedSeamsHapticRecorder()
        let telemetry = RecordingTelemetry()
        var paired = false
        var focused = true
        /// What the Move sheet answers, and the `filing` flags it was opened with.
        var moveAnswer: MoveResult?
        private(set) var moveOpenings: [Bool] = []
        /// Holds the Move sheet open until released.
        var holdsMove = false
        private var heldMove: CheckedContinuation<Void, Never>?
        private(set) var model: ItemDetailModel!

        init(items: EntitiesFakeItems, id: String = "item-1", filing: Bool = false, confirms: [Bool] = []) {
            self.items = items
            self.confirms = SharedSeamsConfirmScript(answers: confirms)
            let log = log
            model = ItemDetailModel(
                id: id,
                filing: filing,
                items: items,
                photos: photos,
                invalidator: log,
                toasts: toasts,
                confirm: self.confirms,
                haptics: haptics.player,
                telemetry: TelemetryReporter(sink: telemetry),
                isPaired: { [unowned self] in paired },
                announce: { log.entries.append("announce \($0)") },
                routing: ItemDetailModel.Routing(
                    openMove: { [unowned self] filing in await openMove(filing) },
                    openEdit: { log.entries.append("edit") },
                    openPhoto: { log.entries.append("photo") },
                    isFocused: { [unowned self] in focused },
                    openNext: { log.entries.append("next \($0)") },
                    close: { log.entries.append("close") }
                )
            )
        }

        private func openMove(_ filing: Bool) async -> MoveResult? {
            moveOpenings.append(filing)
            log.entries.append("move")
            if holdsMove { await withCheckedContinuation { heldMove = $0 } }
            return moveAnswer
        }

        func releaseMove() {
            heldMove?.resume()
            heldMove = nil
        }

        var moveIsHeld: Bool { heldMove != nil }

        /// Focuses the screen and waits for its reads.
        func load() async {
            model.focusChanged(true, revision: 0)
            await settle()
        }

        func settle() async {
            await model.itemQuery.readTask?.value
            await model.dropZoneQuery?.readTask?.value
        }
    }

    private static func waiting(_ ids: [String]) -> [ItemWithContext] {
        ids.map { EntitiesFixtures.context(id: $0, containerId: DropZone.containerId) }
    }

    @Test("loading, a failed read, gone, then the item")
    func phases() async {
        let failing = Harness(items: EntitiesFakeItems(reads: [.failure(EntitiesFailure())]))
        guard case .loading = failing.model.phase else {
            Issue.record("expected loading before the first read")
            return
        }
        #expect(failing.model.title == "")
        await failing.load()
        guard case .failed = failing.model.phase else {
            Issue.record("expected the failure")
            return
        }

        let gone = Harness(items: EntitiesFakeItems(lastRead: .value(nil)))
        await gone.load()
        guard case .gone = gone.model.phase else {
            Issue.record("expected gone")
            return
        }

        let loaded = Harness(items: EntitiesFakeItems(lastRead: .value(EntitiesFixtures.context(name: "Cordless drill"))))
        await loaded.load()
        guard case .loaded(let item) = loaded.model.phase else {
            Issue.record("expected the item")
            return
        }
        #expect(item.name == "Cordless drill")
        #expect(loaded.model.title == "Cordless drill")
        #expect(!loaded.model.isNaming)
        #expect(loaded.model.quantity?.quantity == 1)
        #expect(loaded.model.dropZoneQuery == nil)
    }

    @Test("a failed refresh keeps the item and shows the banner")
    func refreshBanner() async {
        let items = EntitiesFakeItems(reads: [.value(EntitiesFixtures.context()), .failure(EntitiesFailure())])
        let harness = Harness(items: items)
        await harness.load()
        #expect(!harness.model.showsRefreshBanner)
        harness.model.retry()
        await harness.settle()
        #expect(harness.model.showsRefreshBanner)
        guard case .loaded = harness.model.phase else {
            Issue.record("the item stays")
            return
        }
    }

    @Test("an unnamed item is named in place; the name shows before the re-read and focus moves to File it…")
    func namesInPlace() async throws {
        let unnamed = EntitiesFixtures.context(containerId: DropZone.containerId, name: "", updatedAt: 10)
        let items = EntitiesFakeItems(
            updates: [.value(EntitiesFixtures.item(containerId: DropZone.containerId, name: "AA batteries", updatedAt: 11))],
            lastRead: .value(unnamed)
        )
        let harness = Harness(items: items)
        await harness.load()
        #expect(harness.model.isNaming)
        #expect(harness.model.title == L10n.Entities.unnamedItem)
        let field = try #require(harness.model.nameField)
        field.focused = true
        field.value = "AA batteries"

        #expect(await field.save())
        #expect(harness.model.name == "AA batteries")
        #expect(harness.model.title == "AA batteries")
        #expect(harness.model.namedHere == ItemDetailModel.NamedHere(id: "item-1", name: "AA batteries", over: 10))
        #expect(!harness.model.isNaming)
        #expect(harness.model.focusRequest?.target == .fileIt)
        // A fresh field for any later naming.
        #expect(harness.model.nameField !== field)
    }

    @Test("named outside the drop zone, focus moves to Edit details")
    func namedFocusEdit() async throws {
        let items = EntitiesFakeItems(
            updates: [.value(EntitiesFixtures.item(name: "Batteries", updatedAt: 11))],
            lastRead: .value(EntitiesFixtures.context(name: "", updatedAt: 10))
        )
        let harness = Harness(items: items)
        await harness.load()
        let field = try #require(harness.model.nameField)
        field.value = "Batteries"
        #expect(await field.save())
        #expect(harness.model.focusRequest == ItemDetailModel.FocusRequest(target: .editDetails, serial: 1))
    }

    @Test("the name given here gives way to a newer stored one, but not to the same stored read")
    func namedHereGivesWay() async throws {
        let items = EntitiesFakeItems(
            updates: [.value(EntitiesFixtures.item(name: "Batteries", updatedAt: 11))],
            reads: [.value(EntitiesFixtures.context(name: "", updatedAt: 10)), .value(EntitiesFixtures.context(name: "", updatedAt: 10))],
            lastRead: .value(EntitiesFixtures.context(name: "AA batteries", updatedAt: 20))
        )
        let harness = Harness(items: items)
        await harness.load()
        let field = try #require(harness.model.nameField)
        field.value = "Batteries"
        #expect(await field.save())
        // The re-read has not caught up: still no name stored, so ours shows.
        harness.model.retry()
        await harness.settle()
        #expect(harness.model.name == "Batteries")
        // Renamed since (recognition, another phone): theirs shows.
        harness.model.retry()
        await harness.settle()
        #expect(harness.model.name == "AA batteries")
    }

    @Test("the field stays while it is in use, even once a name arrives")
    func fieldStaysWhileEngaged() async throws {
        let items = EntitiesFakeItems(
            reads: [.value(EntitiesFixtures.context(name: "", updatedAt: 10))],
            lastRead: .value(EntitiesFixtures.context(name: "AA batteries", updatedAt: 20))
        )
        let harness = Harness(items: items)
        await harness.load()
        let field = try #require(harness.model.nameField)
        field.focused = true
        harness.model.retry()
        await harness.settle()
        #expect(harness.model.name == "AA batteries")
        #expect(harness.model.isNaming)
        // The name it arrived with is offered, and the field knows the newer stamp.
        #expect(field.offered == "AA batteries")
        #expect(field.itemUpdatedAt == 20)
        field.focused = false
        #expect(!harness.model.isNaming)
    }

    @Test("a filing run counts what waits, this item included, and only a run reads the drop zone")
    func progress() async {
        let filing = Harness(
            items: EntitiesFakeItems(lastRead: .value(EntitiesFixtures.context(containerId: DropZone.containerId)), unsorted: [.value(Self.waiting(["a", "item-1", "b"]))]),
            filing: true
        )
        await filing.load()
        #expect(filing.model.progress == "3 waiting")
        #expect(await filing.items.unsortedReads == 1)

        let last = Harness(
            items: EntitiesFakeItems(lastRead: .value(EntitiesFixtures.context(containerId: DropZone.containerId)), unsorted: [.value(Self.waiting(["item-1"]))]),
            filing: true
        )
        await last.load()
        #expect(last.model.progress == "Last one waiting")

        let filed = Harness(
            items: EntitiesFakeItems(lastRead: .value(EntitiesFixtures.context()), unsorted: [.value(Self.waiting(["a"]))]),
            filing: true
        )
        await filed.load()
        #expect(filed.model.progress == nil)

        let plain = Harness(items: EntitiesFakeItems(lastRead: .value(EntitiesFixtures.context(containerId: DropZone.containerId))))
        await plain.load()
        #expect(plain.model.progress == nil)
        #expect(await plain.items.unsortedReads == 0)
    }

    @Test("Move outside a run opens the sheet and nothing more happens")
    func moveOutsideRun() async {
        let harness = Harness(items: EntitiesFakeItems(lastRead: .value(EntitiesFixtures.context())))
        await harness.load()
        harness.moveAnswer = MoveResult(itemId: "item-1", from: "box-a", to: "box-b", updatedAt: 200)
        await harness.model.moveOrFile()
        #expect(harness.moveOpenings == [false])
        #expect(harness.log.entries == ["move"])
    }

    @Test("filing an item moved out of the drop zone meanwhile is not a step of the run")
    func filingAFiledItem() async {
        let harness = Harness(
            items: EntitiesFakeItems(lastRead: .value(EntitiesFixtures.context()), unsorted: [.value(Self.waiting(["a", "b"]))]),
            filing: true
        )
        await harness.load()
        harness.moveAnswer = MoveResult(itemId: "item-1", from: "box-a", to: "box-b", updatedAt: 200, waiting: ["a", "b"])
        await harness.model.moveOrFile()
        #expect(harness.moveOpenings == [false])
        #expect(harness.log.entries == ["move"])
    }

    @Test("a filing step goes on to the next waiting item, in the drop zone's order")
    func filingStepNext() async {
        let harness = Harness(
            items: EntitiesFakeItems(lastRead: .value(EntitiesFixtures.context(containerId: DropZone.containerId)), unsorted: [.value(Self.waiting(["a", "item-1", "b"]))]),
            filing: true
        )
        await harness.load()
        harness.moveAnswer = MoveResult(itemId: "item-1", from: DropZone.containerId, to: "box-b", updatedAt: 200, waiting: ["a", "b"])
        await harness.model.moveOrFile()
        #expect(harness.moveOpenings == [true])
        #expect(harness.log.entries == ["move", "next b"])
        #expect(await harness.items.unsortedReads == 1)
    }

    @Test("the last filing step goes back")
    func filingStepLast() async {
        let harness = Harness(
            items: EntitiesFakeItems(lastRead: .value(EntitiesFixtures.context(containerId: DropZone.containerId)), unsorted: [.value(Self.waiting(["item-1"]))]),
            filing: true
        )
        await harness.load()
        harness.moveAnswer = MoveResult(itemId: "item-1", from: DropZone.containerId, to: "box-b", updatedAt: 200, waiting: [])
        await harness.model.moveOrFile()
        #expect(harness.log.entries == ["move", "close"])
    }

    @Test("without the sheet's read the run reads the drop zone itself, or falls back to what waited")
    func filingStepRereads() async {
        let rereads = Harness(
            items: EntitiesFakeItems(
                lastRead: .value(EntitiesFixtures.context(containerId: DropZone.containerId)),
                unsorted: [.value(Self.waiting(["item-1", "a"])), .value(Self.waiting(["z"]))]
            ),
            filing: true
        )
        await rereads.load()
        rereads.moveAnswer = MoveResult(itemId: "item-1", from: DropZone.containerId, to: "box-b", updatedAt: 200)
        await rereads.model.moveOrFile()
        #expect(rereads.log.entries == ["move", "next z"])
        #expect(await rereads.items.unsortedReads == 2)

        let fallsBack = Harness(
            items: EntitiesFakeItems(
                lastRead: .value(EntitiesFixtures.context(containerId: DropZone.containerId)),
                unsorted: [.value(Self.waiting(["item-1", "a"])), .failure(EntitiesFailure())]
            ),
            filing: true
        )
        await fallsBack.load()
        fallsBack.moveAnswer = MoveResult(itemId: "item-1", from: DropZone.containerId, to: "box-b", updatedAt: 200)
        await fallsBack.model.moveOrFile()
        #expect(fallsBack.log.entries == ["move", "next a"])
    }

    @Test("left for another screen meanwhile, the run stops; a sheet closed without a move stops it too")
    func filingStepNotFocused() async {
        let harness = Harness(
            items: EntitiesFakeItems(lastRead: .value(EntitiesFixtures.context(containerId: DropZone.containerId)), unsorted: [.value(Self.waiting(["item-1", "a"]))]),
            filing: true
        )
        await harness.load()
        harness.focused = false
        harness.moveAnswer = MoveResult(itemId: "item-1", from: DropZone.containerId, to: "box-b", updatedAt: 200, waiting: ["a"])
        await harness.model.moveOrFile()
        #expect(harness.log.entries == ["move"])

        harness.focused = true
        harness.moveAnswer = nil
        await harness.model.moveOrFile()
        #expect(harness.log.entries == ["move", "move"])
    }

    @Test("a typed name is saved before moving; a name that did not save moves nothing")
    func commitsNameFirst() async throws {
        let unnamed = EntitiesFixtures.context(containerId: DropZone.containerId, name: "", updatedAt: 10)
        let failing = Harness(items: EntitiesFakeItems(updates: [.failure(EntitiesFailure())], lastRead: .value(unnamed)), filing: true)
        await failing.load()
        let failingField = try #require(failing.model.nameField)
        failingField.value = "Batteries"
        await failing.model.moveOrFile()
        #expect(failing.moveOpenings.isEmpty)
        #expect(failing.model.nameField?.error == L10n.Item.NameIt.failed)
        #expect(failing.haptics.played == [.error])

        let saving = Harness(
            items: EntitiesFakeItems(updates: [.value(EntitiesFixtures.item(containerId: DropZone.containerId, name: "Batteries", updatedAt: 11))], lastRead: .value(unnamed)),
            filing: true
        )
        await saving.load()
        let savingField = try #require(saving.model.nameField)
        savingField.value = "Batteries"
        await saving.model.moveOrFile()
        #expect(saving.moveOpenings == [true])
        #expect(await saving.items.updates.map(\.input.name) == ["Batteries"])

        // Nothing typed: filed unnamed, no write.
        let blank = Harness(items: EntitiesFakeItems(lastRead: .value(unnamed)))
        await blank.load()
        await blank.model.moveOrFile()
        #expect(blank.moveOpenings == [false])
        #expect(await blank.items.updates.isEmpty)
    }

    @Test("one action at a time: Delete waits for nothing while Move is open")
    func busyGuard() async {
        let harness = Harness(items: EntitiesFakeItems(lastRead: .value(EntitiesFixtures.context())), confirms: [true])
        await harness.load()
        harness.holdsMove = true
        harness.model.startMoveOrFile()
        for _ in 0..<1000 where !harness.moveIsHeld { await Task.yield() }
        #expect(harness.moveIsHeld)
        await harness.model.delete()
        await harness.model.moveOrFile()
        #expect(harness.confirms.asked.isEmpty)
        #expect(harness.moveOpenings == [false])
        harness.releaseMove()
        await harness.model.actionTask?.value
        await harness.model.delete()
        #expect(harness.confirms.asked.count == 1)
    }

    @Test("Delete confirms, deletes the photo files, goes back before refreshing and says so")
    func deletes() async {
        let items = EntitiesFakeItems(
            lastRead: .value(EntitiesFixtures.context(name: "Cordless drill")),
            delete: .value(DeletionResult(deleted: true, orphanedPhotoUris: ["file:///a.webp", "file:///a-thumb.webp"]))
        )
        let harness = Harness(items: items, confirms: [true])
        await harness.load()
        await harness.model.delete()

        let asked = harness.confirms.asked.first
        #expect(asked?.title == "Delete “Cordless drill”?")
        #expect(asked?.body == L10n.Item.deleteBodyLocal)
        #expect(asked?.confirmLabel == L10n.Common.delete)
        #expect(asked?.destructive == true)
        #expect(await items.deletes == ["item-1"])
        #expect(harness.photos.deleted == [["file:///a.webp", "file:///a-thumb.webp"]])
        #expect(harness.log.entries == ["close", "invalidate"])
        #expect(harness.toasts.messages == ["“Cordless drill” was deleted."])
        #expect(harness.telemetry.names == ["item_deleted"])
        // No haptic on a successful delete (08 §7.2).
        #expect(harness.haptics.played.isEmpty)
    }

    @Test("Delete asks about the household when paired, and names an unnamed item plainly")
    func deleteCopy() async {
        let harness = Harness(items: EntitiesFakeItems(lastRead: .value(EntitiesFixtures.context(name: ""))), confirms: [false])
        harness.paired = true
        await harness.load()
        await harness.model.delete()
        #expect(harness.confirms.asked.first?.title == L10n.Item.deleteTitleUnnamed)
        #expect(harness.confirms.asked.first?.body == L10n.Item.deleteBodyPaired)
        // Cancelled: nothing happens.
        #expect(await harness.items.deletes.isEmpty)
        #expect(harness.log.entries.isEmpty)
        #expect(!harness.model.deleting)
    }

    @Test("an item another phone deleted first is said to be already deleted, and nothing is claimed")
    func alreadyDeleted() async {
        let items = EntitiesFakeItems(lastRead: .value(EntitiesFixtures.context(name: "Cordless drill")), delete: .value(.notDeleted))
        let harness = Harness(items: items, confirms: [true])
        await harness.load()
        harness.focused = false
        await harness.model.delete()
        #expect(harness.photos.deleted.isEmpty)
        #expect(harness.telemetry.names.isEmpty)
        // Left already while deleting: not closed again.
        #expect(harness.log.entries == ["invalidate"])
        #expect(harness.toasts.messages == ["“Cordless drill” was already deleted, probably on another phone."])
    }

    @Test("a failed delete says whether it was the connection, with the error haptic, and stays")
    func deleteFails() async {
        let offline = Harness(
            items: EntitiesFakeItems(lastRead: .value(EntitiesFixtures.context()), delete: .failure(HouseholdHttpError(status: 0, code: "offline"))),
            confirms: [true]
        )
        await offline.load()
        await offline.model.delete()
        #expect(offline.toasts.last?.message == L10n.Item.deleteFailed(offline: true))
        #expect(offline.toasts.last?.tone == .error)
        #expect(offline.haptics.played == [.error])
        #expect(offline.telemetry.errors.map(\.name) == ["item_delete_failed"])
        #expect(offline.telemetry.errors.first?.payload["errorClass"] == .string("offline"))
        #expect(!offline.model.deleting)
        #expect(offline.log.entries.isEmpty)

        let local = Harness(items: EntitiesFakeItems(lastRead: .value(EntitiesFixtures.context()), delete: .failure(EntitiesFailure())), confirms: [true])
        await local.load()
        await local.model.delete()
        #expect(local.toasts.last?.message == L10n.Item.deleteFailed(offline: false))
    }

    @Test("the photo opens full screen only when there is one; facts, category and labels")
    func details() async {
        var withPhoto = EntitiesFixtures.context(name: "Cordless drill", category: "Tools", tags: ["power tools"], createdAt: 1_788_350_400_000, updatedAt: 1_788_350_400_000)
        withPhoto.photoUri = "file:///full.webp"
        withPhoto.photoThumbUri = "file:///thumb.webp"
        let harness = Harness(items: EntitiesFakeItems(lastRead: .value(withPhoto)))
        await harness.load()
        #expect(harness.model.photoUri == "file:///full.webp")
        #expect(harness.model.thumbUri == "file:///thumb.webp")
        #expect(harness.model.photoAccessibilityLabel == "Photo of Cordless drill. Opens it full screen.")
        #expect(harness.model.category == "Tools")
        #expect(harness.model.hasFacts)
        #expect(harness.model.editAccessibilityLabel == "Edit details of “Cordless drill”")
        #expect(harness.model.deleteAccessibilityLabel == "Delete “Cordless drill”…")
        #expect(harness.model.stamp(now: 1_788_350_400_000).hasPrefix("Added "))
        harness.model.openPhoto()
        harness.model.openEdit()
        #expect(harness.log.entries == ["photo", "edit"])

        let plain = Harness(items: EntitiesFakeItems(lastRead: .value(EntitiesFixtures.context(name: "", category: "", notes: ""))))
        await plain.load()
        #expect(plain.model.photoUri == nil)
        #expect(plain.model.category == nil)
        #expect(!plain.model.hasFacts)
        #expect(plain.model.photoAccessibilityLabel == L10n.Item.photoA11yUnnamed)
        #expect(plain.model.editAccessibilityLabel == nil)
        plain.model.openPhoto()
        #expect(plain.log.entries.isEmpty)
    }

    @Test("the stepper follows each read while nothing is being written")
    func quantityFollowsReads() async {
        let items = EntitiesFakeItems(
            reads: [.value(EntitiesFixtures.context(quantity: 2, updatedAt: 10))],
            lastRead: .value(EntitiesFixtures.context(quantity: 5, updatedAt: 20))
        )
        let harness = Harness(items: items)
        await harness.load()
        let stepper = harness.model.quantity
        #expect(stepper?.quantity == 2)
        harness.model.retry()
        await harness.settle()
        #expect(harness.model.quantity === stepper)
        #expect(stepper?.quantity == 5)
    }
}

/// Records, in order, what a screen model did through its seams: routing calls, announcements
/// and invalidations (an `InventoryInvalidating` for tests).
@MainActor
final class ItemScreensEventLog: InventoryInvalidating {
    var entries: [String] = []

    func invalidate() {
        entries.append("invalidate")
    }
}
