import InventoryCore
import InventoryStrings
import Observation

/// Live quantity for one item: the number on screen moves at once, and writes are coalesced
/// (RN `useSavedQuantity`, src/hooks/useSavedQuantity.ts; 07 §4.8, 01 §9.3).
///
/// No debounce: the first change writes straight away; changes made while that write is in
/// flight only replace the pending value, and when it returns one more write sends the newest.
/// So five quick taps from q make exactly two writes, q+1 and then q+5, each over the stamp
/// the previous one returned. A conflict re-reads the item and tries again, at most three times;
/// a failure snaps the number back, says why (``error``) and, except for a vanished item, plays
/// the error haptic.
///
/// One model per item id: recreate it when the row shows another item. The view keeps it current
/// with ``itemDidChange(quantity:updatedAt:)`` whenever its read brings a new quantity or stamp.
@MainActor
@Observable
public final class SavedQuantityModel {
    /// Why a quantity did not save (RN `QuantityErrorKind`).
    public enum ErrorKind: String, Sendable, Hashable {
        /// The network, or a home server that did not answer.
        case offline
        /// The item was deleted elsewhere.
        case gone
        /// Anything else.
        case other

        /// The sentence a large stepper shows under itself (RN `MESSAGES`).
        public var message: String {
            switch self {
            case .offline: L10n.Quantity.notSavedOffline
            case .gone: L10n.Quantity.gone
            case .other: L10n.Quantity.notSaved
            }
        }
    }

    /// How many conflicts in a row are retried before giving up (RN `MAX_CONFLICT_RETRIES`).
    public nonisolated static let maxConflictRetries = 3

    public let itemId: String
    /// The count on screen (optimistic).
    public private(set) var quantity: Int
    /// Why the last change did not save; cleared by the next change.
    public private(set) var errorKind: ErrorKind?

    @ObservationIgnored private let items: any ItemsRepository
    @ObservationIgnored private let invalidator: any InventoryInvalidating
    @ObservationIgnored private let haptics: HapticPlayer
    @ObservationIgnored private let telemetry: TelemetryReporter
    @ObservationIgnored private let onError: (@MainActor (ErrorKind) -> Void)?
    /// The last quantity and stamp the store confirmed.
    @ObservationIgnored private var confirmed: (quantity: Int, updatedAt: Int64)
    @ObservationIgnored private var pending: Int?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var retries = 0
    /// The running write loop (for tests).
    @ObservationIgnored var flushTask: Task<Void, Never>?

    /// - Parameter onError: where a compact stepper reports a failure (a toast naming the
    ///   item, ``notSavedMessage(itemName:kind:)``); a large one shows ``error`` instead.
    public init(
        itemId: String,
        quantity: Int,
        updatedAt: Int64,
        items: any ItemsRepository,
        invalidator: any InventoryInvalidating,
        haptics: @escaping HapticPlayer,
        telemetry: TelemetryReporter = .shared,
        onError: (@MainActor (ErrorKind) -> Void)? = nil
    ) {
        self.itemId = itemId
        self.quantity = quantity
        self.items = items
        self.invalidator = invalidator
        self.haptics = haptics
        self.telemetry = telemetry
        self.onError = onError
        confirmed = (quantity, updatedAt)
    }

    /// The sentence for ``errorKind``, if any.
    public var error: String? { errorKind?.message }

    /// The large stepper's "None left right now" note: at zero, with no error showing.
    public var showsNoneRightNow: Bool { errorKind == nil && quantity == 0 }

    /// The screen read the item again. A new quantity or stamp is taken only while nothing is
    /// pending or being written (RN :69-73).
    public func itemDidChange(quantity: Int, updatedAt: Int64) {
        guard pending == nil, !inFlight else { return }
        confirmed = (quantity, updatedAt)
        self.quantity = quantity
    }

    /// The stepper's new count: shown at once (clamped to 0…9999), written through.
    public func setQuantity(_ next: Int) {
        let clamped = clampQuantity(next)
        quantity = clamped
        errorKind = nil
        pending = clamped
        flush()
    }

    /// The compact stepper's toast: "The quantity of “Wood screws” was not saved." plus a hint
    /// (RN `SavedQuantityStepper`).
    public static func notSavedMessage(itemName: String, kind: ErrorKind) -> String {
        L10n.Quantity.notSavedNamed(name: labelName(itemName) ?? L10n.Entities.unnamedItem, offline: kind == .offline)
    }

    /// The name the stepper's labels use: nil for an unnamed item, so they stay generic.
    public static func labelName(_ itemName: String) -> String? {
        EntityText.hasText(itemName) ? itemName : nil
    }

    /// Starts the write loop unless one is running; a running loop picks up the newest pending
    /// count (RN `flush`). The flag is set before the loop's task starts, so a second change
    /// made before it runs never starts a second loop.
    private func flush() {
        if inFlight { return }
        inFlight = true
        flushTask = Task {
            await writeUntilConfirmed()
            inFlight = false
        }
    }

    /// Writes until the shown count is confirmed (the body of RN `flush`).
    private func writeUntilConfirmed() async {
        writing: while let target = pending, target != confirmed.quantity {
            do {
                let updated = try await items.update(
                    itemId, UpdateItemInput(quantity: target, expectedUpdatedAt: confirmed.updatedAt))
                guard let updated else {
                    // Deleted elsewhere: the screen re-reads (gone, or the row drops out).
                    pending = nil
                    quantity = confirmed.quantity
                    fail(.gone)
                    invalidator.invalidate()
                    break writing
                }
                confirmed = (updated.quantity, updated.updatedAt)
                retries = 0
                telemetry.event("item_updated")
                if pending == target { pending = nil }
                invalidator.invalidate()
            } catch is ConflictError where retries < Self.maxConflictRetries {
                // RN quirk kept (01 Q8): `retries` is reset only by a successful write and by
                // the generic failure below, not by the gone or re-read exits here.
                retries += 1
                do {
                    guard let fresh = try await items.getById(itemId) else {
                        pending = nil
                        quantity = confirmed.quantity
                        fail(.gone)
                        invalidator.invalidate()
                        break writing
                    }
                    confirmed = (fresh.quantity, fresh.updatedAt)
                    continue writing
                } catch {
                    pending = nil
                    quantity = confirmed.quantity
                    fail(.other)
                    break writing
                }
            } catch {
                pending = nil
                retries = 0
                quantity = confirmed.quantity
                // Read like every other failure, so a home box down behind Cloudflare also
                // says "check the connection".
                let kind = describeError(error, context: .quantity, subject: .item).kind
                fail(kind == .offline ? .offline : kind == .gone ? .gone : .other)
                if kind == .gone { invalidator.invalidate() }
                haptics(.error)
                break writing
            }
        }
        if pending == confirmed.quantity { pending = nil }
    }

    private func fail(_ kind: ErrorKind) {
        errorKind = kind
        onError?(kind)
    }
}
