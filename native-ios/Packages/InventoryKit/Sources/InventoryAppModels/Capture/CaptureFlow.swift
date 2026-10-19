import InventoryCore
import InventoryServices
import InventoryStrings

/// The camera's two modes (RN `CaptureMode`): one photo that opens the Add sheet, or Quick Snap.
public enum CaptureMode: String, Sendable, Hashable, CaseIterable {
    case single
    case fast
}

/// Fast-mode counters as the camera keeps them (RN `FastTallies`): shutter presses that produced a
/// photo, pipelines that finished, and those that came back named.
public struct FastTallies: Sendable, Hashable {
    public var captured: Int
    public var completed: Int
    public var recognized: Int

    public init(captured: Int, completed: Int, recognized: Int) {
        self.captured = captured
        self.completed = completed
        self.recognized = recognized
    }
}

/// The fast-mode status pill: its text, and whether everything has landed (a check icon then).
public struct FastStatus: Sendable, Hashable {
    public var text: String
    public var settled: Bool

    public init(text: String, settled: Bool) {
        self.text = text
        self.settled = settled
    }
}

/// Where ✕ goes (RN `leaveCamera`).
public enum CaptureLeave: String, Sendable, Hashable {
    /// A fast set with shots always ends on its review.
    case review
    /// Back to where the camera was opened from.
    case back
}

/// The line under the review's title (RN `ReviewStatus`).
public enum QuickSnapReviewStatus: String, Sendable, Hashable, CaseIterable {
    /// Photos still on their way, and the set is still changing.
    case pending
    /// Photos still expected, but the set has not changed for 30 s.
    case maybeLost
    /// Everything landed; some rows need a name.
    case toName
    /// Everything landed and every row is named.
    case allNamed
}

/// The toast after the review's Done (RN `reviewDoneToast` result).
public struct QuickSnapDoneToast: Sendable, Hashable {
    public var message: String
    /// The drop zone offers View; a container does not (the person is back on it).
    public var viewDropZone: Bool

    public init(message: String, viewDropZone: Bool) {
        self.message = message
        self.viewDropZone = viewDropZone
    }
}

/// Rows hidden the moment they were deleted, bound to the read they were hidden in (RN `HiddenRows`).
///
/// RN tied the hiding to the list array's identity, so a fresh read replaced it (an item moved
/// back by Undo shows again). Swift arrays are values, so the read is identified by a number the
/// review model bumps on every settled read.
public struct QuickSnapHiddenRows: Sendable, Hashable {
    /// The read the rows were hidden in.
    public var source: Int
    public var ids: Set<String>

    public init(source: Int, ids: Set<String>) {
        self.source = source
        self.ids = ids
    }
}

/// The decisions behind the capture and review screens, kept free of UI so they are tested on the
/// Mac (05 §4.10, §6.2-6.5). Copy comes from the String Catalog.
// RN: src/ui/capture/captureFlow.ts
public enum CaptureFlow {
    /// The fast-mode status pill (RN `fastStatus`, 05 §4.10). The counters stay apart on purpose:
    /// reporting completions as identifications would claim work the recogniser did not do.
    ///
    /// `pending = captured − completed`, `unnamed = completed − recognized`; pending first, then
    /// all identified, then all unnamed, then both. A pipeline that failed takes its shot out of
    /// `captured` without completing, so it is neither pending nor unnamed.
    // RN: src/ui/capture/captureFlow.ts:26-41
    public static func fastStatus(_ tallies: FastTallies) -> FastStatus {
        let pending = tallies.captured - tallies.completed
        let unnamed = tallies.completed - tallies.recognized
        let text = if pending > 0 {
            L10n.Capture.identifying(count: pending)
        } else if unnamed == 0 {
            L10n.Capture.identified(count: tallies.recognized)
        } else if tallies.recognized == 0 {
            L10n.Capture.savedUnnamed(count: unnamed)
        } else {
            L10n.Capture.identifiedPartly(identified: tallies.recognized, unnamed: unnamed)
        }
        return FastStatus(text: text, settled: pending <= 0)
    }

    /// Where ✕ goes: a fast set with shots always ends on the review, so a batch can never skip
    /// it; otherwise the camera simply closes (RN `leaveCamera`).
    // RN: src/ui/capture/captureFlow.ts:48-50
    public static func leaveCamera(mode: CaptureMode, captured: Int) -> CaptureLeave {
        mode == .fast && captured > 0 ? .review : .back
    }

    /// The Into pill, spoken: where the photos will go (RN `intoA11y`). The drop zone, and a place
    /// not loaded yet, read as the drop zone; a container name counts only when non-empty.
    // RN: src/ui/capture/captureFlow.ts:53-59
    public static func intoA11y(containerId: String, place: (any PlaceLike)?) -> String {
        guard containerId != DropZone.containerId, let place else { return L10n.Capture.intoDropZoneA11y }
        let spelled = spellCode(place.containerShortCode)
        if let name = place.containerName, !name.isEmpty {
            return L10n.Capture.intoContainerA11y(container: name, space: place.spaceName, spelled: spelled)
        }
        return L10n.Capture.intoSpaceA11y(space: place.spaceName, spelled: spelled)
    }

    /// The review's status (RN `reviewStatus`). `stalled` matters only while photos are pending:
    /// `expected` is frozen when the camera closes, so a shot that failed afterwards would
    /// otherwise leave it saying "Saving…" for ever.
    // RN: src/ui/capture/captureFlow.ts:80-83
    public static func reviewStatus(_ summary: FastSessionSummary, stalled: Bool) -> QuickSnapReviewStatus {
        if summary.pending > 0 { return stalled ? .maybeLost : .pending }
        return summary.unnamed > 0 ? .toName : .allNamed
    }

    /// The status line's words (RN `reviewStatusText`). Under "Saving 2 photos…" (nothing landed
    /// yet), "2 more" would repeat the title, so it explains instead.
    // RN: src/ui/capture/captureFlow.ts:85-99
    public static func reviewStatusText(_ status: QuickSnapReviewStatus, _ summary: FastSessionSummary) -> String {
        switch status {
        case .pending:
            summary.saved == 0 ? L10n.Review.savingFirst : L10n.Review.pending(count: summary.pending)
        case .maybeLost:
            L10n.Review.maybeLost
        case .toName:
            L10n.Review.toName(count: summary.unnamed)
        case .allNamed:
            L10n.Review.allNamed
        }
    }

    /// What the set's rows call their container: the first row's container name, or its label
    /// code when the name is NULL, or nil for no rows (RN `containerLabel`). Only NULL falls back,
    /// as JS `??` does: an empty name stays empty.
    // RN: src/ui/capture/captureFlow.ts:106-112
    public static func containerLabel(_ items: [ItemWithContext]) -> String? {
        guard let first = items.first else { return nil }
        return first.containerName ?? first.containerShortCode
    }

    /// "4 saved to the drop zone" / "4 saved to Tool chest" (RN `reviewTitle`). Until the first
    /// row lands it says what is happening ("Saving 2 photos…"), never "0 saved". A container's
    /// name comes from its rows, so without one there is no title rather than a wrong one.
    // RN: src/ui/capture/captureFlow.ts:120-130
    public static func reviewTitle(
        _ summary: FastSessionSummary,
        status: QuickSnapReviewStatus,
        containerId: String,
        label: String?
    ) -> String? {
        if summary.saved == 0 && status == .pending { return L10n.Review.savingTitle(count: summary.pending) }
        if containerId == DropZone.containerId { return L10n.Review.savedToDropZone(count: summary.saved) }
        return label.map { L10n.Review.savedTo(count: summary.saved, container: $0) }
    }

    /// The toast after Done (RN `reviewDoneToast`): nothing when nothing was saved; the drop zone
    /// offers View; a container needs its label.
    // RN: src/ui/capture/captureFlow.ts:136-148
    public static func reviewDoneToast(saved: Int, containerId: String, label: String?) -> QuickSnapDoneToast? {
        if saved == 0 { return nil }
        if containerId == DropZone.containerId {
            return QuickSnapDoneToast(message: L10n.Review.doneDropZone(count: saved), viewDropZone: true)
        }
        return label.map { QuickSnapDoneToast(message: L10n.Review.doneContainer(count: saved, container: $0), viewDropZone: false) }
    }

    /// Every row the set has shown so far, by id (RN `withLanded`). A row that has since left the
    /// list (deleted, filed, moved) has landed all the same: it is not a photo still on its way.
    // RN: src/ui/capture/captureFlow.ts:156-164
    public static func withLanded(_ landed: Set<String>, _ items: [ItemWithContext]) -> Set<String> {
        landed.union(items.map(\.id))
    }

    /// The `expected` to measure what is shown against: the camera's count less the rows that
    /// landed and have left since (RN `expectedStillShown`).
    // RN: src/ui/capture/captureFlow.ts:173-175
    public static func expectedStillShown(expected: Int, landed: Int, shown: Int) -> Int {
        max(0, expected - max(0, landed - shown))
    }

    /// A fingerprint of a set's rows (RN `sessionSignature`): it changes when a row lands, is named
    /// or goes, not when the same rows are read again.
    // RN: src/ui/capture/captureFlow.ts:182-184
    public static func sessionSignature(_ items: [ItemWithContext]) -> String {
        items.map { "\($0.id):\($0.updatedAt)" }.joined(separator: "|")
    }

    /// Hides `id` in the read `source` (RN `hideRow`): rows hidden in an older read are forgotten.
    // RN: src/ui/capture/captureFlow.ts:197-205
    public static func hideRow(_ previous: QuickSnapHiddenRows?, source: Int, id: String) -> QuickSnapHiddenRows {
        var ids: Set<String> = []
        if let previous, previous.source == source { ids = previous.ids }
        ids.insert(id)
        return QuickSnapHiddenRows(source: source, ids: ids)
    }

    /// The rows of read `source` without the hidden ones (RN `visibleRows`); hiding from another
    /// read is ignored, so a fresh read decides.
    // RN: src/ui/capture/captureFlow.ts:207-210
    public static func visibleRows(_ items: [ItemWithContext], hidden: QuickSnapHiddenRows?, source: Int) -> [ItemWithContext] {
        guard let hidden, hidden.source == source else { return items }
        return items.filter { !hidden.ids.contains($0.id) }
    }
}
