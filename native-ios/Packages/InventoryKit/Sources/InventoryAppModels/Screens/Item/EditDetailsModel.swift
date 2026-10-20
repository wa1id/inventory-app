import InventoryCore
import InventoryStrings
import Observation

// RN: app/item/[id]/edit.tsx. The Edit details sheet's logic: the read, seeding the form once
// per item, the dirty-form guard, validation, the save with its optimistic lock and what each
// outcome does. The SwiftUI side is `ItemEditSheet`.

/// Edit details: name, category, tags and notes, all on screen at once (RN `EditItemScreen`,
/// 07 §3.4).
///
/// Quantity is not here (the stepper saves it), nor the place (that is Move). The form is seeded
/// once per item from its first read, so a background re-read never overwrites typing, and it
/// saves with the lock it was seeded with: a change made on another phone meanwhile is reported
/// (``notice``) and folded into the form rather than silently overwritten. ``dirtyGuard`` asks
/// before a form with real changes closes.
@MainActor
@Observable
public final class EditDetailsModel {
    /// Why the last save did not happen (RN `Problem`).
    public enum Problem {
        /// Someone changed these details meanwhile; their version is filled in.
        case conflict
        case failed(any Error)
    }

    /// What the form was filled from, and the version the save goes over: the item as first
    /// read, or theirs after a conflict (RN `seed`).
    public struct Seed: Sendable, Hashable {
        public var id: String
        public var values: ItemFormValues
        public var base: ItemDetailsBase
    }

    /// The banner above the fields.
    public struct Notice: Sendable, Hashable {
        public var title: String?
        public var message: String
    }

    /// What the sheet shows (RN lines 233-258).
    public enum Phase {
        case loading
        /// The read failed: Try again.
        case failed(any Error)
        /// Deleted, before the sheet opened or during a save: Close.
        case gone
        case form(ItemWithContext)
    }

    /// Where the sheet goes (the screen maps it to the router).
    public struct Routing {
        /// Whether the sheet is still the screen in front (RN `navigation.isFocused()`).
        public var isFocused: @MainActor () -> Bool
        /// Closes the sheet (`router.close(address)`).
        public var close: @MainActor () -> Void

        public init(isFocused: @escaping @MainActor () -> Bool, close: @escaping @MainActor () -> Void) {
            self.isFocused = isFocused
            self.close = close
        }

        /// Leads nowhere (previews).
        public static var none: Routing { Routing(isFocused: { false }, close: {}) }
    }

    /// The categories remembered on this phone (`app.categories`).
    public struct Categories {
        /// Up to six suggestions for what the Category field holds.
        public var suggest: @MainActor (_ prefix: String) -> [String]
        /// After a save with a category, it becomes the first suggestion.
        public var record: @MainActor (_ category: String?) -> Void

        public init(
            suggest: @escaping @MainActor (_ prefix: String) -> [String],
            record: @escaping @MainActor (_ category: String?) -> Void
        ) {
            self.suggest = suggest
            self.record = record
        }

        /// No memory (previews, tests that do not care).
        public static var none: Categories { Categories(suggest: { _ in [] }, record: { _ in }) }
    }

    public let id: String
    /// `items.getById(id)`, key `item:<id>`.
    public let query: InventoryQuery<ItemWithContext?>
    /// What the fields hold. Typing a name clears its error.
    public var values = ItemFormValues.empty {
        didSet {
            if values.name != oldValue.name, nameError != nil { nameError = nil }
            syncGuard()
        }
    }
    public private(set) var seed: Seed? {
        didSet { syncGuard() }
    }
    /// "Give it a name." under the name field.
    public private(set) var nameError: String?
    public private(set) var problem: Problem?
    /// The save found the item deleted.
    public private(set) var gone = false {
        didSet { syncGuard() }
    }
    /// A save is writing; it stays true after a successful one while the sheet closes.
    public private(set) var saving = false {
        didSet { syncGuard() }
    }
    /// Asks "Discard your changes?" before a form with real changes closes.
    public let dirtyGuard: DirtyGuard
    /// Bumped when the name field should take focus (an invalid name).
    public private(set) var nameFocusRequests = 0
    /// A save went through; the sheet is closing (or may close at once).
    public private(set) var saved = false

    @ObservationIgnored private let items: any ItemsRepository
    @ObservationIgnored private let invalidator: any InventoryInvalidating
    @ObservationIgnored private let toasts: any ToastPresenting
    @ObservationIgnored private let haptics: HapticPlayer
    @ObservationIgnored private let telemetry: TelemetryReporter
    @ObservationIgnored private let categories: Categories
    @ObservationIgnored private let routing: Routing
    /// The single-flight guard (RN `savingRef`).
    @ObservationIgnored private var savingGuard = false
    /// The running save (for tests).
    @ObservationIgnored var saveTask: Task<Void, Never>?

    /// - Parameters:
    ///   - items: the items repository in use at each call (`app.repositories.items`).
    ///   - revision: the database revision now.
    ///   - confirm: asks the discard question.
    public init(
        id: String,
        items: any ItemsRepository,
        revision: Int = 0,
        invalidator: any InventoryInvalidating,
        toasts: any ToastPresenting,
        confirm: any ConfirmPresenting,
        haptics: @escaping HapticPlayer,
        telemetry: TelemetryReporter = .shared,
        categories: Categories = .none,
        routing: Routing
    ) {
        self.id = id
        self.items = items
        self.invalidator = invalidator
        self.toasts = toasts
        self.haptics = haptics
        self.telemetry = telemetry
        self.categories = categories
        self.routing = routing
        dirtyGuard = DirtyGuard(confirm: confirm)
        query = InventoryQuery(key: "item:\(id)", revision: revision) { try await items.getById(id) }
        query.onSettle = { [weak self] in self?.settled() }
    }

    // MARK: Driving

    public func focusChanged(_ focused: Bool, revision: Int? = nil) {
        query.focusChanged(focused, revision: revision)
    }

    public func revisionChanged(_ revision: Int) {
        query.revisionChanged(revision)
    }

    /// Try again.
    public func retry() {
        query.reload()
    }

    // MARK: Outputs

    /// The item as last read; nil while loading or once it is gone.
    public var stored: ItemWithContext? { query.data ?? nil }

    public var phase: Phase {
        if !gone, let stored { return .form(stored) }
        if !gone, let cause = query.cause { return .failed(cause) }
        if !gone, query.isLoading { return .loading }
        return .gone
    }

    /// The form holds a real change (RN `detailsDirty`; re-spacing is not one).
    public var isDirty: Bool {
        guard let seed else { return false }
        return ItemDetails.isDirty(values, seed: seed.values)
    }

    /// An item still without a name (a Quick Snap photo) may stay that way: the name is not
    /// required (RN `nameOptional`).
    public var nameIsOptional: Bool { seed?.values.name == "" }

    /// The read-only thumbnail beside the name: the thumbnail, else the full photo.
    public var photoUri: String? { stored.flatMap { $0.photoThumbUri ?? $0.photoUri } }

    /// The recent categories for what Category holds (shown while it is focused).
    public var categorySuggestions: [String] { categories.suggest(values.category) }

    /// The banner above the fields, assertive: a conflict, or a save that failed (RN `ProblemBanner`).
    public var notice: Notice? {
        switch problem {
        case nil:
            return nil
        case .conflict:
            return Notice(title: nil, message: L10n.EditItem.conflict)
        case .failed(let cause):
            let described = describeError(cause, context: .save, subject: .item)
            return described.kind == .offline
                ? Notice(title: described.title, message: described.body)
                : Notice(title: nil, message: L10n.EditItem.notSaved)
        }
    }

    // MARK: Actions

    /// The sheet's Cancel: refused while a save writes (RN disables it), else asks when dirty.
    /// Once a save went through there is nothing to lose: the sheet closes, even if it was not in
    /// front when the save finished (RN left it open then, `saving`, with Cancel disabled for
    /// good; a link or Quick Snap opened mid-save would leave it stuck).
    public func attemptClose() async -> Bool {
        if saved { return true }
        if saving { return false }
        return await dirtyGuard.attemptClose()
    }

    /// The removed-phone layer is up (nothing to keep editing, so closing is never asked about).
    public func setRevoked(_ revoked: Bool) {
        dirtyGuard.revoked = revoked
    }

    /// Starts ``save()`` from the button.
    public func startSave() {
        saveTask = Task { await save() }
    }

    /// "Save changes" (RN `save`).
    public func save() async {
        guard let stored, let seed, !savingGuard else { return }
        let unnamed = ItemDetails.keepsUnnamed(storedName: seed.values.name, typedName: values.name)
        // Validation needs some name: an item that stays unnamed is checked with a stand-in, and
        // the name is left out of the write (the repository refuses an explicitly blank one).
        var checked = values
        checked.name = unnamed ? L10n.Entities.unnamedItem : values.name
        checked.quantity = String(stored.quantity)
        let (errors, parsed) = ItemForm.validate(checked)
        guard let parsed else {
            nameError = errors.name != nil ? L10n.Forms.itemNameRequired : nil
            nameFocusRequests += 1
            return
        }

        savingGuard = true
        saving = true
        problem = nil
        nameError = nil
        let outcome = await ItemDetails.attemptDetails(
            items,
            id: id,
            patch: ItemDetailsPatch(name: unnamed ? nil : parsed.name, category: parsed.category, tags: parsed.tags, notes: parsed.notes),
            base: seed.base
        )

        if case .saved = outcome {
            // Still "saving" while the sheet closes, so the guard lets it go and a second tap
            // cannot save again.
            saved = true
            telemetry.event("item_updated")
            categories.record(parsed.category)
            // Only from the front: closed some other way mid-save (the removed-phone layer),
            // closing again would act on another screen.
            if routing.isFocused() { routing.close() }
            invalidator.invalidate()
            toasts.show(ToastOptions(message: L10n.EditItem.saved))
            return
        }

        savingGuard = false
        saving = false
        switch outcome {
        case .saved:
            break
        case .gone:
            // Deleted on another phone meanwhile: nothing to save into.
            haptics(.error)
            gone = true
        case .conflict(let theirs):
            // Keep what was typed, fill in their change to every other field, save over their
            // version next time, and say so.
            values = ItemDetails.rebase(values, seed: seed.values, theirs: theirs.values)
            self.seed?.values = theirs.values
            self.seed?.base = theirs
            haptics(.warning)
            problem = .conflict
        case .failed(let cause):
            telemetry.error("item_update_failed", ["errorClass": .string(describeError(cause, context: .save).kind.rawValue)])
            haptics(.error)
            problem = .failed(cause)
        }
    }

    // MARK: Reads

    /// Seeds the form once per item id, from its first read (RN lines 136-144).
    private func settled() {
        guard let stored, seed.map({ !EntityText.same($0.id, stored.id) }) ?? true else { return }
        let seeded = ItemDetails.seed(stored)
        seed = Seed(id: stored.id, values: seeded, base: ItemDetailsBase(updatedAt: stored.updatedAt, values: seeded))
        values = seeded
    }

    private func syncGuard() {
        let dirty = isDirty && !gone
        if dirtyGuard.dirty != dirty { dirtyGuard.dirty = dirty }
        if dirtyGuard.saving != saving { dirtyGuard.saving = saving }
    }
}
