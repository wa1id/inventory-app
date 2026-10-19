import InventoryCore
import InventoryServices
import Testing
@testable import InventoryAppModels

/// RN `place` in captureFlow.test.ts.
private let captureFlowPlace = CaptureIntoPlace(
    containerId: "c1",
    containerName: "Tool chest",
    containerShortCode: "CAB-J92R",
    spaceId: "s1",
    spaceName: "Garage",
    spaceColor: "#5B8DEF"
)

private func summary(saved: Int, named: Int, unnamed: Int, pending: Int) -> FastSessionSummary {
    FastSessionSummary(saved: saved, named: named, unnamed: unnamed, pending: pending)
}

@Suite("CaptureFlow.fastStatus (captureFlow.test.ts)")
struct CaptureFlowFastStatusTests {
    @Test("counts what is still on its way first")
    func pendingFirst() {
        #expect(CaptureFlow.fastStatus(FastTallies(captured: 3, completed: 1, recognized: 1)) == FastStatus(text: "Identifying 2…", settled: false))
    }

    @Test("keeps identified, unnamed and saved apart once everything has landed")
    func keepsApart() {
        #expect(CaptureFlow.fastStatus(FastTallies(captured: 3, completed: 3, recognized: 3)).text == "3 identified")
        #expect(CaptureFlow.fastStatus(FastTallies(captured: 3, completed: 3, recognized: 1)).text == "1 identified · 2 to name")
        #expect(CaptureFlow.fastStatus(FastTallies(captured: 2, completed: 2, recognized: 0)).text == "2 saved · name them later")
        #expect(CaptureFlow.fastStatus(FastTallies(captured: 1, completed: 1, recognized: 0)).text == "1 saved · name it later")
    }

    @Test("never shows a tick the font does not have")
    func noTick() {
        let status = CaptureFlow.fastStatus(FastTallies(captured: 2, completed: 2, recognized: 2))
        #expect(!status.text.contains("✓"))
        #expect(status.settled)
    }

    @Test("a failed pipeline leaves the set settled without counting it as unnamed")
    func failedPipeline() {
        // Two shots, one dropped (captured back to 1), one completed and named.
        #expect(CaptureFlow.fastStatus(FastTallies(captured: 1, completed: 1, recognized: 1)) == FastStatus(text: "1 identified", settled: true))
    }
}

@Suite("CaptureFlow.leaveCamera (captureFlow.test.ts)")
struct CaptureFlowLeaveCameraTests {
    @Test("sends a fast set with shots to the review, so it cannot be skipped")
    func review() {
        #expect(CaptureFlow.leaveCamera(mode: .fast, captured: 2) == .review)
    }

    @Test("just closes otherwise")
    func back() {
        #expect(CaptureFlow.leaveCamera(mode: .fast, captured: 0) == .back)
        #expect(CaptureFlow.leaveCamera(mode: .single, captured: 0) == .back)
        #expect(CaptureFlow.leaveCamera(mode: .single, captured: 3) == .back)
    }
}

@Suite("CaptureFlow.intoA11y (captureFlow.test.ts)")
struct CaptureFlowIntoA11yTests {
    @Test("names the container, its space and its spelled label")
    func named() {
        #expect(CaptureFlow.intoA11y(containerId: "c1", place: captureFlowPlace) == "Photos go into Tool chest, in Garage, label C A B, J 9 2 R")
    }

    @Test("falls back to the label for an unnamed container")
    func unnamed() {
        var place = captureFlowPlace
        place.containerName = nil
        #expect(CaptureFlow.intoA11y(containerId: "c1", place: place) == "Photos go into the container in Garage, label C A B, J 9 2 R")
        // An empty name is no name either (JS truthiness).
        place.containerName = ""
        #expect(CaptureFlow.intoA11y(containerId: "c1", place: place) == "Photos go into the container in Garage, label C A B, J 9 2 R")
    }

    @Test("says drop zone for the drop zone and while the place is unknown")
    func dropZone() {
        #expect(CaptureFlow.intoA11y(containerId: DropZone.containerId, place: nil) == "Photos go into the drop zone")
        #expect(CaptureFlow.intoA11y(containerId: DropZone.containerId, place: captureFlowPlace) == "Photos go into the drop zone")
        #expect(CaptureFlow.intoA11y(containerId: "c1", place: nil) == "Photos go into the drop zone")
    }
}

@Suite("CaptureFlow.reviewStatus (captureFlow.test.ts)")
struct CaptureFlowReviewStatusTests {
    @Test("says \"Saving N more…\" while photos are still landing")
    func pending() {
        let value = summary(saved: 1, named: 1, unnamed: 0, pending: 2)
        #expect(CaptureFlow.reviewStatus(value, stalled: false) == .pending)
        #expect(CaptureFlow.reviewStatusText(.pending, value) == "Saving 2 more…")
    }

    @Test("stops promising once the set has gone quiet")
    func stalled() {
        let value = summary(saved: 1, named: 1, unnamed: 0, pending: 2)
        #expect(CaptureFlow.reviewStatus(value, stalled: true) == .maybeLost)
        #expect(CaptureFlow.reviewStatusText(.maybeLost, value) == "Some photos may not have been saved.")
    }

    @Test("counts what still needs a name, or says all are named")
    func toName() {
        let two = summary(saved: 3, named: 1, unnamed: 2, pending: 0)
        #expect(CaptureFlow.reviewStatus(two, stalled: true) == .toName)
        #expect(CaptureFlow.reviewStatusText(.toName, two) == "2 still need a name")
        #expect(CaptureFlow.reviewStatusText(.toName, summary(saved: 3, named: 1, unnamed: 1, pending: 0)) == "1 still needs a name")
        let named = summary(saved: 3, named: 3, unnamed: 0, pending: 0)
        #expect(CaptureFlow.reviewStatus(named, stalled: false) == .allNamed)
        #expect(CaptureFlow.reviewStatusText(.allNamed, named) == "All named")
    }

    @Test("works on what summarizeSession reports")
    func onSummary() {
        let items = [CaptureTestRows.row("a", name: "Drill"), CaptureTestRows.row("b")]
        #expect(CaptureFlow.reviewStatus(FastReview.summarize(items, expected: 2), stalled: false) == .toName)
    }
}

@Suite("CaptureFlow review title and toast (captureFlow.test.ts)")
struct CaptureFlowReviewTitleTests {
    @Test("names the container by name, or by its code when unnamed")
    func label() {
        #expect(CaptureFlow.containerLabel([CaptureTestRows.row("a", name: "Drill")]) == "Tool chest")
        #expect(CaptureFlow.containerLabel([CaptureTestRows.row("a", name: "Drill", containerName: nil)]) == "CAB-J92R")
        #expect(CaptureFlow.containerLabel([]) == nil)
        // Only NULL falls back, as JS `??` does.
        #expect(CaptureFlow.containerLabel([CaptureTestRows.row("a", containerName: "")]) == "")
    }

    @Test("says where the set went")
    func whereItWent() {
        let four = summary(saved: 4, named: 3, unnamed: 1, pending: 0)
        #expect(CaptureFlow.reviewTitle(four, status: .toName, containerId: DropZone.containerId, label: nil) == "4 saved to the drop zone")
        let one = summary(saved: 1, named: 1, unnamed: 0, pending: 0)
        #expect(CaptureFlow.reviewTitle(one, status: .allNamed, containerId: "c1", label: "Tool chest") == "1 saved to Tool chest")
    }

    @Test("says what is happening, never \"0 saved\", until the first row lands")
    func savingFirst() {
        let none = summary(saved: 0, named: 0, unnamed: 0, pending: 2)
        #expect(CaptureFlow.reviewTitle(none, status: .pending, containerId: DropZone.containerId, label: nil) == "Saving 2 photos…")
        #expect(CaptureFlow.reviewTitle(summary(saved: 0, named: 0, unnamed: 0, pending: 1), status: .pending, containerId: "c1", label: nil) == "Saving 1 photo…")
        #expect(CaptureFlow.reviewStatusText(.pending, none) == "They appear here as they are saved.")
        let some = summary(saved: 1, named: 1, unnamed: 0, pending: 1)
        #expect(CaptureFlow.reviewTitle(some, status: .pending, containerId: DropZone.containerId, label: nil) == "1 saved to the drop zone")
    }

    @Test("never says \"the drop zone\" for a container whose rows have not landed yet")
    func noDropZoneForContainer() {
        let none = summary(saved: 0, named: 0, unnamed: 0, pending: 0)
        #expect(CaptureFlow.reviewTitle(none, status: .allNamed, containerId: "c1", label: nil) == nil)
        #expect(CaptureFlow.reviewDoneToast(saved: 2, containerId: "c1", label: nil) == nil)
    }

    @Test("offers to view the drop zone, but not a container the person is back on")
    func toasts() {
        #expect(CaptureFlow.reviewDoneToast(saved: 4, containerId: DropZone.containerId, label: "Drop zone") == QuickSnapDoneToast(message: "4 items are in the drop zone.", viewDropZone: true))
        #expect(CaptureFlow.reviewDoneToast(saved: 1, containerId: DropZone.containerId, label: nil)?.message == "1 item is in the drop zone.")
        #expect(CaptureFlow.reviewDoneToast(saved: 2, containerId: "c1", label: "Tool chest") == QuickSnapDoneToast(message: "2 items added to Tool chest.", viewDropZone: false))
        #expect(CaptureFlow.reviewDoneToast(saved: 1, containerId: "c1", label: "Tool chest")?.message == "1 item added to Tool chest.")
    }

    @Test("says nothing when nothing was saved")
    func nothingSaved() {
        #expect(CaptureFlow.reviewDoneToast(saved: 0, containerId: DropZone.containerId, label: nil) == nil)
    }
}

@Suite("CaptureFlow.sessionSignature (captureFlow.test.ts)")
struct CaptureFlowSignatureTests {
    @Test("changes when a row lands or is named, not when it is read again")
    func changes() {
        let before = CaptureFlow.sessionSignature([CaptureTestRows.row("a", createdAt: 1, updatedAt: 1)])
        #expect(CaptureFlow.sessionSignature([CaptureTestRows.row("a", createdAt: 1, updatedAt: 1)]) == before)
        #expect(CaptureFlow.sessionSignature([CaptureTestRows.row("a", name: "Drill", createdAt: 1, updatedAt: 2)]) != before)
        #expect(CaptureFlow.sessionSignature([CaptureTestRows.row("a", createdAt: 1, updatedAt: 1), CaptureTestRows.row("b", createdAt: 2, updatedAt: 2)]) != before)
        #expect(before == "a:1")
    }
}

@Suite("CaptureFlow hidden rows (captureFlow.test.ts)")
struct CaptureFlowHiddenRowsTests {
    private let list = [CaptureTestRows.row("a", name: "A"), CaptureTestRows.row("b", name: "B"), CaptureTestRows.row("c", name: "C")]

    @Test("hides filed or deleted rows from the list they were hidden in")
    func hides() {
        let hidden = CaptureFlow.hideRow(CaptureFlow.hideRow(nil, source: 1, id: "a"), source: 1, id: "c")
        #expect(CaptureFlow.visibleRows(list, hidden: hidden, source: 1).map(\.id) == ["b"])
    }

    @Test("lets a fresh read decide, so an item moved back by Undo shows again")
    func freshRead() {
        let hidden = CaptureFlow.hideRow(nil, source: 1, id: "a")
        let fresh = [CaptureTestRows.row("a", name: "A"), CaptureTestRows.row("b", name: "B")]
        #expect(CaptureFlow.visibleRows(fresh, hidden: hidden, source: 2) == fresh)
        #expect(CaptureFlow.hideRow(hidden, source: 2, id: "b").ids == ["b"])
    }

    @Test("shows everything when nothing is hidden")
    func nothingHidden() {
        #expect(CaptureFlow.visibleRows(list, hidden: nil, source: 1) == list)
    }
}

@Suite("CaptureFlow rows that landed and left (captureFlow.test.ts)")
struct CaptureFlowLandedTests {
    @Test("remembers every row the set has shown, and keeps the same set when nothing is new")
    func remembers() {
        let first = CaptureFlow.withLanded([], [CaptureTestRows.row("a"), CaptureTestRows.row("b")])
        #expect(first == ["a", "b"])
        #expect(CaptureFlow.withLanded(first, [CaptureTestRows.row("b", name: "Drill")]) == first)
        #expect(CaptureFlow.withLanded(first, [CaptureTestRows.row("c")]) == ["a", "b", "c"])
    }

    @Test("does not count a filed or deleted row as a photo still on its way")
    func filedRow() {
        // Four shots; all four landed, then one was filed out of the drop zone.
        let expected = CaptureFlow.expectedStillShown(expected: 4, landed: 4, shown: 3)
        #expect(expected == 3)
        let rows = [CaptureTestRows.row("a", name: "A"), CaptureTestRows.row("b", name: "B"), CaptureTestRows.row("c", name: "C")]
        #expect(FastReview.summarize(rows, expected: expected).pending == 0)
    }

    @Test("still counts photos that never landed")
    func neverLanded() {
        // Four shots; three landed, one of those was deleted.
        #expect(CaptureFlow.expectedStillShown(expected: 4, landed: 3, shown: 2) == 3)
        #expect(FastReview.summarize([CaptureTestRows.row("a", name: "A"), CaptureTestRows.row("b", name: "B")], expected: 3).pending == 1)
        #expect(CaptureFlow.expectedStillShown(expected: 0, landed: 2, shown: 0) == 0)
    }
}
