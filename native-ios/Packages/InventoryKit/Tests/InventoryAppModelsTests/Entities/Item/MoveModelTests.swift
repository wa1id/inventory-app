import Foundation
import InventoryCore
import InventoryStorage
import InventoryStrings
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// `useMove` (src/hooks/useMove.ts) as a model: 07 §3.5, 01 §9.4. RN has no tests for the hook.
@MainActor
@Suite("MoveModel (useMove.ts)")
struct EntitiesMoveModelTests {
    /// Everything a model under test talks to.
    @MainActor
    final class Harness {
        let items: EntitiesFakeItems
        let toasts = SharedSeamsToastRecorder()
        let haptics = SharedSeamsHapticRecorder()
        let invalidations = SharedSeamsInvalidationCounter()
        let telemetry = RecordingTelemetry()
        let preferences = InMemoryPreferences()
        let routes = RouteResults(makeId: { "move-request" })
        let screen: EntitiesScreenStub
        let model: MoveModel

        var focused: Bool {
            get { screen.focused }
            set { screen.focused = newValue }
        }

        var closes: Int { screen.closes }

        init(items: EntitiesFakeItems, filing: Bool = false, withRequest: Bool = true) {
            self.items = items
            let screen = EntitiesScreenStub()
            self.screen = screen
            model = MoveModel(
                items: items,
                filing: filing,
                request: withRequest ? RouteRequest(id: "move-request") : nil,
                routeResults: routes,
                recentPlaces: RecentPlacesStore(preferences: preferences),
                invalidator: invalidations,
                toasts: toasts,
                haptics: haptics.player,
                telemetry: TelemetryReporter(sink: telemetry),
                isFocused: { screen.focused },
                close: { screen.closes += 1 }
            )
        }

        /// Opens the request the model answers, as the item screen does.
        func openRequest() async -> Task<MoveResult?, any Error> {
            let routes = routes
            let task = Task { try await routes.open(MoveResult.self) { _ in } }
            for _ in 0..<1000 where !routes.isPending(RouteRequest<MoveResult>(id: "move-request")) { await Task.yield() }
            return task
        }
    }

    private let shelf = EntitiesFixtures.option("box-b", name: "Tool chest", spaceName: "Garage")

    @Test("a move delivers the result, closes the sheet, refreshes and offers Undo")
    func moves() async throws {
        let harness = Harness(items: EntitiesFakeItems(updates: [.value(EntitiesFixtures.item(containerId: "box-b", updatedAt: 200))]))
        let opener = await harness.openRequest()
        let model = harness.model
        model.loaded = EntitiesFixtures.context(containerId: "box-a", name: "Cordless drill", updatedAt: 100)

        await model.pick(.container(shelf))

        #expect(try await opener.value == MoveResult(itemId: "item-1", from: "box-a", to: "box-b", updatedAt: 200))
        #expect(harness.closes == 1)
        #expect(harness.invalidations.count == 1)
        #expect(harness.haptics.played == [.success])
        #expect(harness.telemetry.names == ["item_moved"])
        #expect(RecentPlacesStore(preferences: harness.preferences).read() == ["box-b"])
        let toast = try #require(harness.toasts.last)
        #expect(toast.message == "Moved to Tool chest (Garage).")
        #expect(toast.action?.label == L10n.Common.undo)
        #expect(toast.action?.accessibilityLabel == L10n.Move.undoA11y(name: "Cordless drill"))
        // The sheet is closing: the picker stays locked and a second pick does nothing.
        #expect(model.busyId == "box-b")
        await model.pick(.container(EntitiesFixtures.option("box-c")))
        #expect(await harness.items.updates.count == 1)
    }

    @Test("a filing step reads the drop zone once and says when everything is filed")
    func filingStep() async throws {
        let items = EntitiesFakeItems(
            updates: [.value(EntitiesFixtures.item(containerId: "box-b", updatedAt: 200))],
            unsorted: [.value([])]
        )
        let harness = Harness(items: items, filing: true)
        let opener = await harness.openRequest()
        harness.model.loaded = EntitiesFixtures.context(containerId: DropZone.containerId, name: "", updatedAt: 100)

        await harness.model.pick(.container(shelf))

        let result = try await opener.value
        #expect(result?.waiting == [])
        #expect(await items.unsortedReads == 1)
        #expect(harness.toasts.last?.message == "Filed in Tool chest (Garage). Everything is filed.")
        #expect(harness.toasts.last?.action?.accessibilityLabel == L10n.Move.undoA11yUnnamed)
    }

    @Test("out of a run, filing reads nothing more and says filed in")
    func filingOutsideRun() async {
        let items = EntitiesFakeItems(updates: [.value(EntitiesFixtures.item(updatedAt: 200))])
        let harness = Harness(items: items, filing: false, withRequest: false)
        harness.model.loaded = EntitiesFixtures.context(containerId: DropZone.containerId, updatedAt: 100)
        #expect(harness.model.inDropZone)
        #expect(harness.model.pickerMode == .file)
        await harness.model.pick(.container(shelf))
        #expect(await items.unsortedReads == 0)
        #expect(harness.toasts.last?.message == "Filed in Tool chest (Garage).")
    }

    @Test("a sheet closed while writing is not closed again; the toast still shows")
    func closedWhileWriting() async {
        let harness = Harness(items: EntitiesFakeItems(updates: [.value(EntitiesFixtures.item(updatedAt: 200))]), withRequest: false)
        harness.focused = false
        harness.model.loaded = EntitiesFixtures.context(updatedAt: 100)
        await harness.model.pick(.container(shelf))
        #expect(harness.closes == 0)
        #expect(harness.toasts.shown.count == 1)
    }

    @Test("an item deleted elsewhere is said to be gone, with nothing refreshed")
    func gone() async {
        let harness = Harness(items: EntitiesFakeItems(updates: [.value(nil)]))
        harness.model.loaded = EntitiesFixtures.context(updatedAt: 100)
        await harness.model.pick(.container(shelf))
        #expect(harness.model.notice == MoveModel.Notice(kind: .gone, message: L10n.Move.gone))
        #expect(harness.haptics.played == [.error])
        #expect(harness.invalidations.count == 0)
        #expect(harness.model.busyId == nil)
        #expect(harness.closes == 0)
    }

    @Test("an item moved elsewhere first follows its new place, and the next pick may move it")
    func movedElsewhere() async {
        let fresh = EntitiesFixtures.context(containerId: "box-c", updatedAt: 150, containerName: "Garage shelf")
        let items = EntitiesFakeItems(
            updates: [.failure(ConflictError(updatedAt: 150))], lastRead: .value(fresh))
        let harness = Harness(items: items)
        harness.model.loaded = EntitiesFixtures.context(containerId: "box-a", updatedAt: 100)
        await harness.model.pick(.container(shelf))
        #expect(harness.model.item == fresh)
        #expect(harness.model.notice?.kind == .movedElsewhere)
        #expect(harness.model.notice?.message == "Someone already moved it to Garage shelf on another device.")
        #expect(harness.haptics.played == [.warning])
        #expect(harness.model.busyId == nil)
        // Picking where it now is does nothing.
        await harness.model.pick(.container(EntitiesFixtures.option("box-c")))
        #expect(await items.updates.count == 1)
    }

    @Test("a failure says whether it was the connection and logs the kind")
    func failed() async {
        let harness = Harness(items: EntitiesFakeItems(updates: [.failure(HouseholdHttpError(status: 0, code: "offline"))]))
        harness.model.loaded = EntitiesFixtures.context(updatedAt: 100)
        await harness.model.pick(.container(shelf))
        #expect(harness.model.notice == MoveModel.Notice(kind: .failed, message: L10n.Move.failed))
        #expect(harness.telemetry.errors == [RecordingTelemetry.Entry(level: "error", name: "item_move_failed", payload: ["errorClass": .string("offline")])])
        #expect(harness.haptics.played == [.error])
        #expect(harness.invalidations.count == 0)
    }

    @Test("ignores the drop zone, a missing item and the container it is already in")
    func ignores() async {
        let items = EntitiesFakeItems()
        let harness = Harness(items: items)
        await harness.model.pick(.container(shelf))
        harness.model.loaded = EntitiesFixtures.context(containerId: "box-b", updatedAt: 100)
        await harness.model.pick(.dropZone)
        await harness.model.pick(.container(shelf))
        #expect(await items.updates.isEmpty)
        #expect(harness.haptics.played.isEmpty)
    }

    @Test("the newer read of the item wins, ties to the screen's")
    func newerRead() async {
        let harness = Harness(items: EntitiesFakeItems(
            updates: [.failure(ConflictError(updatedAt: 150))],
            lastRead: .value(EntitiesFixtures.context(containerId: "box-c", updatedAt: 150))))
        harness.model.loaded = EntitiesFixtures.context(containerId: "box-a", updatedAt: 100)
        await harness.model.pick(.container(shelf))
        #expect(harness.model.item?.containerId == "box-c")
        // The screen's own re-read catches up with a newer stamp.
        harness.model.loaded = EntitiesFixtures.context(containerId: "box-d", updatedAt: 151)
        #expect(harness.model.item?.containerId == "box-d")
        harness.model.loaded = EntitiesFixtures.context(containerId: "box-e", updatedAt: 150)
        #expect(harness.model.item?.containerId == "box-e")
    }

    @Test("the title files or moves, with or without a name")
    func titles() {
        let harness = Harness(items: EntitiesFakeItems())
        #expect(harness.model.title == "")
        harness.model.loaded = EntitiesFixtures.context(name: "Drill")
        #expect(harness.model.title == L10n.Move.titleMove(name: "Drill"))
        harness.model.loaded = EntitiesFixtures.context(name: "")
        #expect(harness.model.title == L10n.Move.titleMoveUnnamed)
        harness.model.loaded = EntitiesFixtures.context(containerId: DropZone.containerId, name: "Drill")
        #expect(harness.model.title == L10n.Move.titleFile(name: "Drill"))
        let filing = Harness(items: EntitiesFakeItems(), filing: true)
        filing.model.loaded = EntitiesFixtures.context(name: "")
        #expect(filing.model.title == L10n.Move.titleFileUnnamed)
    }

    @Test("Undo puts it back, refreshes and says so")
    func undo() async throws {
        let items = EntitiesFakeItems(updates: [
            .value(EntitiesFixtures.item(containerId: "box-b", updatedAt: 200)),
            .value(EntitiesFixtures.item(containerId: "box-a", updatedAt: 250)),
        ])
        let harness = Harness(items: items, withRequest: false)
        harness.model.loaded = EntitiesFixtures.context(containerId: "box-a", updatedAt: 100)
        await harness.model.pick(.container(shelf))
        harness.toasts.pressAction()
        await harness.model.undoTask?.value

        #expect(await items.updates.last == EntitiesUpdateCall(id: "item-1", input: UpdateItemInput(containerId: "box-a", expectedUpdatedAt: 200)))
        #expect(harness.telemetry.names == ["item_moved", "item_move_undone"])
        #expect(harness.invalidations.count == 2)
        #expect(harness.haptics.played == [.success, .undo])
        #expect(harness.toasts.last?.message == L10n.Move.undone)
    }

    @Test("an Undo that meets a later change says so, with a warning, and refreshes")
    func undoConflict() async {
        let harness = Harness(items: EntitiesFakeItems(updates: [.failure(ConflictError(updatedAt: 260))]), withRequest: false)
        await harness.model.undo(MoveResult(itemId: "item-1", from: "box-a", to: "box-b", updatedAt: 200))
        #expect(harness.haptics.played == [.warning])
        #expect(harness.telemetry.errors.map(\.payload) == [["outcome": .string("conflict")]])
        #expect(harness.telemetry.errors.map(\.name) == ["item_move_undo_failed"])
        #expect(harness.toasts.last?.message == L10n.Move.undoConflict)
        #expect(harness.toasts.last?.tone == .error)
        #expect(harness.invalidations.count == 1)
    }

    @Test("a failed Undo logs its kind")
    func undoFailed() async {
        let harness = Harness(items: EntitiesFakeItems(updates: [.failure(HouseholdHttpError(status: 0, code: "offline"))]), withRequest: false)
        await harness.model.undo(MoveResult(itemId: "item-1", from: "box-a", to: "box-b", updatedAt: 200))
        #expect(harness.haptics.played == [.error])
        #expect(harness.telemetry.errors.map(\.payload) == [["outcome": .string("failed"), "errorClass": .string("offline")]])
        #expect(harness.toasts.last?.message == L10n.Move.undoFailed)
    }

    @Test("closing the sheet without a pick answers the opener with nothing; after a move it does nothing")
    func sheetClosed() async throws {
        let harness = Harness(items: EntitiesFakeItems())
        let opener = await harness.openRequest()
        harness.model.sheetClosed()
        #expect(try await opener.value == nil)
        harness.model.sheetClosed()
    }

    @Test("the sheet resists a swipe-down only while a pick writes")
    func dismissWhileBusy() async {
        let items = EntitiesFakeItems(updates: [.value(nil)])
        await items.setHoldUpdates(true)
        let harness = Harness(items: items)
        harness.model.loaded = EntitiesFixtures.context(updatedAt: 100)
        let pick = Task { await harness.model.pick(.container(shelf)) }
        await EntitiesFakeItems.waitForHeld(items, count: 1)
        #expect(harness.model.interactiveDismissDisabled)
        await items.releaseNextUpdate()
        await pick.value
        #expect(!harness.model.interactiveDismissDisabled)
    }

    @Test("following the sheet's read sets the item as each read settles, gone included")
    func followsRead() async {
        let harness = Harness(items: EntitiesFakeItems())
        let reads = EntitiesFakeItems(
            reads: [.value(EntitiesFixtures.context(containerId: DropZone.containerId, updatedAt: 100))],
            lastRead: .value(nil)
        )
        let query = InventoryQuery<ItemWithContext?>(key: "item:item-1") { try await reads.getById("item-1") }
        harness.model.follow(query)
        #expect(harness.model.item == nil)
        query.focusChanged(true, revision: 0)
        await query.readTask?.value
        #expect(harness.model.pickerMode == .file)
        #expect(harness.model.item?.updatedAt == 100)
        query.reload()
        await query.readTask?.value
        #expect(harness.model.item == nil)
    }
}
