import InventoryCore
import InventoryStrings
import Observation

// RN: src/ui/components/PlacePicker.tsx:110-288, the logic half of the component (07 §4.1).
// The rows and sections themselves are `PlacePickerRules` (wave 3); this model owns the reads,
// the filter text, the loading and failure rules, the pick and the inline "New container in …"
// and "New space" flows. The SwiftUI side is `PlacePickerHost` (app target), which builds one
// of these per screen and draws it with the shared `PlacePicker` view.

/// One screen's place picker: Move and File, the Add sheet's place step, binding a label and
/// opening a container by its code (RN `PlacePicker`).
///
/// **Reads.** Two ``InventoryQuery`` values, as RN's two `useInventoryQuery` calls:
/// ``containers`` (`containers.listAllWithSpace()`, key `containers-all`) and ``spaces``
/// (`spaces.listWithCounts()`, key `spaces`). Drive both with ``focusChanged(_:revision:)`` and
/// ``revisionChanged(_:)`` (the host does, from the screen's focus and the database revision),
/// so the picker reads again when a form opened over it closes.
///
/// **Inputs** the screen may change at any time: ``query`` (the filter), ``busyId`` (the row
/// whose pick is saving; the list is locked meanwhile), ``currentContainerId``,
/// ``selectedContainerId`` and ``showsDropZone``.
///
/// **Outputs**: ``options``, ``sections``, ``noMatchMessage``, ``isLoading``, ``failure`` and
/// ``isNothingAtAll``, exactly as RN computes them (PlacePicker.tsx:132-205, 279-288).
///
/// **Actions**: ``pick(_:)`` (ignored while busy; plays `.choice`), ``newContainer(in:spaceName:)``
/// and ``newSpace()`` (one form at a time: RN `openOnce`), ``retry()``.
@MainActor
@Observable
public final class PlacePickerModel {
    /// The picker's two reads (tests replace them).
    public struct Reads: Sendable {
        public var containers: @Sendable () async throws -> [ContainerWithSpace]
        public var spaces: @Sendable () async throws -> [SpaceWithCounts]

        public init(
            containers: @escaping @Sendable () async throws -> [ContainerWithSpace],
            spaces: @escaping @Sendable () async throws -> [SpaceWithCounts]
        ) {
            self.containers = containers
            self.spaces = spaces
        }

        /// The repositories in use at each call (`app.repositories`).
        public init(repositories: some InventoryRepositories) {
            let containers = repositories.containers
            let spaces = repositories.spaces
            self.init(
                containers: { try await containers.listAllWithSpace() },
                spaces: { try await spaces.listWithCounts() }
            )
        }
    }

    /// The forms the picker opens and what it does with their answers (the host maps them to
    /// the router).
    public struct Forms {
        /// Opens the new-container form in a space and waits: the container it made, or nil when
        /// it closed without one (`router.presentForResult(NewContainerResult.self) { .sheet(.containerNew(spaceId:request:)) }`).
        public var createContainer: @MainActor (_ spaceId: String) async -> NewContainerResult?
        /// Opens the new-space form and waits: the space it made, or nil
        /// (`router.presentForResult(NewSpaceResult.self) { .sheet(.spaceNew(request:)) }`).
        public var createSpace: @MainActor () async -> NewSpaceResult?
        /// Opens the new-space form without waiting (`router.present(.spaceNew(request: nil))`),
        /// where nothing waits for a place (`open` mode).
        public var openNewSpace: @MainActor () -> Void

        public init(
            createContainer: @escaping @MainActor (_ spaceId: String) async -> NewContainerResult?,
            createSpace: @escaping @MainActor () async -> NewSpaceResult?,
            openNewSpace: @escaping @MainActor () -> Void
        ) {
            self.createContainer = createContainer
            self.createSpace = createSpace
            self.openNewSpace = openNewSpace
        }

        /// Forms that never open (previews, tests that do not create).
        public static var none: Forms {
            Forms(createContainer: { _ in nil }, createSpace: { nil }, openNewSpace: {})
        }
    }

    // MARK: Configuration

    public let mode: PlacePickerMode
    /// "New container in …" under each space; everywhere but `open` by default.
    public let allowsNewContainer: Bool
    /// Move and file: the item's container, "Here now" and not pickable.
    public var currentContainerId: String?
    /// Choose: the current choice (the drop zone when nil).
    public var selectedContainerId: String?
    /// Choose: "Drop zone · Sort it later" first.
    public var showsDropZone: Bool
    /// The row whose pick is saving (the drop zone's is its container id). While set, picks and
    /// the create flows are ignored and the list is locked.
    public var busyId: String?
    /// What the filter holds.
    public var query: String

    // MARK: Reads

    /// `containers.listAllWithSpace()` (key `containers-all`).
    public let containers: InventoryQuery<[ContainerWithSpace]>
    /// `spaces.listWithCounts()` (key `spaces`).
    public let spaces: InventoryQuery<[SpaceWithCounts]>
    /// The recent places as the screen first saw them (``RecentPlacesModel``; up to four show).
    public let recentIds: [String]

    @ObservationIgnored private let forms: Forms
    @ObservationIgnored private let haptics: HapticPlayer
    @ObservationIgnored private let onPick: @MainActor (PickedPlace) -> Void
    /// A form is open (or opening) for a pick (RN `openingRef`).
    @ObservationIgnored private var isOpeningForm = false

    /// - Parameters:
    ///   - allowsNewContainer: nil for the mode's default (everywhere but `open`).
    ///   - revision: the database revision now (`app.database.revision`).
    ///   - recentPlaces: the screen's held recent places (`RecentPlacesModel(store: app.recentPlaces)`).
    ///   - onPick: the screen's pick (RN `onPick`): called by ``pick(_:)`` and, with no haptic,
    ///     with a container just made from the picker.
    public init(
        mode: PlacePickerMode,
        currentContainerId: String? = nil,
        selectedContainerId: String? = nil,
        showsDropZone: Bool = false,
        allowsNewContainer: Bool? = nil,
        query: String = "",
        busyId: String? = nil,
        reads: Reads,
        revision: Int = 0,
        recentPlaces: RecentPlacesModel,
        forms: Forms,
        haptics: @escaping HapticPlayer,
        onPick: @escaping @MainActor (PickedPlace) -> Void
    ) {
        self.mode = mode
        self.allowsNewContainer = allowsNewContainer ?? mode.allowsNewContainerByDefault
        self.currentContainerId = currentContainerId
        self.selectedContainerId = selectedContainerId
        self.showsDropZone = showsDropZone
        self.busyId = busyId
        self.query = query
        containers = InventoryQuery(key: "containers-all", revision: revision, read: reads.containers)
        spaces = InventoryQuery(key: "spaces", revision: revision, read: reads.spaces)
        recentIds = recentPlaces.ids
        self.forms = forms
        self.haptics = haptics
        self.onPick = onPick
    }

    // MARK: Outputs

    /// Every container joined with its space (RN `options`).
    public var options: [PlaceOption] {
        joinPlaceOptions(containers.data ?? [], spaces: spaces.data ?? [])
    }

    /// The sections for ``query`` (``PlacePickerRules/sections(mode:query:options:spaces:recentIds:showDropZone:allowNewContainer:)``).
    public var sections: [PlacePickerSection] {
        PlacePickerRules.sections(
            mode: mode,
            query: query,
            options: options,
            spaces: spaces.data ?? [],
            recentIds: recentIds,
            showDropZone: showsDropZone,
            allowNewContainer: allowsNewContainer
        )
    }

    /// "Nothing matches “q”" when the filter finds no container although there are some.
    public var noMatchMessage: String? {
        PlacePickerRules.noMatchMessage(query: query, options: options, sections: sections)
    }

    /// Either list is loading with nothing to show yet: the skeleton (RN :279-280).
    public var isLoading: Bool {
        (containers.isLoading && containers.data == nil) || (spaces.isLoading && spaces.data == nil)
    }

    /// Why the picker cannot show its lists: the containers failed with nothing to show, or the
    /// spaces have nothing to show and failed (RN :281-286). Shown only when not loading.
    public var failure: (any Error)? {
        if containers.data == nil, let cause = containers.cause { return cause }
        return spaces.data == nil ? spaces.cause : nil
    }

    /// No containers to offer and none can be made here: the "make a space" empty state
    /// (RN `nothingAtAll`, :287-288).
    public var isNothingAtAll: Bool {
        PlacePickerRules.isNothingAtAll(loading: isLoading, options: options, spaces: spaces.data, allowNewContainer: allowsNewContainer)
    }

    /// A pick is saving: the list is dimmed and locked.
    public var isBusy: Bool { busyId != nil }

    // MARK: Driving the reads

    /// The screen gained or lost focus (both reads; see ``InventoryQuery/focusChanged(_:revision:)``).
    public func focusChanged(_ focused: Bool, revision: Int? = nil) {
        containers.focusChanged(focused, revision: revision)
        spaces.focusChanged(focused, revision: revision)
    }

    /// The database revision changed (both reads).
    public func revisionChanged(_ revision: Int) {
        containers.revisionChanged(revision)
        spaces.revisionChanged(revision)
    }

    /// Try again: reads both lists again (RN `reload`).
    public func retry() {
        containers.reload()
        spaces.reload()
    }

    // MARK: Actions

    /// The person picked a row (RN `pick`): ignored while a pick saves (VoiceOver can still
    /// activate a row of the locked list), else the `.choice` haptic and the screen's pick.
    public func pick(_ place: PickedPlace) {
        guard busyId == nil else { return }
        haptics(.choice)
        onPick(place)
    }

    /// "New container in <space>…" (RN `newContainer`, :225-248): opens the form for a result
    /// and picks what it made without reading it back, straight through the screen's pick (no
    /// haptic). The space may be one just made from here and not in ``spaces`` yet: then
    /// `spaceName` names it. Ignored while busy or while another form is open.
    public func newContainer(in spaceId: String, spaceName: String) async {
        guard busyId == nil else { return }
        guard let created = await openOnce({ await self.forms.createContainer(spaceId) }) else { return }
        onPick(.container(PlacePickerRules.option(for: created, spaces: spaces.data, spaceName: spaceName)))
    }

    /// No containers at all (RN `newSpace`, :255-265). Where nothing waits for a place (no
    /// "New container", i.e. `open` mode) the new-space form simply opens. Otherwise it waits
    /// for the space, then for a container in it, and picks that, so a sheet waiting for a
    /// place ends with one.
    public func newSpace() async {
        if !allowsNewContainer {
            forms.openNewSpace()
            return
        }
        guard busyId == nil else { return }
        guard let created = await openOnce({ await self.forms.createSpace() }) else { return }
        await newContainer(in: created.spaceId, spaceName: created.name)
    }

    /// Opens one form at a time: a second tap before the first form is up would stack another
    /// (RN `openOnce`). Nil when one is already open or the form closed without an answer.
    private func openOnce<Value>(_ open: @MainActor () async -> Value?) async -> Value? {
        guard !isOpeningForm else { return nil }
        isOpeningForm = true
        defer { isOpeningForm = false }
        return await open()
    }
}
