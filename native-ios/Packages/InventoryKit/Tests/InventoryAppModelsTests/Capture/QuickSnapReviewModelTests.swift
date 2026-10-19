import Foundation
import InventoryCore
import InventoryServices
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// Everything a review model under test talks to.
@MainActor
final class QuickSnapReviewHarness {
    let items: CaptureTestItems
    let photos = CaptureTestPhotos()
    let invalidator = SharedSeamsInvalidationCounter()
    let toasts = SharedSeamsToastRecorder()
    let confirm: SharedSeamsConfirmScript
    let haptics = SharedSeamsHapticRecorder()
    let telemetry = RecordingTelemetry()
    let navigation = CaptureTestNavigation<QuickSnapReviewNavigation>()
    let clock = ManualClock()
    var paired = false

    init(confirm: [Bool] = [true], holdReads: Bool = false) {
        self.confirm = SharedSeamsConfirmScript(answers: confirm)
        items = CaptureTestItems(holdReads: holdReads)
    }

    func model(containerId: String = DropZone.containerId, since: Int64 = 100, expected: Int) -> QuickSnapReviewModel {
        QuickSnapReviewModel(
            route: QuickSnapReviewRoute(containerId: containerId, since: since, expected: expected),
            items: items,
            photos: photos,
            isPaired: { [self] in paired },
            invalidator: invalidator,
            toasts: toasts,
            confirm: confirm,
            haptics: haptics.player,
            telemetry: TelemetryReporter(sink: telemetry),
            clock: clock,
            navigate: navigation.navigate
        )
    }
}

@Suite("QuickSnapReviewModel: reading and status (app/capture/review.tsx)", .timeLimit(.minutes(1)))
@MainActor
struct QuickSnapReviewStatusTests {
    @Test("reads the container's rows from the session start, oldest first")
    func readsSession() async {
        let harness = QuickSnapReviewHarness()
        harness.items.rows = [
            CaptureTestRows.dropZone("newest", createdAt: 300),
            CaptureTestRows.dropZone("older", createdAt: 200),
            CaptureTestRows.dropZone("before", createdAt: 99),
        ]
        let model = harness.model(since: 100, expected: 2)
        #expect(model.queryKey == "fast-review:drop-zone:100")
        await model.reload()
        #expect(harness.items.listCalls == [DropZone.containerId])
        #expect(model.list.map(\.id) == ["older", "newest"])
        #expect(model.summary == FastSessionSummary(saved: 2, named: 0, unnamed: 2, pending: 0))
        #expect(model.status == .toName)
        #expect(model.title == "2 saved to the drop zone")
        #expect(model.statusText == "2 still need a name")
        #expect(model.showsHeader)
    }

    @Test("says what is happening before the first row lands, then counts what is still on its way")
    func savingThenPending() async {
        let harness = QuickSnapReviewHarness()
        let model = harness.model(expected: 2)
        // Nothing is claimed before the first read.
        #expect(!model.showsHeader)
        guard case .skeleton(rows: 2) = model.placeholder else {
            Issue.record("expected a two-row skeleton, got \(model.placeholder)")
            return
        }
        await model.reload()
        #expect(model.status == .pending)
        #expect(model.title == "Saving 2 photos…")
        #expect(model.statusText == "They appear here as they are saved.")
        #expect(model.showsHeader)

        harness.items.rows = [CaptureTestRows.dropZone("a", name: "Drill", createdAt: 150)]
        await model.reload()
        #expect(model.title == "1 saved to the drop zone")
        #expect(model.statusText == "Saving 1 more…")
        guard case .none = model.placeholder else {
            Issue.record("rows are on screen")
            return
        }
    }

    @Test("a container's set is titled by its rows' container")
    func containerTitle() async {
        let harness = QuickSnapReviewHarness()
        harness.items.rows = [CaptureTestRows.row("a", name: "Drill", createdAt: 150)]
        let model = harness.model(containerId: "c1", expected: 1)
        await model.reload()
        #expect(model.label == "Tool chest")
        #expect(model.title == "1 saved to Tool chest")
        #expect(model.status == .allNamed)
        #expect(model.statusText == "All named")
    }

    @Test("stops promising after 30 s without a change, and a row that lands restarts the wait")
    func stall() async throws {
        let harness = QuickSnapReviewHarness()
        harness.items.rows = [CaptureTestRows.dropZone("a", createdAt: 150)]
        let model = harness.model(expected: 3)
        await model.reload()
        #expect(model.status == .pending)

        try await harness.clock.waitForSleepers()
        await harness.clock.advance(by: .seconds(20))
        #expect(model.status == .pending)

        // A second row lands: the timer starts again.
        harness.items.rows = [CaptureTestRows.dropZone("b", createdAt: 160), CaptureTestRows.dropZone("a", createdAt: 150)]
        await model.reload()
        try await harness.clock.waitForSleepers()
        await harness.clock.advance(by: .seconds(20))
        #expect(model.status == .pending)
        await harness.clock.advance(by: .seconds(10))
        #expect(model.status == .maybeLost)
        #expect(model.statusText == "Some photos may not have been saved.")

        // The same rows read again change nothing.
        await model.reload()
        #expect(model.status == .maybeLost)

        // A row being named changes the signature: pending again until it goes quiet.
        harness.items.rows = [CaptureTestRows.dropZone("b", name: "Drill", createdAt: 160, updatedAt: 170), CaptureTestRows.dropZone("a", createdAt: 150)]
        await model.reload()
        #expect(model.status == .pending)
    }

    @Test("the stall timer runs from the start, before the first read answers")
    func stallBeforeFirstRead() async throws {
        let harness = QuickSnapReviewHarness(holdReads: true)
        let model = harness.model(expected: 2)
        let read = Task { await model.reload() }
        await harness.items.readLatch?.waitForArrivals(1)
        try await harness.clock.waitForSleepers()
        await harness.clock.advance(by: QuickSnapReviewModel.stallDuration)
        await harness.items.readLatch?.release(())
        await read.value
        // Nothing landed and nothing changed for 30 s.
        #expect(model.status == .maybeLost)
        #expect(!model.showsHeader)
        guard case .nothing = model.placeholder else {
            Issue.record("expected the nothing-saved state, got \(model.placeholder)")
            return
        }
    }

    @Test("a read that finishes after a newer one started is dropped")
    func staleRead() async {
        let harness = QuickSnapReviewHarness(holdReads: true)
        let model = harness.model(expected: 1)
        harness.items.rows = []
        let first = Task { await model.reload() }
        await harness.items.readLatch?.waitForArrivals(1)
        harness.items.rows = [CaptureTestRows.dropZone("a", createdAt: 150)]
        let second = Task { await model.reload() }
        await harness.items.readLatch?.waitForArrivals(2)
        await harness.items.readLatch?.release(())
        await first.value
        #expect(model.loaded == nil)
        await harness.items.readLatch?.release(())
        await second.value
        #expect(model.list.map(\.id) == ["a"])
    }

    @Test("a failed first read is the error state, never \"nothing was saved\"; a failed refresh keeps the rows")
    func failures() async {
        let harness = QuickSnapReviewHarness()
        harness.items.readError = CaptureTestError()
        let model = harness.model(expected: 1)
        await model.reload()
        guard case .error = model.placeholder else {
            Issue.record("expected the error state, got \(model.placeholder)")
            return
        }
        #expect(!model.showsRefreshBanner)

        harness.items.readError = nil
        harness.items.rows = [CaptureTestRows.dropZone("a", createdAt: 150)]
        await model.reload()
        harness.items.readError = CaptureTestError()
        await model.reload()
        #expect(model.list.map(\.id) == ["a"])
        #expect(model.refreshFailed)
        #expect(model.showsRefreshBanner)

        // Offline has the connection banner instead.
        harness.items.readError = HouseholdHttpError(status: 0, code: "offline")
        await model.reload()
        #expect(model.refreshFailed)
        #expect(!model.showsRefreshBanner)
    }

    @Test("nothing landed: the Try again state; everything landed and left: the emptied state")
    func emptyStates() async {
        let harness = QuickSnapReviewHarness()
        let nothing = harness.model(expected: 0)
        await nothing.reload()
        guard case .nothing = nothing.placeholder else {
            Issue.record("expected the nothing-saved state")
            return
        }

        harness.items.rows = [CaptureTestRows.dropZone("a", createdAt: 150)]
        let emptied = harness.model(expected: 1)
        await emptied.reload()
        harness.items.rows = []
        await emptied.reload()
        #expect(emptied.summary.pending == 0)
        guard case .emptied = emptied.placeholder else {
            Issue.record("expected the emptied state, got \(emptied.placeholder)")
            return
        }
        #expect(!emptied.showsHeader)
    }
}

@Suite("QuickSnapReviewModel: rows and actions (05 §6.5)", .timeLimit(.minutes(1)))
@MainActor
struct QuickSnapReviewActionTests {
    @Test("a drop-zone row opens a filing run; a container's row opens the item")
    func openItem() {
        let harness = QuickSnapReviewHarness()
        harness.model(expected: 1).openItem("a")
        harness.model(containerId: "c1", expected: 1).openItem("b")
        #expect(harness.navigation.destinations == [.openItem(id: "a", filing: true), .openItem(id: "b", filing: false)])
    }

    @Test("delete asks first, deletes, removes the files, hides the row at once and invalidates")
    func delete() async {
        let harness = QuickSnapReviewHarness()
        harness.items.rows = [CaptureTestRows.dropZone("b", createdAt: 160), CaptureTestRows.dropZone("a", createdAt: 150)]
        harness.items.deleteResult = .success(DeletionResult(deleted: true, orphanedPhotoUris: ["file:///a.webp", "file:///a-thumb.webp"]))
        let model = harness.model(expected: 2)
        await model.reload()

        await model.delete("a")

        #expect(harness.confirm.asked == [ConfirmOptions(
            title: "Delete this item?",
            body: "This removes it and its photo from this phone. This cannot be undone.",
            confirmLabel: "Delete"
        )])
        #expect(harness.items.deleted == ["a"])
        #expect(harness.photos.deleted == [["file:///a.webp", "file:///a-thumb.webp"]])
        #expect(harness.telemetry.entries == [RecordingTelemetry.Entry(level: "event", name: "item_deleted")])
        #expect(model.list.map(\.id) == ["b"])
        #expect(harness.invalidator.count == 1)
        // It landed: not a photo still on its way.
        #expect(model.summary.pending == 0)
        #expect(model.title == "1 saved to the drop zone")

        // The fresh read no longer has it; hiding is forgotten, the count stays right.
        harness.items.rows = [CaptureTestRows.dropZone("b", createdAt: 160)]
        await model.reload()
        #expect(model.hidden != nil)
        #expect(model.list.map(\.id) == ["b"])
        #expect(model.summary.pending == 0)
    }

    @Test("delete says the household loses it too when paired; Cancel deletes nothing")
    func deletePairedCancelled() async {
        let harness = QuickSnapReviewHarness(confirm: [false])
        harness.paired = true
        harness.items.rows = [CaptureTestRows.dropZone("a", createdAt: 150)]
        let model = harness.model(expected: 1)
        await model.reload()
        await model.delete("a")
        #expect(harness.confirm.asked.first?.body == "This removes it and its photo from the household, on every phone. This cannot be undone.")
        #expect(harness.items.deleted.isEmpty)
        #expect(model.list.map(\.id) == ["a"])
        #expect(harness.invalidator.count == 0)
    }

    @Test("a row another phone deleted first still leaves, but is not counted as deleted here")
    func deletedElsewhere() async {
        let harness = QuickSnapReviewHarness()
        harness.items.rows = [CaptureTestRows.dropZone("a", createdAt: 150)]
        harness.items.deleteResult = .success(.notDeleted)
        let model = harness.model(expected: 1)
        await model.reload()
        await model.delete("a")
        #expect(harness.telemetry.entries.isEmpty)
        #expect(harness.photos.deleted.isEmpty)
        #expect(model.list.isEmpty)
        #expect(harness.invalidator.count == 1)
    }

    @Test("a failed delete logs item_delete_failed with the kind, plays the error haptic and says so")
    func deleteFails() async {
        let harness = QuickSnapReviewHarness(confirm: [true, true])
        harness.items.rows = [CaptureTestRows.dropZone("a", createdAt: 150)]
        let model = harness.model(expected: 1)
        await model.reload()

        harness.items.deleteResult = .failure(HouseholdHttpError(status: 0, code: "offline"))
        await model.delete("a")
        harness.items.deleteResult = .failure(CaptureTestError())
        await model.delete("a")

        #expect(harness.telemetry.entries == [
            RecordingTelemetry.Entry(level: "error", name: "item_delete_failed", payload: ["errorClass": .string("offline")]),
            RecordingTelemetry.Entry(level: "error", name: "item_delete_failed", payload: ["errorClass": .string("local")]),
        ])
        #expect(harness.haptics.played == [.error, .error])
        #expect(harness.toasts.messages == [
            "The item was not deleted. Check the connection and try again.",
            "The item was not deleted. Try again.",
        ])
        #expect(harness.toasts.shown.allSatisfy { $0.options.tone == .error })
        #expect(model.list.map(\.id) == ["a"])
        #expect(harness.invalidator.count == 0)
    }

    @Test("a second trash tap while the question is open does nothing")
    func deleteSingleFlight() async {
        let harness = QuickSnapReviewHarness()
        harness.items.rows = [CaptureTestRows.dropZone("a", createdAt: 150), CaptureTestRows.dropZone("b", createdAt: 140)]
        let model = harness.model(expected: 2)
        await model.reload()
        let held = CaptureTestHeldConfirm()
        let gated = QuickSnapReviewModel(
            route: model.route,
            items: harness.items,
            photos: harness.photos,
            isPaired: { false },
            invalidator: harness.invalidator,
            toasts: harness.toasts,
            confirm: held,
            haptics: harness.haptics.player,
            telemetry: TelemetryReporter(sink: harness.telemetry),
            clock: harness.clock,
            navigate: harness.navigation.navigate
        )
        await gated.reload()
        let first = Task { await gated.delete("a") }
        await held.latch.waitForArrivals(1)
        await gated.delete("b")
        await held.latch.release(true)
        await first.value
        #expect(held.asked.count == 1)
        #expect(harness.items.deleted == ["a"])
    }

    @Test("Done logs fast_review_done, goes back, and offers to view the drop zone")
    func doneDropZone() async {
        let harness = QuickSnapReviewHarness()
        harness.items.rows = [CaptureTestRows.dropZone("b", name: "Drill", createdAt: 160), CaptureTestRows.dropZone("a", createdAt: 150)]
        let model = harness.model(expected: 2)
        await model.reload()

        model.done()
        model.done()
        model.keepShooting()

        // `kept` and `unnamed` are not on the allowlist.
        #expect(harness.telemetry.entries == [RecordingTelemetry.Entry(level: "event", name: "fast_review_done")])
        #expect(harness.navigation.destinations == [.leave(containerId: DropZone.containerId)])
        let toast = harness.toasts.last
        #expect(toast?.message == "2 items are in the drop zone.")
        #expect(toast?.tone == .info)
        #expect(toast?.action?.label == "View")
        #expect(toast?.action?.accessibilityLabel == "View the drop zone")
        #expect(harness.toasts.pressAction())
        #expect(harness.navigation.destinations == [.leave(containerId: DropZone.containerId), .viewDropZone])
    }

    @Test("Done on a container's set says where the items went, without View; nothing saved, nothing said")
    func doneContainer() async {
        let harness = QuickSnapReviewHarness()
        harness.items.rows = [CaptureTestRows.row("a", name: "Drill", createdAt: 150)]
        let model = harness.model(containerId: "c1", expected: 1)
        await model.reload()
        model.done()
        #expect(harness.toasts.last?.message == "1 item added to Tool chest.")
        #expect(harness.toasts.last?.action == nil)

        let emptyHarness = QuickSnapReviewHarness()
        let empty = emptyHarness.model(expected: 0)
        await empty.reload()
        empty.done()
        #expect(emptyHarness.toasts.shown.isEmpty)
        #expect(emptyHarness.navigation.destinations == [.leave(containerId: DropZone.containerId)])
    }

    @Test("Keep shooting continues the set with its start and the photos still expected (U6)")
    func keepShooting() async {
        let harness = QuickSnapReviewHarness()
        // Four shots: two landed, one of them deleted here, two still on their way.
        harness.items.rows = [CaptureTestRows.dropZone("b", createdAt: 160), CaptureTestRows.dropZone("a", createdAt: 150)]
        let model = harness.model(since: 100, expected: 4)
        await model.reload()
        await model.delete("a")
        #expect(model.expectedStillShown == 3)

        model.keepShooting()
        model.tryAgain()
        #expect(harness.navigation.destinations == [.keepShooting(CaptureRoute(containerId: DropZone.containerId, mode: .fast, since: 100, expectedBase: 3))])
    }

    @Test("Try again opens a fresh camera for a new set")
    func tryAgain() async {
        let harness = QuickSnapReviewHarness()
        let model = harness.model(containerId: "c1", expected: 2)
        await model.reload()
        model.tryAgain()
        #expect(harness.navigation.destinations == [.tryAgain(CaptureRoute(containerId: "c1", mode: .fast))])
    }
}
