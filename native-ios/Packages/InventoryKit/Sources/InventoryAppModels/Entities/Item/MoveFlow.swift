import InventoryCore
import InventoryStrings

// RN: src/ui/item/moveFlow.ts. The pure half of Move and File: the desk's
// `chooseMove`/`afterMove` as plain functions over the repository calls they make.

/// The item as it was when a move started (RN `MoveSubject`).
public struct MoveSubject: Sendable, Hashable {
    public var id: String
    public var containerId: String
    public var updatedAt: Int64

    public init(id: String, containerId: String, updatedAt: Int64) {
        self.id = id
        self.containerId = containerId
        self.updatedAt = updatedAt
    }

    public init(_ item: ItemWithContext) {
        self.init(id: item.id, containerId: item.containerId, updatedAt: item.updatedAt)
    }
}

/// How a move went (RN `MoveOutcome`).
public enum MoveOutcome: Sendable {
    /// Written; `updatedAt` is the item's new stamp, which Undo expects.
    case moved(updatedAt: Int64)
    /// Deleted on another phone (a household update answers 404 as nil, never read as moved).
    case gone
    /// Someone moved it first; nothing was written. `fresh` is where it is now.
    case movedElsewhere(fresh: ItemWithContext)
    case failed(any Error)
}

/// How an Undo went (RN `UndoOutcome`).
public enum MoveUndoOutcome: Sendable {
    case undone
    case gone
    /// It changed again since the move; a later change elsewhere wins over Undo.
    case conflict
    /// Kept, so the toast blames the connection only when it was the connection.
    case failed(any Error)

    /// The telemetry `outcome`: `undone`, `gone`, `conflict` or `failed`.
    public var name: String {
        switch self {
        case .undone: "undone"
        case .gone: "gone"
        case .conflict: "conflict"
        case .failed: "failed"
        }
    }
}

/// The drop zone read right after a filing step (RN `afterFiling`'s result).
public struct AfterFiling: Sendable, Hashable {
    /// The drop zone's ids, newest first; nil when the read failed.
    public var waiting: [String]?
    /// Whether anything but this item is still waiting; nil when the read failed.
    public var moreWaiting: Bool?

    public init(waiting: [String]?, moreWaiting: Bool?) {
        self.waiting = waiting
        self.moreWaiting = moreWaiting
    }
}

/// Move and File rules (RN `src/ui/item/moveFlow.ts`).
public enum MoveFlow {
    /// Moves `before` into `target`, carrying the optimistic lock (RN `attemptMove`).
    ///
    /// On a conflict it re-reads the item: if it is now somewhere else, another phone moved
    /// it and that is shown rather than overruled; if it is still where it was (a rename or a
    /// quantity changed), the move is retried once with the new stamp.
    public static func attemptMove(
        _ items: any ItemsRepository,
        before: MoveSubject,
        target: String
    ) async -> MoveOutcome {
        do {
            let updated = try await items.update(
                before.id, UpdateItemInput(containerId: target, expectedUpdatedAt: before.updatedAt))
            return updated.map { .moved(updatedAt: $0.updatedAt) } ?? .gone
        } catch is ConflictError {
            // Re-read below.
        } catch {
            return .failed(error)
        }

        do {
            guard let fresh = try await items.getById(before.id) else { return .gone }
            if !EntityText.same(fresh.containerId, before.containerId) { return .movedElsewhere(fresh: fresh) }
            let updated = try await items.update(
                before.id, UpdateItemInput(containerId: target, expectedUpdatedAt: fresh.updatedAt))
            return updated.map { .moved(updatedAt: $0.updatedAt) } ?? .gone
        } catch {
            return .failed(error)
        }
    }

    /// Puts the item back where it came from, but only if nothing touched it since the move:
    /// the lock is the stamp the move left (RN `attemptUndo`).
    public static func attemptUndo(_ items: any ItemsRepository, move: MoveResult) async -> MoveUndoOutcome {
        do {
            let restored = try await items.update(
                move.itemId, UpdateItemInput(containerId: move.from, expectedUpdatedAt: move.updatedAt))
            return restored == nil ? .gone : .undone
        } catch is ConflictError {
            return .conflict
        } catch {
            return .failed(error)
        }
    }

    /// The error toast for an Undo that did not happen (RN `undoFailedMessage`); nil for one
    /// that did.
    public static func undoFailedMessage(_ outcome: MoveUndoOutcome) -> String? {
        switch outcome {
        case .undone: nil
        case .gone: L10n.Move.undoGone
        case .conflict: L10n.Move.undoConflict
        case .failed(let cause):
            describeError(cause, context: .move, subject: .item).kind == .offline
                ? L10n.Move.undoFailed : L10n.Move.undoFailedOther
        }
    }

    /// A container as a toast names it: its name, or the code on its label (RN `containerLabel`).
    public static func containerLabel(name: String?, shortCode: String) -> String {
        name ?? shortCode
    }

    /// ``containerLabel(name:shortCode:)`` for a picker option.
    public static func containerLabel(_ place: PlaceOption) -> String {
        containerLabel(name: place.name, shortCode: place.shortCode)
    }

    /// The toast after a move (RN `movedMessage`): "Moved to", or "Filed in" out of the drop
    /// zone, with "Everything is filed." only when a filing run read the drop zone empty.
    public static func movedMessage(
        fromDropZone: Bool,
        filing: Bool,
        moreWaiting: Bool?,
        container: String,
        space: String
    ) -> String {
        if !fromDropZone { return L10n.Move.movedTo(container: container, space: space) }
        return filing && moreWaiting == false
            ? L10n.Move.filedLast(container: container, space: space)
            : L10n.Move.filedIn(container: container, space: space)
    }

    /// Reads the drop zone once after a filing step (RN `afterFiling`): the toast's
    /// "Everything is filed." and the run's next item both come from this one read.
    public static func afterFiling(_ items: any ItemsRepository, itemId: String) async -> AfterFiling {
        do {
            let waiting = try await items.listUnsorted().map(\.id)
            return AfterFiling(waiting: waiting, moreWaiting: waiting.contains { !EntityText.same($0, itemId) })
        } catch {
            return AfterFiling(waiting: nil, moreWaiting: nil)
        }
    }

    /// The picker notice when another phone moved the item first (RN `movedElsewhereMessage`);
    /// never the drop zone's internal code.
    public static func movedElsewhereMessage(_ fresh: some PlaceLike) -> String {
        if EntityText.same(fresh.containerId, DropZone.containerId) { return L10n.Move.alreadyMovedToDropZone }
        return L10n.Move.alreadyMoved(container: fresh.containerName ?? fresh.containerShortCode)
    }

    /// The picker notice for a move that failed: the connection, or anything else
    /// (RN `moveFailedMessage`).
    public static func moveFailedMessage(_ cause: any Error) -> String {
        describeError(cause, context: .move, subject: .item).kind == .offline ? L10n.Move.failed : L10n.Move.failedOther
    }

    /// The next item of a filing run (RN `nextInRun`).
    ///
    /// `before` is the drop zone when this item's move started; `waiting` is the drop zone
    /// now. The item after this one in `before` is next, wrapping round, skipping this item and
    /// anything filed or deleted meanwhile; items that arrived since come last. Nil when
    /// nothing is left.
    public static func nextInRun(before: [String], currentId: String, waiting: [String]) -> String? {
        let left = waiting.filter { !EntityText.same($0, currentId) }
        func isLeft(_ id: String) -> Bool { left.contains { EntityText.same($0, id) } }
        if left.isEmpty { return nil }
        let start = (before.firstIndex { EntityText.same($0, currentId) } ?? -1) + 1
        for offset in 0..<before.count {
            let id = before[(start + offset) % before.count]
            if isLeft(id) { return id }
        }
        return waiting.first(where: isLeft)
    }
}
