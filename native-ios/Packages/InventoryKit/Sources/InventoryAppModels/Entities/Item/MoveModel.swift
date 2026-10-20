import InventoryCore
import InventoryStorage
import InventoryStrings
import Observation

/// Moving or filing one item: the Move/File sheet's logic (RN `useMove`,
/// src/hooks/useMove.ts; 07 §3.5, 01 §9.4).
///
/// A pick writes with the item's lock. Success hands the opener a ``MoveResult``, closes the
/// sheet (if it is still in front), refreshes every screen and says where the item went in a
/// toast with Undo; the person stays where they were. A failure keeps the sheet open with a
/// ``notice`` and writes nothing more: an item deleted elsewhere is gone (a household answers
/// nil, never read as success), and an item another phone moved first shows where it is now,
/// with "Here now" following it. The picker is locked while a pick writes (``busyId``); after a
/// successful move it stays locked, because the sheet is closing.
@MainActor
@Observable
public final class MoveModel {
    /// Why the last pick did not move anything (RN `MoveNotice`).
    public struct Notice: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case gone
            case movedElsewhere
            case failed
        }

        public var kind: Kind
        public var message: String
    }

    /// The item as the screen last read it; nil while loading or once it is gone. Set from the
    /// sheet's query on every read (``follow(_:)``).
    public var loaded: ItemWithContext?
    /// The container being moved into, which shows a spinner; the picker is locked meanwhile.
    public private(set) var busyId: String?
    public private(set) var notice: Notice?
    /// The item as re-read when another phone moved it first.
    public private(set) var reread: ItemWithContext?

    @ObservationIgnored private let items: any ItemsRepository
    @ObservationIgnored private let filing: Bool
    @ObservationIgnored private let request: RouteRequest<MoveResult>?
    @ObservationIgnored private let routeResults: RouteResults?
    @ObservationIgnored private let recentPlaces: RecentPlacesStore
    @ObservationIgnored private let invalidator: any InventoryInvalidating
    @ObservationIgnored private let toasts: any ToastPresenting
    @ObservationIgnored private let haptics: HapticPlayer
    @ObservationIgnored private let telemetry: TelemetryReporter
    @ObservationIgnored private let isFocused: @MainActor () -> Bool
    @ObservationIgnored private let close: @MainActor () -> Void
    /// The double-submit guard; never released after a successful move.
    @ObservationIgnored private var busy = false
    /// The last Undo started from the toast (for tests).
    @ObservationIgnored var undoTask: Task<Void, Never>?

    /// - Parameters:
    ///   - filing: part of a filing run from the item screen (`filing=1`).
    ///   - request: the opener's request, answered with the ``MoveResult`` through `routeResults`.
    ///   - isFocused: whether the sheet is still the screen in front (RN `navigation.isFocused()`).
    ///   - close: dismisses the sheet.
    public init(
        items: any ItemsRepository,
        filing: Bool,
        request: RouteRequest<MoveResult>? = nil,
        routeResults: RouteResults? = nil,
        recentPlaces: RecentPlacesStore,
        invalidator: any InventoryInvalidating,
        toasts: any ToastPresenting,
        haptics: @escaping HapticPlayer,
        telemetry: TelemetryReporter = .shared,
        isFocused: @escaping @MainActor () -> Bool,
        close: @escaping @MainActor () -> Void
    ) {
        self.items = items
        self.filing = filing
        self.request = request
        self.routeResults = routeResults
        self.recentPlaces = recentPlaces
        self.invalidator = invalidator
        self.toasts = toasts
        self.haptics = haptics
        self.telemetry = telemetry
        self.isFocused = isFocused
        self.close = close
    }

    /// The item as last known: the newer of the screen's read and the re-read, by `updatedAt`
    /// for the same id (ties go to the screen's read) (RN `newer`).
    public var item: ItemWithContext? {
        guard let loaded, let reread, EntityText.same(loaded.id, reread.id) else { return loaded ?? reread }
        return reread.updatedAt > loaded.updatedAt ? reread : loaded
    }

    /// The item waits in the drop zone, so this is filing it.
    public var inDropZone: Bool {
        item.map { EntityText.same($0.containerId, DropZone.containerId) } ?? false
    }

    /// The sheet's title; empty while loading (RN `sheetTitle`, app/item/[id]/move.tsx:17-20).
    public var title: String {
        guard let item else { return "" }
        let name = item.name
        if inDropZone || filing {
            return name.isEmpty ? L10n.Move.titleFileUnnamed : L10n.Move.titleFile(name: name)
        }
        return name.isEmpty ? L10n.Move.titleMoveUnnamed : L10n.Move.titleMove(name: name)
    }

    /// The picker's mode: filing out of the drop zone, else moving.
    public var pickerMode: PlacePickerMode { inDropZone ? .file : .move }

    /// While a pick writes, the sheet resists a swipe-down (the header Cancel still closes it).
    public var interactiveDismissDisabled: Bool { busyId != nil }

    /// Picks a destination (RN `pick`). Ignored for the drop zone, without an item, while a
    /// pick writes, or for the container it is already in.
    public func pick(_ place: PickedPlace) async {
        guard case .container(let target) = place, let before = item, !busy else { return }
        if EntityText.same(target.id, before.containerId) { return }

        busy = true
        busyId = target.id
        notice = nil
        let outcome = await MoveFlow.attemptMove(items, before: MoveSubject(before), target: target.id)

        switch outcome {
        case .moved(let updatedAt):
            await moved(before: before, target: target, updatedAt: updatedAt)
        case .gone:
            release()
            notice = Notice(kind: .gone, message: L10n.Move.gone)
            haptics(.error)
        case .movedElsewhere(let fresh):
            release()
            reread = fresh
            notice = Notice(kind: .movedElsewhere, message: MoveFlow.movedElsewhereMessage(fresh))
            haptics(.warning)
        case .failed(let cause):
            release()
            telemetry.error("item_move_failed", ["errorClass": .string(describeError(cause, context: .move).kind.rawValue)])
            notice = Notice(kind: .failed, message: MoveFlow.moveFailedMessage(cause))
            haptics(.error)
        }
        // Nothing was written on failure, so nothing is invalidated: the screens underneath
        // re-read when they are back in front.
    }

    /// Puts the item back (the toast's Undo; RN `undo`).
    public func undo(_ move: MoveResult) async {
        let outcome = await MoveFlow.attemptUndo(items, move: move)
        if case .undone = outcome {
            telemetry.event("item_move_undone")
            invalidator.invalidate()
            haptics(.undo)
            toasts.show(ToastOptions(message: L10n.Move.undone))
            return
        }
        if case .conflict = outcome { haptics(.warning) } else { haptics(.error) }
        var payload: TelemetryPayload = ["outcome": .string(outcome.name)]
        if case .failed(let cause) = outcome {
            payload["errorClass"] = .string(describeError(cause, context: .move).kind.rawValue)
        }
        telemetry.error("item_move_undo_failed", payload)
        toasts.show(ToastOptions(message: MoveFlow.undoFailedMessage(outcome) ?? L10n.Move.undoFailedOther, tone: .error))
        // Whatever stopped it, the screen in front should show where the item really is.
        invalidator.invalidate()
    }

    /// Keeps ``loaded`` set from `query` (the sheet's `item:<id>` read) as each read settles,
    /// before the view redraws, so the picker is never built for a read the model has not seen.
    public func follow(_ query: InventoryQuery<ItemWithContext?>) {
        loaded = query.data ?? nil
        query.onSettle = { [weak self, weak query] in
            guard let self, let query else { return }
            loaded = query.data ?? nil
        }
    }

    /// Call when the sheet goes away: an opener still waiting gets nothing (RN `abandonResult`
    /// on unmount). Does nothing after a delivery.
    public func sheetClosed() {
        routeResults?.abandon(request)
    }

    private func release() {
        busy = false
        busyId = nil
    }

    private func moved(before: ItemWithContext, target: PlaceOption, updatedAt: Int64) async {
        let name = before.name
        let fromDropZone = EntityText.same(before.containerId, DropZone.containerId)
        var move = MoveResult(itemId: before.id, from: before.containerId, to: target.id, updatedAt: updatedAt)
        telemetry.event("item_moved")
        haptics(.success)
        recentPlaces.remember(target.id)
        // A filing step reads the drop zone once, while the spinner still shows: the toast
        // below and the run's next item both come from it.
        var moreWaiting: Bool?
        if filing && fromDropZone {
            let after = await MoveFlow.afterFiling(items, itemId: before.id)
            move.waiting = after.waiting
            moreWaiting = after.moreWaiting
        }
        routeResults?.deliver(request, move)
        // Closed first, so the refresh does not redraw the closing sheet; not if it was closed
        // while writing (the header Cancel). The toast and its Undo show either way.
        if isFocused() { close() }
        invalidator.invalidate()
        let undoMove = move
        toasts.show(
            ToastOptions(
                message: MoveFlow.movedMessage(
                    fromDropZone: fromDropZone,
                    filing: filing,
                    moreWaiting: moreWaiting,
                    container: MoveFlow.containerLabel(target),
                    space: target.spaceName
                ),
                action: ToastAction(
                    label: L10n.Common.undo,
                    accessibilityLabel: name.isEmpty ? L10n.Move.undoA11yUnnamed : L10n.Move.undoA11y(name: name),
                    handler: { [self] in undoTask = Task { await undo(undoMove) } }
                )
            )
        )
    }
}
