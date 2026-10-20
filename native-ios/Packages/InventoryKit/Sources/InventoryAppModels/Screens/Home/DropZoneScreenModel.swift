import InventoryCore
import InventoryStrings
import Observation

/// The Drop zone tab: the holding area for things added "somewhere" or photographed with Quick
/// Snap, and the owner's filing queue (RN app/(tabs)/drop-zone.tsx; 06 §7.2).
///
/// The list is the shared drop-zone read (``DropZoneModel``, also behind the tab badge and
/// Home's card), so the three never disagree; the tab shell drives it. Filing a named item is
/// two taps and she stays on the list: "File…" opens the move sheet for a ``MoveResult``, and the
/// row leaves as soon as the item is filed rather than when the refetch lands. The move sheet's
/// toast ("Filed in …" with Undo) is the confirmation.
@MainActor
@Observable
public final class DropZoneScreenModel {
    /// Opens the move sheet for an item (not as a filing run: the list itself is the run) and
    /// waits for its answer; nil when it closed without moving anything.
    public typealias OpenMove = @MainActor (_ itemId: String) async -> MoveResult?

    /// What stands in for the list while no rows show.
    public enum Placeholder {
        /// No answer yet: a skeleton.
        case loading
        /// The first read failed: never "everything is filed" (RN issue #12).
        case failed(any Error)
        /// Nothing is waiting.
        case allFiled
    }

    /// The shared read.
    public let dropZone: DropZoneModel
    /// Rows filed a moment ago, hidden until the next read (bound to the read they were hidden in).
    public private(set) var hidden: QuickSnapHiddenRows?
    /// A move sheet is opening or open: a second "File…" waits rather than stacking another.
    public private(set) var isFiling = false

    @ObservationIgnored private let openMove: OpenMove
    @ObservationIgnored private let rememberCategories: @MainActor ([String?]) -> Void
    @ObservationIgnored private let animate: @MainActor (@MainActor () -> Void) -> Void
    @ObservationIgnored private var rememberedGeneration: Int?

    /// - Parameters:
    ///   - dropZone: the shared drop-zone read (`app.dropZone`).
    ///   - openMove: presents the move sheet for a result.
    ///   - rememberCategories: feeds the waiting items' categories to the category memory, so
    ///     they are offered when naming them.
    ///   - animate: runs a change to the rows with the layout animation (a filed row leaving).
    public init(
        dropZone: DropZoneModel,
        openMove: @escaping OpenMove,
        rememberCategories: @escaping @MainActor ([String?]) -> Void = { _ in },
        animate: @escaping @MainActor (@MainActor () -> Void) -> Void = { $0() }
    ) {
        self.dropZone = dropZone
        self.openMove = openMove
        self.rememberCategories = rememberCategories
        self.animate = animate
    }

    // MARK: Outputs

    /// The waiting items, newest first, without the ones filed a moment ago (RN `visibleRows`).
    public var rows: [ItemWithContext] {
        CaptureFlow.visibleRows(dropZone.items, hidden: hidden, source: dropZone.readGeneration)
    }

    /// "4 items waiting for a place. Open one to name it, then file it.", only while rows show;
    /// with nothing waiting the empty state says it, and its primary is the one Quick Snap.
    public var subtitle: String? {
        let count = rows.count
        return count > 0 ? L10n.DropZone.intro2(count: count) : nil
    }

    /// Quick Snap under the intro, only while rows show.
    public var showsQuickSnap: Bool { !rows.isEmpty }

    /// "Could not be refreshed" over the old list, unless the connection banner or the
    /// removed-phone layer already explains it (RN `needsRefreshBanner`).
    public var showsRefreshBanner: Bool {
        needsRefreshBanner(dropZone.refreshFailed, cause: dropZone.cause)
    }

    /// The state in place of the list when no rows show (RN `ListEmptyComponent`); nil while
    /// there are rows. With rows on screen a failed refresh shows only the banner.
    public var placeholder: Placeholder? {
        guard rows.isEmpty else { return nil }
        if dropZone.loading { return .loading }
        if let cause = dropZone.cause, !dropZone.refreshFailed { return .failed(cause) }
        return .allFiled
    }

    // MARK: Inputs

    /// "File…" on a row: opens the move sheet, and once the item is filed hides its row at once
    /// and reads the list again. One sheet at a time; closing the sheet changes nothing.
    public func file(_ itemId: String) async {
        guard !isFiling else { return }
        isFiling = true
        defer { isFiling = false }
        guard await openMove(itemId) != nil else { return }
        // The list as drawn now: a refetch may have replaced the one the row was tapped in
        // while the sheet was open (RN `shownRef`).
        let source = dropZone.readGeneration
        animate { [self] in
            hidden = CaptureFlow.hideRow(hidden, source: source, id: itemId)
        }
        dropZone.reload()
    }

    /// The items changed (call it on appear and whenever ``DropZoneModel/readGeneration``
    /// moves): their categories are offered when naming them. Once per read.
    public func itemsChanged() {
        let generation = dropZone.readGeneration
        guard dropZone.query.data != nil, rememberedGeneration != generation else { return }
        rememberedGeneration = generation
        rememberCategories(dropZone.items.map(\.item.category))
    }

    /// Try again, on the banner or the error state.
    public func retry() {
        dropZone.reload()
    }

    /// Pull to refresh: returns once the read has answered (RN's spinner follows `reading`).
    public func refresh() async {
        await dropZone.refresh()
    }

    // MARK: Layout

    /// The row thumbnail: 76 pt, or 56 pt when the second line would be too narrow for
    /// "×30 · 28 days ago" beside the photo and "File…" (RN drop-zone.tsx:28-35,65). The photo
    /// needs a window 390 pt wide at standard text, wider as text grows (text smaller than
    /// standard does not lower the bar); stacked rows put "File…" under the text, so they keep
    /// it.
    ///
    /// - Parameters:
    ///   - windowWidth: the window's width in points.
    ///   - fontScale: RN's font scale for the Dynamic Type size (1 at Large).
    ///   - stacked: the row's control goes under its text (`LayoutScale`).
    public nonisolated static func thumbSize(windowWidth: Double, fontScale: Double, stacked: Bool) -> Int {
        stacked || windowWidth >= photoThumbWidth * max(fontScale, 1) ? 76 : 56
    }

    /// RN `PHOTO_THUMB_WIDTH`.
    public nonisolated static let photoThumbWidth: Double = 390
}
