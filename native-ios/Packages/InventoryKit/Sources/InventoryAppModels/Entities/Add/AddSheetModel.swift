import Foundation
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage
import InventoryStrings
import Observation

/// The Add sheet: add an item fast, a name is enough (RN `app/item/new.tsx`; 06 §10, 07 §3.1).
///
/// The place defaults to the drop zone; the container the sheet was opened for and the last few
/// places are one tap each, and the place step offers the full picker. A photo is optional:
/// recognition runs in the background, only fills blanks, and never blocks saving or takes
/// typing back. Nothing typed is lost to a stray swipe: every change is kept in the
/// ``AddDraftStore`` (which owns the photo until the item is saved), and the next plain open
/// within half an hour restores it.
///
/// The view binds the fields to ``name``, ``category``, ``tags`` and ``notes`` (each a user
/// edit) and the stepper to ``quantity``/``setQuantity(_:)``. It calls ``start()`` once when
/// the sheet appears, ``loadPlaces()`` on appear and whenever the inventory revision changes,
/// and ``sheetClosed()`` when the sheet is dismissed (not when the place step is pushed). It
/// focuses the name field when ``nameFocusRequest`` changes and scrolls to the top when
/// ``scrollToTopRequest`` changes. Camera and navigation go through ``Routing``.
@MainActor
@Observable
public final class AddSheetModel {
    /// Which button is saving (RN `saving`).
    public enum SaveKind: Sendable, Hashable {
        case save
        case another
    }

    /// What the model asks of the screen around it.
    public struct Routing {
        /// Whether the sheet is still the screen in front (RN `navigation.isFocused()`).
        public var isFocused: @MainActor () -> Bool
        /// Dismisses the sheet.
        public var close: @MainActor () -> Void
        /// Replaces the sheet with the camera for `containerId`: Quick Snap's fast mode
        /// ("Snap several at once…"), or the default single mode with nobody waiting
        /// ("Save and add another" after a photo), whose shot opens a fresh Add sheet.
        public var replaceWithCapture: @MainActor (_ containerId: String, _ fast: Bool) -> Void
        /// Opens the single-mode camera for a photo for this sheet; nil when it closed without one.
        public var takePhoto: @MainActor (_ containerId: String) async -> StoredImage?

        public init(
            isFocused: @escaping @MainActor () -> Bool,
            close: @escaping @MainActor () -> Void,
            replaceWithCapture: @escaping @MainActor (_ containerId: String, _ fast: Bool) -> Void,
            takePhoto: @escaping @MainActor (_ containerId: String) async -> StoredImage?
        ) {
            self.isFocused = isFocused
            self.close = close
            self.replaceWithCapture = replaceWithCapture
            self.takePhoto = takePhoto
        }
    }

    /// Recognises the stored photo at a URI, anchored to a name hint (RN `recognizeItem`).
    /// The app resolves the URI with `PhotoPathResolver` and calls `RecognitionClient`.
    public typealias Recognize = @Sendable (_ photoUri: String, _ nameHint: String?) async -> RecognitionResult

    // MARK: State

    /// What the form holds. User edits go through ``edit(_:)`` (or the field properties).
    public private(set) var values: ItemFormValues { didSet { syncDraft() } }
    /// Where the item goes: a container id, or `DropZone.containerId`.
    public private(set) var placeId: String { didSet { syncDraft() } }
    /// The last container picked in the place step (it may be newer than the places list).
    public private(set) var picked: PlaceOption? { didSet { syncDraft() } }
    public private(set) var photo: AddPhoto? { didSet { syncDraft() } }
    /// The stored suggestion state; never `stale` (see ``suggestionBanner``).
    public private(set) var suggestion: SuggestionState { didSet { syncDraft() } }
    /// "More details" was opened by hand.
    public private(set) var showMore: Bool { didSet { syncDraft() } }
    /// The details as they were when "More details" was closed over them.
    public private(set) var collapsedAt: String?
    /// The form came from a draft: the banner says so and offers to clear it.
    public private(set) var restored: Bool
    /// The place step is showing.
    public var isPickingPlace = false
    public private(set) var saving: SaveKind?
    /// Under the name: "Give the item a name."
    public private(set) var nameError: String?
    /// Why the last save did not happen, while the sheet stayed open.
    public private(set) var problem: SaveNoticeCopy?
    /// "Saved. Add the next one." after "Save and add another" without a photo, until a name is typed.
    public private(set) var savedNext = false
    /// Every container with its space (the `add-places` read); nil until it first loads.
    public private(set) var places: [PlaceOption]?
    /// Why the last places read failed; nil after a good one.
    public private(set) var placesCause: (any Error)?
    public private(set) var placesLoading = false
    /// Bumped when the name field should take focus.
    public private(set) var nameFocusRequest = 0
    /// Bumped when the form should scroll back to the top.
    public private(set) var scrollToTopRequest = 0

    /// This phone's recent places as they were when the sheet opened.
    public let recentIds: [String]
    /// Where the sheet started.
    public let initial: AddInitialState

    // MARK: Dependencies

    @ObservationIgnored private let params: AddParams
    @ObservationIgnored private let spaces: any SpacesRepository
    @ObservationIgnored private let containers: any ContainersRepository
    @ObservationIgnored private let items: any ItemsRepository
    @ObservationIgnored private let drafts: AddDraftStore
    @ObservationIgnored private let photos: any PhotoStoring
    @ObservationIgnored private let recognize: Recognize
    @ObservationIgnored private let recentPlaces: RecentPlacesStore
    @ObservationIgnored private let categories: CategoryMemory
    @ObservationIgnored private let invalidator: any InventoryInvalidating
    @ObservationIgnored private let toasts: any ToastPresenting
    @ObservationIgnored private let confirmPresenter: any ConfirmPresenting
    @ObservationIgnored private let haptics: HapticPlayer
    @ObservationIgnored private let routing: Routing
    @ObservationIgnored private let telemetry: TelemetryReporter
    @ObservationIgnored private let now: @Sendable () -> Int64
    /// The sheet that writes the draft; only it may clear it.
    @ObservationIgnored private let owner: String

    /// The synchronous double-submit guard (RN `savingRef`).
    @ObservationIgnored private var savingGuard = false
    /// The camera is open for this sheet (RN `cameraOpenRef`).
    @ObservationIgnored private var cameraOpen = false
    /// The photo recognition is running for; an answer about another one is dropped (RN `recognitionRef`).
    @ObservationIgnored private var recognitionURI: String?
    /// False once the sheet has gone (dismissed, replaced, saved and closed): nothing is written
    /// to the draft any more and late answers are dropped, as an unmounted RN screen drops them.
    @ObservationIgnored private var active = true
    @ObservationIgnored private var started = false
    /// Counts places reads, so an older answer never overwrites a newer one.
    @ObservationIgnored private var placesGeneration = 0
    /// The recognition and Undo running in the background (for tests).
    @ObservationIgnored var recognitionTask: Task<Void, Never>?
    @ObservationIgnored var undoTask: Task<Void, Never>?

    /// - Parameters:
    ///   - params: how the sheet was opened.
    ///   - drafts: the app's one draft store.
    ///   - photos: deletes photo files nobody keeps.
    ///   - recognize: photo recognition (never throws; failures come back as `.failed`).
    ///   - recentPlaces: read once for the "Where it goes" list; a save remembers its place.
    ///   - categories: a save records its category for the Category chips.
    ///   - now: epoch milliseconds, for the draft's `savedAt` and freshness.
    ///   - owner: this sheet's id in the draft store.
    public init(
        params: AddParams,
        spaces: any SpacesRepository,
        containers: any ContainersRepository,
        items: any ItemsRepository,
        drafts: AddDraftStore,
        photos: any PhotoStoring,
        recognize: @escaping Recognize,
        recentPlaces: RecentPlacesStore,
        categories: CategoryMemory,
        invalidator: any InventoryInvalidating,
        toasts: any ToastPresenting,
        confirm: any ConfirmPresenting,
        haptics: @escaping HapticPlayer,
        routing: Routing,
        telemetry: TelemetryReporter = .shared,
        now: @escaping @Sendable () -> Int64 = { epochMillis() },
        owner: String = UUID().uuidString
    ) {
        self.params = params
        self.spaces = spaces
        self.containers = containers
        self.items = items
        self.drafts = drafts
        self.photos = photos
        self.recognize = recognize
        self.recentPlaces = recentPlaces
        self.categories = categories
        self.invalidator = invalidator
        self.toasts = toasts
        confirmPresenter = confirm
        self.haptics = haptics
        self.routing = routing
        self.telemetry = telemetry
        self.now = now
        self.owner = owner

        let initial = AddSheetRules.initialState(params: params, draft: drafts.restorableDraft(now: now())?.state)
        self.initial = initial
        recentIds = recentPlaces.read()
        values = initial.state.values
        placeId = initial.state.placeId
        picked = initial.state.picked
        photo = initial.state.photo
        suggestion = initial.state.suggestion
        showMore = initial.state.showMore
        restored = initial.restored
    }

    // MARK: Derived

    /// The places by id; nil until the first read lands (later duplicates win, like a JS `Map`).
    public var options: [String: PlaceOption]? {
        places.map { list in
            var byId: [String: PlaceOption] = [:]
            for option in list { byId[option.id] = option }
            return byId
        }
    }

    /// The container the sheet was opened for, once its details are known; never the drop zone.
    public var paramOption: PlaceOption? {
        guard let id = params.containerId, !id.isEmpty, !EntityText.same(id, DropZone.containerId) else { return nil }
        return options?[id]
    }

    /// Where a save goes now.
    public var place: ResolvedPlace {
        AddSheetRules.resolvePlace(selectedId: placeId, options: options, picked: picked)
    }

    /// The "Where it goes" rows. While the places load, or after they failed with nothing
    /// loaded, only the drop zone (and a picked place) show.
    public var entries: [WhereEntry] {
        AddSheetRules.whereEntries(param: paramOption, recentIds: recentIds, options: options ?? [:], selectedId: place.id, picked: picked)
    }

    /// The trimmed name.
    public var typedName: String { values.name.jsTrimmed() }

    /// Whether anything is worth keeping or asking about before closing.
    public var hasContent: Bool { AddSheetRules.formHasContent(values, photo: photo) }

    /// The name the suggested details no longer describe, if any.
    public var staleName: String? { suggestion.staleName(typed: typedName) }

    /// What the suggestion banner shows; nil without a photo (no banner then).
    public var suggestionBanner: SuggestionState? {
        photo == nil ? nil : suggestion.banner(typed: typedName)
    }

    /// The details as one key, to notice a change after "More details" was closed.
    public var detailsKey: String {
        [values.category, values.tags, values.notes].joined(separator: "\u{0}")
    }

    /// "More details" is open: opened by hand, or holding something and not closed over exactly
    /// these values, so details a suggestion changed are never hidden.
    public var detailsShown: Bool {
        showMore || (AddSheetRules.hasDetails(values) && !EntityText.same(detailsKey, collapsedAt))
    }

    /// The form step's title.
    public var title: String { AddSheetRules.title(param: paramOption) }

    /// The place step's title.
    public var placeStepTitle: String { L10n.Add.placeTitle }

    /// The Save button's spoken label.
    public var saveAccessibilityLabel: String { AddSheetRules.saveAccessibilityLabel(place) }

    /// The stepper's value: the typed quantity, or 1.
    public var quantity: Int { parseQuantityInput(values.quantity) ?? 1 }

    /// The name the stepper's labels use, or nil while unnamed.
    public var stepperItemName: String? { typedName.isEmpty ? nil : typedName }

    /// "Your containers could not be loaded": the read failed with nothing loaded.
    public var showsPlacesFailed: Bool { placesCause != nil && places == nil }

    /// While saving, the sheet resists a swipe-down.
    public var interactiveDismissDisabled: Bool { saving != nil }

    /// Photo options (Retake, Remove) are offered only while not saving.
    public var canShowPhotoOptions: Bool { saving == nil }

    /// The name field is focused on arrival only without a photo (the suggestion may name it).
    public var focusesNameOnArrival: Bool { initial.state.photo == nil }

    /// Up to six known categories for what the Category field holds; shown as chips while the
    /// field is focused, never filled in on their own (RN `useCategorySuggestions`).
    public var categorySuggestions: [String] { categories.suggestions(for: values.category) }

    // MARK: Field bindings

    public var name: String {
        get { values.name }
        set { var next = values; next.name = newValue; edit(next) }
    }

    public var category: String {
        get { values.category }
        set { var next = values; next.category = newValue; edit(next) }
    }

    public var tags: String {
        get { values.tags }
        set { var next = values; next.tags = newValue; edit(next) }
    }

    public var notes: String {
        get { values.notes }
        set { var next = values; next.notes = newValue; edit(next) }
    }

    // MARK: Lifecycle

    /// Call once when the sheet appears: drops a stale draft (when nothing was restored),
    /// keeps the current state as the draft, and starts recognition for a photo that arrived
    /// with the sheet or was cut off in a restored draft.
    public func start() {
        guard !started else { return }
        started = true
        if !initial.restored { drafts.discardStaleDraft(now: now()) }
        syncDraft()
        if initial.recognize, let photo = initial.state.photo {
            startRecognition(uri: photo.uri, nameHint: Self.hint(initial.state.values.name.jsTrimmed()))
        }
    }

    /// Reads every container with its space (the `add-places` query). A failed read keeps what
    /// was loaded before; only the newest read's answer counts (RN `useInventoryQuery`). A read
    /// whose task was cancelled (the view's `.task(id:)` restarting it, or the sheet going)
    /// settles nothing, so its cancellation never shows as "could not be loaded".
    public func loadPlaces() async {
        placesGeneration += 1
        let generation = placesGeneration
        placesLoading = true
        let containers = containers
        let spaces = spaces
        let result: Result<[PlaceOption], any Error>
        do {
            async let containerRows = containers.listAllWithSpace()
            async let spaceRows = spaces.listWithCounts()
            result = .success(joinPlaceOptions(try await containerRows, spaces: try await spaceRows))
        } catch {
            result = .failure(error)
        }
        guard generation == placesGeneration, !Task.isCancelled else { return }
        placesLoading = false
        switch result {
        case .success(let loaded):
            places = loaded
            placesCause = nil
        case .failure(let error):
            placesCause = error
        }
    }

    /// Call when the sheet is dismissed (a swipe-down or Back keep the draft).
    public func sheetClosed() {
        leave()
    }

    // MARK: Editing

    /// A user edit of the fields: typing a non-blank name clears the name error and the
    /// "Saved. Add the next one." line.
    public func edit(_ next: ItemFormValues) {
        values = next
        if nameError != nil && EntityText.hasText(next.name) { nameError = nil }
        if savedNext && EntityText.hasText(next.name) { savedNext = false }
    }

    /// The stepper's new count, applied to the latest values so a hold-repeat never undoes a
    /// suggestion that landed meanwhile.
    public func setQuantity(_ next: Int) {
        values.quantity = String(next)
    }

    /// A "Where it goes" row was tapped. The selected row does nothing.
    public func choose(_ entry: WhereEntry) {
        guard !EntityText.same(entry.id, place.id) else { return }
        haptics(.choice)
        placeId = entry.id
    }

    /// "Somewhere else…": shows the place step; ignored while saving.
    public func showPlaceStep() {
        guard !savingGuard else { return }
        isPickingPlace = true
    }

    /// A place picked in the place step; back to the form.
    public func pickPlace(_ chosen: PickedPlace) {
        switch chosen {
        case .dropZone:
            placeId = DropZone.containerId
        case .container(let option):
            placeId = option.id
            picked = option
        }
        isPickingPlace = false
    }

    /// Opens or closes "More details".
    public func toggleDetails() {
        if detailsShown {
            showMore = false
            collapsedAt = detailsKey
        } else {
            showMore = true
        }
    }

    // MARK: Photo and recognition

    /// The camera button: single-mode capture for this sheet, then recognition anchored to the
    /// typed name. Ignored while saving or while the camera is already open.
    public func takePhoto() async {
        guard !savingGuard, !cameraOpen else { return }
        cameraOpen = true
        let taken = await routing.takePhoto(place.id)
        cameraOpen = false
        guard let taken else { return }
        guard active else {
            // The sheet went while the camera was up: nobody will own this photo.
            photos.deleteStoredPhotos([taken.uri, taken.thumbUri])
            return
        }
        let next = AddPhoto(taken)
        photo = next
        suggestion = .running
        startRecognition(uri: next.uri, nameHint: Self.hint(typedName))
    }

    /// Photo options › Retake: the photo goes, then the camera opens. Ignored while saving
    /// (RN `photoOptions`, app/item/new.tsx:407-408): the files may already be the item's.
    public func retakePhoto() async {
        guard !savingGuard else { return }
        dropPhoto()
        await takePhoto()
    }

    /// Photo options › Remove photo. Ignored while saving, as ``retakePhoto()``.
    public func removePhoto() {
        guard !savingGuard else { return }
        dropPhoto()
    }

    /// The banner's "Try suggestions again", anchored to the typed name.
    public func retrySuggestion() {
        guard let photo else { return }
        suggestion = .running
        startRecognition(uri: photo.uri, nameHint: Self.hint(typedName))
    }

    /// The banner's "Update the other details" (stale only): replaces category and tags for
    /// the typed name.
    public func refreshSuggestion() {
        guard let photo, let staleName else { return }
        suggestion = .refreshing
        startRecognition(uri: photo.uri, nameHint: staleName, overwrite: true)
    }

    /// The draft banner's "Clear": the photo goes too; back to an empty form in the drop zone.
    public func clearRestored() {
        guard !savingGuard else { return }
        dropPhoto()
        values = .empty
        placeId = DropZone.containerId
        picked = nil
        showMore = false
        collapsedAt = nil
        restored = false
        nameError = nil
        problem = nil
        nameFocusRequest += 1
    }

    // MARK: Leaving

    /// The header's Cancel: asks before discarding typing or a photo, deletes the photo on
    /// discard, forgets the draft and closes. Ignored while saving.
    public func cancel() async {
        guard !savingGuard else { return }
        if hasContent {
            let discard = await confirmPresenter.confirm(
                ConfirmOptions(
                    title: L10n.Add.discardTitle,
                    body: L10n.Add.discardBody,
                    confirmLabel: L10n.Forms.discard,
                    cancelLabel: L10n.Forms.keepEditing
                )
            )
            guard discard else { return }
            recognitionURI = nil
            photos.deleteStoredPhotos(AddSheetRules.photoFiles(photo))
        }
        drafts.clearDraft(owner: owner)
        leave()
        routing.close()
    }

    /// "Snap several at once…": replaces the sheet with Quick Snap for the current place; the
    /// draft keeps the typing. Ignored while saving.
    public func snapSeveral() {
        guard !savingGuard else { return }
        let containerId = place.id
        leave()
        routing.replaceWithCapture(containerId, true)
    }

    // MARK: Saving

    /// Saves the item (RN `save(andAnother)`, 06 §10.4).
    ///
    /// Item, photo and tags are written in one call. A failure keeps everything and says why
    /// (a banner while the sheet is open, else an error toast). After a save: "another" without
    /// a photo empties the form for the next one in the same place; "another" with a photo
    /// replaces the sheet with the camera; otherwise the sheet closes and a toast says where it
    /// went, with Undo.
    public func save(andAnother: Bool) async {
        guard !savingGuard else { return }
        let (errors, parsed) = ItemForm.validate(values)
        guard let parsed else {
            // An invalid quantity alone has no UI: the stepper always writes whole numbers.
            if errors.name != nil {
                nameError = L10n.Add.nameRequired
                nameFocusRequest += 1
            }
            return
        }

        let target = place
        let addedPhoto = photo
        let suggestionAtSave = suggestion
        savingGuard = true
        saving = andAnother ? .another : .save
        problem = nil
        savedNext = false

        let item: Item
        do {
            item = try await items.create(
                ItemDraft(
                    containerId: target.id,
                    name: parsed.name,
                    category: parsed.category,
                    quantity: parsed.quantity,
                    notes: parsed.notes,
                    tags: parsed.tags,
                    photo: addedPhoto?.input
                )
            )
        } catch {
            let described = describeError(error, context: .save, subject: .container)
            telemetry.error("item_create_failed", ["errorClass": .string(described.kind.rawValue)])
            haptics(.error)
            savingGuard = false
            saving = nil
            // A 404 here means the container went, not the item.
            if routing.isFocused() {
                problem = SaveNoticeCopy(cause: error, subject: .container)
            } else {
                toasts.show(ToastOptions(message: described.body, tone: .error))
            }
            return
        }

        // Only the write is guarded above: nothing below may report "not saved".
        let accepted: Bool
        let hinted: Bool
        switch suggestionAtSave {
        case .applied: (accepted, hinted) = (true, false)
        case .refreshed: (accepted, hinted) = (true, true)
        default: (accepted, hinted) = (false, false)
        }
        telemetry.event(
            "item_created",
            ["hasPhoto": .bool(addedPhoto != nil), "suggestionAccepted": .bool(accepted), "hinted": .bool(hinted)]
        )
        // The item owns the photo now.
        drafts.clearDraft(owner: owner)
        invalidator.invalidate()
        haptics(.success)
        recentPlaces.remember(target.id)
        categories.record(parsed.category)

        let here = routing.isFocused()
        if andAnother && addedPhoto == nil && here {
            savingGuard = false
            saving = nil
            startNext()
            savedNext = true
            return
        }
        if andAnother && addedPhoto != nil && here {
            // The guard stays set: the sheet is leaving.
            leave()
            routing.replaceWithCapture(target.id, false)
            return
        }

        leave()
        if here { routing.close() }
        let itemId = item.id
        toasts.show(
            ToastOptions(
                message: AddSheetRules.savedMessage(target),
                action: ToastAction(
                    label: L10n.Common.undo,
                    accessibilityLabel: L10n.Add.undoA11y(name: parsed.name),
                    handler: { [self] in undoTask = Task { await undoAdd(itemId: itemId, addedPhoto: addedPhoto) } }
                )
            )
        )
    }

    /// Undo from the toast: the item goes again, and so do its photo files (RN `undoAdd`).
    func undoAdd(itemId: String, addedPhoto: AddPhoto?) async {
        do {
            let result = try await items.delete(itemId)
            // Paired, the household reports its own copies; the files this phone took go too.
            photos.deleteStoredPhotos(result.orphanedPhotoUris.map(Optional.some) + AddSheetRules.photoFiles(addedPhoto))
            telemetry.event("item_deleted")
            invalidator.invalidate()
            haptics(.undo)
            toasts.show(ToastOptions(message: L10n.Add.removedAgain))
        } catch {
            let kind = describeError(error, context: .delete, subject: .item).kind
            telemetry.error("item_delete_failed", ["errorClass": .string(kind.rawValue)])
            haptics(.error)
            toasts.show(ToastOptions(message: L10n.Add.undoFailed(offline: kind == .offline), tone: .error))
        }
    }

    // MARK: Private

    /// After "Save and add another" without a photo: same place, empty form, name focused.
    private func startNext() {
        values = .empty
        suggestion = .idle
        showMore = false
        collapsedAt = nil
        restored = false
        scrollToTopRequest += 1
        nameFocusRequest += 1
    }

    /// Deletes the photo's files (both) and forgets it; a pending answer about it is dropped.
    private func dropPhoto() {
        recognitionURI = nil
        photos.deleteStoredPhotos(AddSheetRules.photoFiles(photo))
        photo = nil
        suggestion = .idle
    }

    /// Starts recognition for `uri`. The photo it is for is noted here, before the task runs,
    /// as RN sets `recognitionRef` before its first await (app/item/new.tsx:248): a photo
    /// removed or replaced right after can then never have its answer applied.
    private func startRecognition(uri: String, nameHint: String?, overwrite: Bool = false) {
        recognitionURI = uri
        recognitionTask = Task { await runRecognition(uri: uri, nameHint: nameHint, overwrite: overwrite) }
    }

    /// Runs recognition for `uri` (started by ``startRecognition(uri:nameHint:overwrite:)``);
    /// sets only the terminal states (whoever starts it set `running` or `refreshing`). An
    /// answer about a photo removed or replaced meanwhile, or arriving after the sheet went, is
    /// dropped.
    private func runRecognition(uri: String, nameHint: String?, overwrite: Bool) async {
        let result = await recognize(uri, nameHint)
        guard active, let current = recognitionURI, EntityText.same(current, uri) else { return }

        switch result {
        case .failed(let reason):
            suggestion = .failed(reason)
        case .success(let found, _):
            values = ItemForm.applySuggestion(values, found, overwrite: overwrite)
            // The hint, not the echoed name: it is the title now in the field.
            if overwrite, let nameHint, !nameHint.isEmpty {
                suggestion = .refreshed(forName: nameHint)
            } else {
                suggestion = .applied(confidence: found.confidence, forName: found.name ?? "")
            }
        }
    }

    /// Keeps the current state as the draft (or clears this sheet's draft when there is
    /// nothing worth keeping), as RN's effect does after every change.
    private func syncDraft() {
        guard active else { return }
        let state = AddDraftState(values: values, placeId: placeId, picked: picked, photo: photo, suggestion: suggestion, showMore: showMore)
        drafts.keepDraft(owner: owner, draft: hasContent ? AddDraft(state: state, savedAt: now()) : nil)
    }

    private func leave() {
        active = false
        recognitionURI = nil
    }

    private static func hint(_ typed: String) -> String? {
        typed.isEmpty ? nil : typed
    }
}
