import InventoryCore
import InventoryServices
import InventoryStrings
import Observation

// RN: app/item/[id]/index.tsx. The item screen's logic: its two reads, the name given here
// shown before the re-read brings it back, the inline naming field, the write-through quantity,
// Move or File with the filing run, and Delete. The SwiftUI side is `ItemDetailScreen`.

/// One item: where it is first, then the small edits (RN `ItemScreen`, 07 §3.2).
///
/// **Reads.** ``itemQuery`` (`items.getById`, key `item:<id>`) and, only in a filing run,
/// ``dropZoneQuery`` (`items.listUnsorted()`, key `drop-zone`) for "3 waiting" and the run's next
/// item. Drive both with ``focusChanged(_:revision:)`` and ``revisionChanged(_:)``.
///
/// **Naming.** An item with no name shows ``nameField`` ("What is it?") in place of its title.
/// The field stays while it is in use (focused or holding text), even once a name arrives
/// (``isNaming``). A name given here shows at once (``namedHere``) until the re-read brings it.
///
/// **Move or File** (``moveOrFile()``) commits a typed name first, opens the Move sheet for a
/// result and, in a filing run, goes on to the next waiting item (`MoveFlow.nextInRun`) or back
/// once everything is filed. **Delete** (``delete()``) confirms, deletes, goes back before the
/// refresh (so the screen is never re-read into "gone") and says what happened in a toast. Both
/// sit behind one busy guard.
@MainActor
@Observable
public final class ItemDetailModel {
    /// Where the screen's actions lead (the screen maps them to the router).
    public struct Routing {
        /// Opens Move or File for a result and waits: the move, or nil when the sheet closed
        /// without one (`router.presentForResult(MoveResult.self) { .sheet(.move(itemId:filing:request:)) }`).
        /// `filing` marks a step of a filing run.
        public var openMove: @MainActor (_ filing: Bool) async -> MoveResult?
        /// Edit details (`router.present(.itemEdit(id:))`).
        public var openEdit: @MainActor () -> Void
        /// The photo, full screen (`router.present(.photo(itemId:))`).
        public var openPhoto: @MainActor () -> Void
        /// Whether this screen is still the one in front (RN `navigation.isFocused()`).
        public var isFocused: @MainActor () -> Bool
        /// Replaces this screen with the run's next item (`router.replace(address, with: .item(id:filing: true))`).
        public var openNext: @MainActor (_ itemId: String) -> Void
        /// Back to where the screen was opened from (`router.close(address)`; RN `router.back()`).
        public var close: @MainActor () -> Void

        public init(
            openMove: @escaping @MainActor (_ filing: Bool) async -> MoveResult?,
            openEdit: @escaping @MainActor () -> Void,
            openPhoto: @escaping @MainActor () -> Void,
            isFocused: @escaping @MainActor () -> Bool,
            openNext: @escaping @MainActor (_ itemId: String) -> Void,
            close: @escaping @MainActor () -> Void
        ) {
            self.openMove = openMove
            self.openEdit = openEdit
            self.openPhoto = openPhoto
            self.isFocused = isFocused
            self.openNext = openNext
            self.close = close
        }

        /// Leads nowhere (previews).
        public static var none: Routing {
            Routing(openMove: { _ in nil }, openEdit: {}, openPhoto: {}, isFocused: { false }, openNext: { _ in }, close: {})
        }
    }

    /// A name given on this screen, over the stamp the item had when it was given (RN `namedHere`).
    public struct NamedHere: Sendable, Hashable {
        public var id: String
        public var name: String
        public var over: Int64
    }

    /// Where VoiceOver goes once the item is named: on to filing it, or to its details.
    public enum FocusTarget: Sendable, Hashable {
        case fileIt
        case editDetails
    }

    /// A focus move for the view to make; `serial` tells one request from the next.
    public struct FocusRequest: Sendable, Hashable {
        public var target: FocusTarget
        public var serial: Int
    }

    /// What the screen shows (RN lines 275-301).
    public enum Phase {
        /// The read has not answered yet: the skeleton.
        case loading
        /// The read failed with nothing to show: Try again.
        case failed(any Error)
        /// The read answered nothing: deleted, probably on another phone.
        case gone
        /// The item, with the name given here if the re-read has not brought it yet.
        case loaded(ItemWithContext)
    }

    public let id: String
    /// A filing run from the Drop zone (RN `filing=1`).
    public let filing: Bool
    /// `items.getById(id)`, key `item:<id>`.
    public let itemQuery: InventoryQuery<ItemWithContext?>
    /// `items.listUnsorted()`, key `drop-zone`; only in a filing run.
    public let dropZoneQuery: InventoryQuery<[ItemWithContext]>?
    public private(set) var namedHere: NamedHere?
    /// "What is it?": made with the first read, and anew once a name was given.
    public private(set) var nameField: NameItModel?
    /// The large stepper's write-through quantity, made with the first read.
    public private(set) var quantity: SavedQuantityModel?
    /// The delete is writing (the button's spinner).
    public private(set) var deleting = false
    /// The latest focus move asked for (after naming).
    public private(set) var focusRequest: FocusRequest?

    @ObservationIgnored private let items: any ItemsRepository
    @ObservationIgnored private let photos: any PhotoStoring
    @ObservationIgnored private let invalidator: any InventoryInvalidating
    @ObservationIgnored private let toasts: any ToastPresenting
    @ObservationIgnored private let confirmPresenter: any ConfirmPresenting
    @ObservationIgnored private let haptics: HapticPlayer
    @ObservationIgnored private let telemetry: TelemetryReporter
    @ObservationIgnored private let isPaired: @MainActor () -> Bool
    @ObservationIgnored private let announce: @MainActor (String) -> Void
    @ObservationIgnored private let routing: Routing
    /// The one busy guard for Move/File and Delete (RN `busyRef`).
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var focusSerial = 0
    /// The running Move/File or Delete (for tests).
    @ObservationIgnored var actionTask: Task<Void, Never>?

    /// - Parameters:
    ///   - items: the items repository in use at each call (`app.repositories.items`).
    ///   - photos: deletes the photo files a delete orphaned (`app.imageStore`).
    ///   - revision: the database revision now.
    ///   - isPaired: joined to a household (the delete confirmation says "on every phone").
    ///   - announce: posts a VoiceOver announcement (the name field's errors).
    public init(
        id: String,
        filing: Bool,
        items: any ItemsRepository,
        photos: any PhotoStoring,
        revision: Int = 0,
        invalidator: any InventoryInvalidating,
        toasts: any ToastPresenting,
        confirm: any ConfirmPresenting,
        haptics: @escaping HapticPlayer,
        telemetry: TelemetryReporter = .shared,
        isPaired: @escaping @MainActor () -> Bool,
        announce: @escaping @MainActor (String) -> Void = { _ in },
        routing: Routing
    ) {
        self.id = id
        self.filing = filing
        self.items = items
        self.photos = photos
        self.invalidator = invalidator
        self.toasts = toasts
        confirmPresenter = confirm
        self.haptics = haptics
        self.telemetry = telemetry
        self.isPaired = isPaired
        self.announce = announce
        self.routing = routing
        itemQuery = InventoryQuery(key: "item:\(id)", revision: revision) { try await items.getById(id) }
        // Only a filing run reads the drop zone: for "3 waiting" and the next item.
        dropZoneQuery = filing ? InventoryQuery(key: "drop-zone", revision: revision) { try await items.listUnsorted() } : nil
        itemQuery.onSettle = { [weak self] in self?.itemSettled() }
    }

    // MARK: Driving

    /// The screen gained or lost focus (both reads).
    public func focusChanged(_ focused: Bool, revision: Int? = nil) {
        itemQuery.focusChanged(focused, revision: revision)
        dropZoneQuery?.focusChanged(focused, revision: revision)
    }

    /// The database revision changed (both reads).
    public func revisionChanged(_ revision: Int) {
        itemQuery.revisionChanged(revision)
        dropZoneQuery?.revisionChanged(revision)
    }

    /// Try again.
    public func retry() {
        itemQuery.reload()
    }

    // MARK: Outputs

    /// The item as last read; nil while loading or once it is gone.
    public var stored: ItemWithContext? { itemQuery.data ?? nil }

    /// The name shown: the one given here while the re-read has not brought it (over no name, or
    /// over the name it had when it was given), else the stored one (RN `ownName ?? stored.name`).
    public var name: String {
        if let namedHere, EntityText.same(namedHere.id, id), stored.map({ $0.name.isEmpty || $0.updatedAt == namedHere.over }) ?? true {
            return namedHere.name
        }
        return stored?.name ?? ""
    }

    /// The stored item with the name shown.
    public var item: ItemWithContext? {
        guard var item = stored else { return nil }
        item.item.name = name
        return item
    }

    public var phase: Phase {
        if let item { return .loaded(item) }
        if let cause = itemQuery.cause { return .failed(cause) }
        if itemQuery.isLoading { return .loading }
        return .gone
    }

    /// The navigation title: the name, or "Needs a name" while it has none (RN's collapsed title).
    public var title: String {
        guard stored != nil else { return "" }
        let name = name
        return name.isEmpty ? L10n.Entities.unnamedItem : name
    }

    /// It waits in the drop zone: "File it…" instead of "Move…".
    public var inDropZone: Bool {
        stored.map { EntityText.same($0.containerId, DropZone.containerId) } ?? false
    }

    /// The drop zone's ids as last read, in its order; empty outside a filing run.
    public var waitingIds: [String] {
        (dropZoneQuery?.data ?? []).map(\.id)
    }

    /// "3 waiting" / "Last one waiting" in a filing run, this item included, while it still waits
    /// (RN `progress`).
    public var progress: String? {
        let waiting = waitingIds
        guard filing, waiting.contains(where: { EntityText.same($0, id) }) else { return nil }
        return L10n.Item.progress(waiting: waiting.count)
    }

    /// "What is it?" shows in place of the title: no name yet, or the field is in use (RN `naming`).
    public var isNaming: Bool {
        name.isEmpty || (nameField?.engaged ?? false)
    }

    /// The failed refresh banner, with the data still on screen (RN `needsRefreshBanner`).
    public var showsRefreshBanner: Bool {
        needsRefreshBanner(itemQuery.refreshFailed, cause: itemQuery.cause)
    }

    /// The full photo (the viewer's) or, failing that, the thumbnail: the thumbnail opens it.
    public var photoUri: String? { stored.flatMap { $0.photoUri ?? $0.photoThumbUri } }

    /// What the 88 pt thumbnail draws.
    public var thumbUri: String? { stored.flatMap { $0.photoThumbUri ?? $0.photoUri } }

    /// "Photo of Cordless drill. Opens it full screen."
    public var photoAccessibilityLabel: String {
        let name = name
        return name.isEmpty ? L10n.Item.photoA11yUnnamed : L10n.Item.photoA11y(name: name)
    }

    /// The category under the title, when it has one.
    public var category: String? {
        guard let category = stored?.category, !category.isEmpty else { return nil }
        return category
    }

    /// The facts card shows: tags or notes (the category is read with the name).
    public var hasFacts: Bool {
        guard let stored else { return false }
        return !stored.tags.isEmpty || !(stored.notes ?? "").isEmpty
    }

    /// "Edit details of “Cordless drill”", or nil to read the label.
    public var editAccessibilityLabel: String? {
        let name = name
        return name.isEmpty ? nil : L10n.Item.editDetailsA11y(name: name)
    }

    /// "Delete “Cordless drill”…", or nil to read the label.
    public var deleteAccessibilityLabel: String? {
        let name = name
        return name.isEmpty ? nil : L10n.Item.deleteA11y(name: name)
    }

    /// "Added 2 September 2026. Last changed 3 days ago."
    public func stamp(now: Int64) -> String {
        guard let stored else { return "" }
        return ItemDetails.stamp(createdAt: stored.createdAt, updatedAt: stored.updatedAt, now: now)
    }

    // MARK: Actions

    /// Edit details.
    public func openEdit() {
        routing.openEdit()
    }

    /// The photo, full screen; nothing without one.
    public func openPhoto() {
        guard photoUri != nil else { return }
        routing.openPhoto()
    }

    /// "Move…" or "File it…" (RN `moveOrFile`).
    public func moveOrFile() async {
        guard stored != nil, !busy else { return }
        busy = true
        defer { busy = false }
        // Filing this item is a step of the run; moving one already filed (by another phone,
        // say) is not, and does not advance it.
        let runStep = filing && inDropZone
        // The drop zone as it was before this move keeps the run in its order.
        let before = waitingIds
        // A name typed but not saved goes with it; if saving fails, the field says why and
        // nothing moves.
        if isNaming, let nameField, !(await nameField.commit()) { return }
        // Outside a run nothing more happens: the screen re-reads on focus, and the move sheet
        // has said where the item went.
        guard let result = await routing.openMove(runStep), runStep else { return }
        // The sheet's own read after the move, the one its toast was worded from; read again
        // only if that failed.
        var waiting = result.waiting
        if waiting == nil {
            do {
                waiting = try await items.listUnsorted().map(\.id)
            } catch {
                waiting = before.filter { !EntityText.same($0, id) }
            }
        }
        // Left for another screen while the list was read: the run is over, and replacing or
        // going back now would act on that screen.
        guard routing.isFocused() else { return }
        if let next = MoveFlow.nextInRun(before: before, currentId: id, waiting: waiting ?? []) {
            routing.openNext(next)
        } else {
            routing.close()
        }
    }

    /// "Delete item…" (RN `deleteItem`).
    public func delete() async {
        guard stored != nil, !busy else { return }
        busy = true
        defer { busy = false }
        let name = name
        let sure = await confirmPresenter.confirm(
            ConfirmOptions(
                title: name.isEmpty ? L10n.Item.deleteTitleUnnamed : L10n.Item.deleteTitle(name: name),
                body: isPaired() ? L10n.Item.deleteBodyPaired : L10n.Item.deleteBodyLocal,
                confirmLabel: L10n.Common.delete
            )
        )
        guard sure else { return }
        deleting = true
        do {
            let result = try await items.delete(id)
            // Nothing deleted means another phone deleted it first (a household answers a 404
            // that way): gone either way, but this phone did not do it.
            let message: String
            if result.deleted {
                photos.deleteStoredPhotos(result.orphanedPhotoUris.map { Optional($0) })
                telemetry.event("item_deleted")
                message = name.isEmpty ? L10n.Item.deletedUnnamed : L10n.Item.deleted(name: name)
            } else {
                message = name.isEmpty ? L10n.Item.alreadyDeletedUnnamed : L10n.Item.alreadyDeleted(name: name)
            }
            // Back first, so the screen is not re-read into "This item is gone" on the way out;
            // not if it was left already while deleting (back would pop the screen in front).
            if routing.isFocused() { routing.close() }
            invalidator.invalidate()
            toasts.show(ToastOptions(message: message))
        } catch {
            deleting = false
            let kind = describeError(error, context: .delete, subject: .item).kind
            telemetry.error("item_delete_failed", ["errorClass": .string(kind.rawValue)])
            haptics(.error)
            toasts.show(ToastOptions(message: L10n.Item.deleteFailed(offline: kind == .offline), tone: .error))
        }
    }

    /// Starts ``moveOrFile()`` from a button.
    public func startMoveOrFile() {
        actionTask = Task { await moveOrFile() }
    }

    /// Starts ``delete()`` from a button.
    public func startDelete() {
        actionTask = Task { await delete() }
    }

    // MARK: Reads

    /// Keeps the name field and the stepper in step with each read.
    private func itemSettled() {
        guard let stored else { return }
        if let nameField {
            nameField.itemUpdatedAt = stored.updatedAt
            nameField.incomingName = stored.name
        } else {
            nameField = makeNameField(for: stored)
        }
        if let quantity {
            quantity.itemDidChange(quantity: stored.quantity, updatedAt: stored.updatedAt)
        } else {
            quantity = SavedQuantityModel(
                itemId: id,
                quantity: stored.quantity,
                updatedAt: stored.updatedAt,
                items: items,
                invalidator: invalidator,
                haptics: haptics,
                telemetry: telemetry
            )
        }
    }

    private func makeNameField(for stored: ItemWithContext) -> NameItModel {
        NameItModel(
            itemId: id,
            updatedAt: stored.updatedAt,
            incomingName: stored.name,
            items: items,
            invalidator: invalidator,
            haptics: haptics,
            telemetry: telemetry,
            announce: announce,
            onNamed: { [weak self] name in self?.named(name) }
        )
    }

    /// The field gave the item a name: show it at once, move focus on (to filing it, or to its
    /// details) and start a fresh field for any later naming (RN `onNamed`).
    private func named(_ given: String) {
        guard let stored else { return }
        namedHere = NamedHere(id: id, name: given, over: stored.updatedAt)
        focusSerial += 1
        focusRequest = FocusRequest(target: inDropZone ? .fileIt : .editDetails, serial: focusSerial)
        nameField = makeNameField(for: stored)
    }
}
