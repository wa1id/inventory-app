import InventoryCore
import InventoryStrings
import Testing
@testable import InventoryAppModels

/// The Drop zone tab (06 §7.2; app/(tabs)/drop-zone.tsx): the rows, filing from the list and
/// the states in place of an empty list.
@Suite("DropZoneScreenModel (app/(tabs)/drop-zone.tsx)")
@MainActor
struct DropZoneScreenModelTests {
    private func waiting(_ ids: String...) -> [ItemWithContext] {
        ids.map { ShellFixtures.item($0, containerId: DropZone.containerId, category: "cat-\($0)") }
    }

    /// The move sheet as the test answers it.
    @MainActor
    private final class MoveSheets {
        var opened: [String] = []
        var answers: [CheckedContinuation<MoveResult?, Never>] = []

        func open(_ itemId: String) async -> MoveResult? {
            opened.append(itemId)
            return await withCheckedContinuation { answers.append($0) }
        }

        func answer(_ result: MoveResult?) {
            guard !answers.isEmpty else {
                Issue.record("no move sheet is waiting")
                return
            }
            answers.removeFirst().resume(returning: result)
        }
    }

    private struct Harness {
        let reads: ShellHeldReads<[ItemWithContext]>
        let dropZone: DropZoneModel
        let sheets: MoveSheets
        let categories: ShellEventLog
        let animations: ShellEventLog
        let model: DropZoneScreenModel
    }

    private func harness() -> Harness {
        let reads = ShellHeldReads<[ItemWithContext]>()
        let dropZone = DropZoneModel(read: reads.read)
        let sheets = MoveSheets()
        let categories = ShellEventLog()
        let animations = ShellEventLog()
        let model = DropZoneScreenModel(
            dropZone: dropZone,
            openMove: { await sheets.open($0) },
            rememberCategories: { categories.record($0.map { $0 ?? "nil" }.joined(separator: ",")) },
            animate: { change in
                animations.record("animated")
                change()
            })
        return Harness(reads: reads, dropZone: dropZone, sheets: sheets, categories: categories, animations: animations, model: model)
    }

    /// The tab shell comes into view and the first read answers `items`.
    private func appear(_ harness: Harness, _ items: [ItemWithContext]) async {
        harness.dropZone.focusChanged(true)
        await harness.reads.waitForCalls(1)
        harness.reads.succeed(items)
        await harness.dropZone.query.readTask?.value
    }

    private func moved(_ id: String) -> MoveResult {
        MoveResult(itemId: id, from: DropZone.containerId, to: "c1", updatedAt: 1)
    }

    // MARK: The shared read

    @Test("the shared read counts its answers; a failed refresh keeps the old items and the count")
    func readGeneration() async {
        let harness = harness()
        #expect(harness.dropZone.readGeneration == 0)
        await appear(harness, waiting("a"))
        #expect(harness.dropZone.readGeneration == 1)

        harness.dropZone.reload()
        await harness.reads.waitForCalls(2)
        harness.reads.fail()
        await harness.dropZone.query.readTask?.value
        #expect(harness.dropZone.refreshFailed)
        #expect(harness.dropZone.readGeneration == 1)

        harness.dropZone.reload()
        await harness.reads.waitForCalls(3)
        harness.reads.succeed(waiting("a"))
        await harness.dropZone.query.readTask?.value
        #expect(harness.dropZone.readGeneration == 2)
    }

    // MARK: Rows and header

    @Test("rows newest first as read, the intro with the count, and Quick Snap under it")
    func rows() async {
        let harness = harness()
        await appear(harness, waiting("c", "b", "a"))
        #expect(harness.model.rows.map(\.id) == ["c", "b", "a"])
        #expect(harness.model.subtitle == L10n.DropZone.intro2(count: 3))
        #expect(harness.model.subtitle == "3 items waiting for a place. Open one to name it, then file it.")
        #expect(harness.model.showsQuickSnap)
        #expect(harness.model.placeholder == nil)
        #expect(!harness.model.showsRefreshBanner)
    }

    @Test("the waiting items' categories are remembered once per read")
    func categories() async {
        let harness = harness()
        harness.model.itemsChanged()
        #expect(harness.categories.events.isEmpty)
        await appear(harness, waiting("a", "b"))
        harness.model.itemsChanged()
        harness.model.itemsChanged()
        #expect(harness.categories.events == ["cat-a,cat-b"])

        harness.dropZone.reload()
        await harness.reads.waitForCalls(2)
        harness.reads.succeed(waiting("b"))
        await harness.dropZone.query.readTask?.value
        harness.model.itemsChanged()
        #expect(harness.categories.events == ["cat-a,cat-b", "cat-b"])
    }

    // MARK: Filing

    @Test("File… hides the row as soon as it is filed, with the layout animation, then reads again")
    func filing() async {
        let harness = harness()
        await appear(harness, waiting("a", "b"))

        let filing = Task { await harness.model.file("a") }
        await ShellWait.until("the move sheet") { harness.sheets.opened == ["a"] }
        #expect(harness.model.isFiling)
        #expect(harness.model.rows.map(\.id) == ["a", "b"])

        harness.sheets.answer(moved("a"))
        await filing.value
        #expect(!harness.model.isFiling)
        #expect(harness.model.rows.map(\.id) == ["b"])
        #expect(harness.model.subtitle == L10n.DropZone.intro2(count: 1))
        #expect(harness.animations.events == ["animated"])

        // The read after the move decides: the item is gone from it.
        await harness.reads.waitForCalls(2)
        harness.reads.succeed(waiting("b"))
        await harness.dropZone.query.readTask?.value
        #expect(harness.model.rows.map(\.id) == ["b"])
    }

    @Test("a fresh read shows a row again: an item moved back by Undo returns")
    func undoShowsAgain() async {
        let harness = harness()
        await appear(harness, waiting("a", "b"))
        let filing = Task { await harness.model.file("a") }
        await ShellWait.until("the move sheet") { harness.sheets.opened == ["a"] }
        harness.sheets.answer(moved("a"))
        await filing.value
        #expect(harness.model.rows.map(\.id) == ["b"])

        await harness.reads.waitForCalls(2)
        harness.reads.succeed(waiting("a", "b"))
        await harness.dropZone.query.readTask?.value
        #expect(harness.model.rows.map(\.id) == ["a", "b"])
    }

    @Test("a refresh that fails keeps the filed row hidden (the same read is still on screen)")
    func hiddenAcrossFailedRefresh() async {
        let harness = harness()
        await appear(harness, waiting("a", "b"))
        let filing = Task { await harness.model.file("b") }
        await ShellWait.until("the move sheet") { harness.sheets.opened == ["b"] }
        harness.sheets.answer(moved("b"))
        await filing.value
        await harness.reads.waitForCalls(2)
        harness.reads.fail()
        await harness.dropZone.query.readTask?.value
        #expect(harness.model.rows.map(\.id) == ["a"])
        #expect(harness.model.showsRefreshBanner)
    }

    @Test("closing the move sheet changes nothing and reads nothing")
    func closedWithoutMoving() async {
        let harness = harness()
        await appear(harness, waiting("a"))
        let filing = Task { await harness.model.file("a") }
        await ShellWait.until("the move sheet") { harness.sheets.opened == ["a"] }
        harness.sheets.answer(nil)
        await filing.value
        #expect(harness.model.rows.map(\.id) == ["a"])
        #expect(harness.animations.events.isEmpty)
        await ShellWait.settle()
        #expect(harness.reads.callCount == 1)
        #expect(!harness.model.isFiling)
    }

    @Test("one move sheet at a time: a second File… while one is open does nothing")
    func oneSheetAtATime() async {
        let harness = harness()
        await appear(harness, waiting("a", "b"))
        let first = Task { await harness.model.file("a") }
        await ShellWait.until("the move sheet") { harness.sheets.opened == ["a"] }
        await harness.model.file("b")
        #expect(harness.sheets.opened == ["a"])
        harness.sheets.answer(nil)
        await first.value

        let second = Task { await harness.model.file("b") }
        await ShellWait.until("the second move sheet") { harness.sheets.opened == ["a", "b"] }
        harness.sheets.answer(nil)
        await second.value
    }

    @Test("rows filed one after another stay hidden together until the next read lands")
    func severalFiled() async {
        let harness = harness()
        await appear(harness, waiting("a", "b", "c"))
        for id in ["a", "b"] {
            let filing = Task { await harness.model.file(id) }
            await ShellWait.until("the move sheet for \(id)") { harness.sheets.opened.last == id }
            harness.sheets.answer(moved(id))
            await filing.value
        }
        #expect(harness.model.rows.map(\.id) == ["c"])
    }

    // MARK: States

    @Test("loading: a skeleton until the first answer; no intro, no Quick Snap")
    func loading() {
        let harness = harness()
        guard case .loading? = harness.model.placeholder else {
            Issue.record("expected the skeleton")
            return
        }
        #expect(harness.model.subtitle == nil)
        #expect(!harness.model.showsQuickSnap)
    }

    @Test("a failed first read is the error state, never 'everything is filed' (issue #12)")
    func failedFirstRead() async {
        let harness = harness()
        harness.dropZone.focusChanged(true)
        await harness.reads.waitForCalls(1)
        harness.reads.fail()
        await harness.dropZone.query.readTask?.value
        guard case .failed? = harness.model.placeholder else {
            Issue.record("expected the error state, got \(String(describing: harness.model.placeholder))")
            return
        }
        #expect(!harness.model.showsRefreshBanner)
    }

    @Test("nothing waiting: everything is filed, also once the last row is filed")
    func allFiled() async {
        let harness = harness()
        await appear(harness, waiting("a"))
        let filing = Task { await harness.model.file("a") }
        await ShellWait.until("the move sheet") { harness.sheets.opened == ["a"] }
        harness.sheets.answer(moved("a"))
        await filing.value
        guard case .allFiled? = harness.model.placeholder else {
            Issue.record("expected the empty state, got \(String(describing: harness.model.placeholder))")
            return
        }
        #expect(harness.model.subtitle == nil)
        #expect(!harness.model.showsQuickSnap)
    }

    @Test("with rows on screen a failed refresh shows only the banner; offline is the connection banner's")
    func refreshBanner() async {
        let harness = harness()
        await appear(harness, waiting("a"))
        harness.model.retry()
        await harness.reads.waitForCalls(2)
        harness.reads.fail(HouseholdHttpError(status: 0, code: "offline"))
        await harness.dropZone.query.readTask?.value
        #expect(harness.dropZone.refreshFailed)
        #expect(!harness.model.showsRefreshBanner)

        harness.model.retry()
        await harness.reads.waitForCalls(3)
        harness.reads.fail(HouseholdHttpError(status: 500, code: "http_500"))
        await harness.dropZone.query.readTask?.value
        #expect(harness.model.showsRefreshBanner)
        #expect(harness.model.placeholder == nil)
        #expect(harness.model.rows.map(\.id) == ["a"])
    }

    @Test("pull to refresh returns once the read has answered")
    func pull() async {
        let harness = harness()
        await appear(harness, waiting("a"))
        let pulling = Task { await harness.model.refresh() }
        await harness.reads.waitForCalls(2)
        #expect(harness.dropZone.reading)
        harness.reads.succeed(waiting("a"))
        await pulling.value
        #expect(!harness.dropZone.reading)
    }

    // MARK: Layout

    @Test("the photo needs 390 pt at standard text, more as text grows; stacked rows keep it", arguments: [
        (393.0, 1.0, false, 76),
        (390.0, 1.0, false, 76),
        (375.0, 1.0, false, 56),
        (393.0, 0.823, false, 76),
        (402.0, 1.118, false, 56),
        (440.0, 1.118, false, 76),
        (320.0, 3.12, true, 76),
    ])
    func thumbSize(width: Double, fontScale: Double, stacked: Bool, size: Int) {
        #expect(DropZoneScreenModel.thumbSize(windowWidth: width, fontScale: fontScale, stacked: stacked) == size)
    }
}
