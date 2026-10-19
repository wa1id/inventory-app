import InventoryCore
import InventoryStrings
import Observation

/// "What is it?" in place of the title of an item that has no name yet, a Quick Snap photo
/// (RN `NameItInline`, src/ui/item/NameItInline.tsx; 07 §3.3, 05 §12).
///
/// What is typed belongs to this model, which the item screen keeps per item id while the field
/// is in use (``engaged``), so neither a re-read nor a name arriving meanwhile takes it away.
/// Recognition often finishes while the owner is typing: its name is offered (``offered``,
/// "Use “AA batteries”"), and "Save name" still saves what she typed. A save runs at most once
/// at a time and carries the item's lock; another name met on the way is reported, never
/// written over unasked.
///
/// The screen keeps ``itemUpdatedAt`` and ``incomingName`` current from its read, binds the
/// field to ``value`` and ``focused``, and is told through `onNamed` once the item has a name.
@MainActor
@Observable
public final class NameItModel {
    /// A name a save ran into, with its stamp, which the next save goes over.
    public struct Meanwhile: Sendable, Hashable {
        public var name: String
        public var updatedAt: Int64
    }

    public let itemId: String
    /// The item's stamp as the screen last read it.
    public var itemUpdatedAt: Int64
    /// The item's name as last read, or `""` while it has none.
    public var incomingName: String
    /// What is typed. Typing clears the error.
    public var value: String {
        didSet { if error != nil { error = nil } }
    }
    /// The field has focus.
    public var focused = false
    public private(set) var saving = false
    /// Under the field: why the name was not saved.
    public private(set) var error: String?
    public private(set) var meanwhile: Meanwhile?
    /// The item has a name now (saved here, or the offered one chosen): the field is on its way out.
    public private(set) var named = false

    @ObservationIgnored private let items: any ItemsRepository
    @ObservationIgnored private let invalidator: any InventoryInvalidating
    @ObservationIgnored private let haptics: HapticPlayer
    @ObservationIgnored private let telemetry: TelemetryReporter
    @ObservationIgnored private let announce: @MainActor (String) -> Void
    @ObservationIgnored private let onNamed: @MainActor (String) -> Void
    /// The single-flight guard (RN `savingRef`).
    @ObservationIgnored private var savingGuard = false

    /// - Parameters:
    ///   - announce: posts a VoiceOver announcement (errors are announced each time they are set).
    ///   - onNamed: the item now has this name; the screen shows it, dismisses the keyboard and
    ///     moves focus on.
    public init(
        itemId: String,
        updatedAt: Int64,
        incomingName: String,
        items: any ItemsRepository,
        invalidator: any InventoryInvalidating,
        haptics: @escaping HapticPlayer,
        telemetry: TelemetryReporter = .shared,
        announce: @escaping @MainActor (String) -> Void = { _ in },
        onNamed: @escaping @MainActor (String) -> Void
    ) {
        self.itemId = itemId
        itemUpdatedAt = updatedAt
        self.incomingName = incomingName
        value = ""
        self.items = items
        self.invalidator = invalidator
        self.haptics = haptics
        self.telemetry = telemetry
        self.announce = announce
        self.onNamed = onNamed
    }

    /// The newest name the item has: the one a save ran into, until the screen's re-read
    /// catches up; else the stored one (RN `theirs`).
    public var theirs: String {
        if let meanwhile, meanwhile.updatedAt > itemUpdatedAt { return meanwhile.name }
        return incomingName
    }

    /// Their name, offered under the field when it differs from what is typed (RN `offered`).
    public var offered: String? {
        let name = theirs
        return !name.isEmpty && !EntityText.same(name, value.jsTrimmed()) ? name : nil
    }

    /// The line under the field about the offered name. The view announces it whenever it
    /// changes to a new non-nil value (RN's `useEffect` on `notice`, NameItInline.tsx:104-106);
    /// only errors, which must be said again when the same one is set again, go through the
    /// model's `announce`.
    public var notice: String? {
        guard let offered else { return nil }
        return meanwhile != nil
            ? L10n.Item.NameIt.namedMeanwhile(name: offered)
            : L10n.Item.NameIt.justNamed(name: offered)
    }

    /// The field is in use (focused, or holding typed text), so the screen keeps it even once
    /// the item has a name; no longer once it is named (RN `engage`).
    public var engaged: Bool {
        !named && (focused || EntityText.hasText(value))
    }

    /// "Use “X”" is offered while not saving.
    public var canUseOffered: Bool { offered != nil && !saving }

    /// The field's spoken label, with the error when there is one.
    public var accessibilityLabel: String {
        guard let error else { return L10n.Item.NameIt.a11y }
        return "\(L10n.Item.NameIt.a11y), \(L10n.Forms.errorA11y(error: error))"
    }

    /// "Save name" or Return: true once the name is saved; false when it was not (``error``
    /// says why) or while another save runs.
    @discardableResult
    public func save() async -> Bool {
        let name = value.jsTrimmed()
        if name.isEmpty {
            showError(L10n.Forms.itemNameRequired)
            return false
        }
        if savingGuard { return false }
        savingGuard = true
        saving = true
        error = nil

        // After a save ran into another name, saving again is the choice to keep this one, so
        // it goes over that name's stamp.
        let lock = max(meanwhile?.updatedAt ?? 0, itemUpdatedAt)
        let outcome = await ItemDetails.attemptName(items, id: itemId, updatedAt: lock, name: name)
        savingGuard = false
        saving = false

        switch outcome {
        case .named:
            telemetry.event("item_updated")
            finish(name)
            invalidator.invalidate()
            return true
        case .namedMeanwhile(let theirName, let updatedAt):
            // The typed name and the keyboard stay; the notice offers theirs.
            haptics(.warning)
            meanwhile = Meanwhile(name: theirName, updatedAt: updatedAt)
            invalidator.invalidate()
        case .gone:
            // The screen re-reads, finds nothing and says the item is gone.
            invalidator.invalidate()
        case .failed(let cause):
            let kind = describeError(cause, context: .save, subject: .item).kind
            telemetry.error("item_name_failed", ["errorClass": .string(kind.rawValue)])
            haptics(.error)
            showError(kind == .offline ? L10n.Item.NameIt.failedOffline : L10n.Item.NameIt.failed)
        }
        return false
    }

    /// "Use “X”": the offered name is already stored; nothing to write.
    public func useOffered() {
        guard let offered, !saving else { return }
        finish(offered)
    }

    /// "File it…" with a name typed but not saved saves it first (RN `commit`): true once there
    /// is nothing left to save, false when saving it did not happen.
    public func commit() async -> Bool {
        let typed = value.jsTrimmed()
        if typed.isEmpty { return true }
        if EntityText.same(typed, theirs) {
            finish(typed)
            return true
        }
        return await save()
    }

    private func finish(_ name: String) {
        named = true
        onNamed(name)
    }

    /// Announced as it is set, so the same message set again is said again.
    private func showError(_ message: String) {
        error = message
        announce(message)
    }
}
