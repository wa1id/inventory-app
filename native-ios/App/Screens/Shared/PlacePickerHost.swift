import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// The one view a screen embeds to pick a place (RN `<PlacePicker>`, 07 §4.1): Move and File
/// (item area), the Add sheet's place step (add area), binding a label and the Scan tab's typed
/// code (labels area).
///
/// It builds one ``PlacePickerModel`` for the screen's life from `app.repositories` and
/// `app.recentPlaces`, drives its two reads from the screen's focus (`\.isScreenFocused`) and
/// the database revision, and draws it with the shared `PlacePicker`. "New container in …"
/// opens `.containerNew(spaceId:request:)` for a result and picks the container it made; with
/// no containers at all, the empty state's action opens `.spaceNew(request:)` and then the
/// container form (in `open` mode it just opens the new space). Present it inside a
/// `NavigationStack` (its filter is the stock search field in the navigation bar).
///
/// ```swift
/// PlacePickerHost(mode: move.pickerMode, currentContainerId: item.containerId, busyId: move.busyId) {
///     if let notice = move.notice { BannerView(tone: .warning, message: notice.message) }
/// } onPick: { place in
///     Task { await move.pick(place) }
/// }
/// ```
///
/// `onPick` runs after the `.choice` haptic and never while `busyId` is set; a container made
/// from the picker reaches it with no haptic (RN parity). Saving the pick, the busy row and the
/// notice are the screen's. UI tests find the filter as `app.searchFields.firstMatch`.
struct PlacePickerHost<Notice: View>: View {
    let mode: PlacePickerMode
    /// Move and file: the item's container, "Here now" and not pickable.
    var currentContainerId: String?
    /// Choose: the current choice (the drop zone when nil).
    var selectedContainerId: String?
    /// Choose: "Drop zone · Sort it later" first.
    var showsDropZone = false
    /// "New container in …" under each space; nil for the mode's default (everywhere but `open`).
    var allowsNewContainer: Bool?
    /// The row showing a spinner while the screen saves the pick; the list is locked meanwhile.
    var busyId: String?
    var placeholder: String = L10n.Picker.filter
    /// What the filter holds on arrival.
    var initialQuery = ""
    /// Focus the filter on arrival; nil for the mode's default (only `open`).
    var autoFocusesFilter: Bool?
    /// A banner above the lists; an optional view that is nil adds nothing.
    var notice: Notice
    let onPick: (PickedPlace) -> Void

    @Environment(AppContainer.self) private var app
    @State private var model: PlacePickerModel?
    @State private var relay = PlacePickerHostRelay()

    init(
        mode: PlacePickerMode,
        currentContainerId: String? = nil,
        selectedContainerId: String? = nil,
        showsDropZone: Bool = false,
        allowsNewContainer: Bool? = nil,
        busyId: String? = nil,
        placeholder: String = L10n.Picker.filter,
        initialQuery: String = "",
        autoFocusesFilter: Bool? = nil,
        @ViewBuilder notice: () -> Notice,
        onPick: @escaping (PickedPlace) -> Void
    ) {
        self.mode = mode
        self.currentContainerId = currentContainerId
        self.selectedContainerId = selectedContainerId
        self.showsDropZone = showsDropZone
        self.allowsNewContainer = allowsNewContainer
        self.busyId = busyId
        self.placeholder = placeholder
        self.initialQuery = initialQuery
        self.autoFocusesFilter = autoFocusesFilter
        self.notice = notice()
        self.onPick = onPick
    }

    var body: some View {
        // The model was made with the first `onPick`; the relay hands it the newest one, as RN
        // called the props of the latest render. A plain reference, so nothing redraws.
        let _ = relay.keep(onPick)
        Group {
            if let model {
                picker(model)
                    .inventoryQuery(model)
            } else {
                // One frame, until `onAppear` has made the model.
                PlacePicker(mode: mode, options: nil, spaces: nil, recentIds: [], isLoading: true, autoFocusesFilter: false, placeholder: placeholder, onPick: { _ in })
            }
        }
        .onAppear {
            guard model == nil else { return }
            model = Self.makeModel(
                app: app,
                mode: mode,
                currentContainerId: currentContainerId,
                selectedContainerId: selectedContainerId,
                showsDropZone: showsDropZone,
                allowsNewContainer: allowsNewContainer,
                busyId: busyId,
                initialQuery: initialQuery,
                onPick: { [relay] in relay.onPick($0) }
            )
        }
        .onChange(of: busyId) { _, busyId in model?.busyId = busyId }
        .onChange(of: currentContainerId) { _, id in model?.currentContainerId = id }
        .onChange(of: selectedContainerId) { _, id in model?.selectedContainerId = id }
        .onChange(of: showsDropZone) { _, shows in model?.showsDropZone = shows }
    }

    private func picker(_ model: PlacePickerModel) -> some View {
        PlacePicker(
            mode: mode,
            options: model.options,
            spaces: model.spaces.data,
            recentIds: model.recentIds,
            isLoading: model.isLoading,
            failure: model.failure,
            onRetry: { model.retry() },
            currentContainerId: currentContainerId,
            selectedContainerId: selectedContainerId,
            showsDropZone: showsDropZone,
            allowsNewContainer: model.allowsNewContainer,
            autoFocusesFilter: autoFocusesFilter,
            placeholder: placeholder,
            initialQuery: initialQuery,
            busyId: busyId,
            notice: { notice },
            onPick: { model.pick($0) },
            onNewContainer: { spaceId, spaceName in
                Task { await model.newContainer(in: spaceId, spaceName: spaceName) }
            },
            onNewSpace: { Task { await model.newSpace() } },
            filterText: Binding(get: { model.query }, set: { model.query = $0 }),
            handlesPickFeedback: false
        )
    }

    /// The model the host builds, wired to the app: the current repositories, the recent places
    /// as they are now, the platform's haptics, and the router for the forms. Tests use it to
    /// drive the same wiring without a view.
    static func makeModel(
        app: AppContainer,
        mode: PlacePickerMode,
        currentContainerId: String? = nil,
        selectedContainerId: String? = nil,
        showsDropZone: Bool = false,
        allowsNewContainer: Bool? = nil,
        busyId: String? = nil,
        initialQuery: String = "",
        onPick: @escaping @MainActor (PickedPlace) -> Void
    ) -> PlacePickerModel {
        PlacePickerModel(
            mode: mode,
            currentContainerId: currentContainerId,
            selectedContainerId: selectedContainerId,
            showsDropZone: showsDropZone,
            allowsNewContainer: allowsNewContainer,
            query: initialQuery,
            busyId: busyId,
            reads: PlacePickerModel.Reads(repositories: app.repositories),
            revision: app.database.revision,
            recentPlaces: RecentPlacesModel(store: app.recentPlaces),
            forms: forms(router: app.router),
            haptics: app.platform.haptics,
            onPick: onPick
        )
    }

    /// The forms through the router: new container and new space for a result (a sheet over
    /// the picker's screen), and the new space without waiting where nothing waits for a place.
    static func forms(router: Router) -> PlacePickerModel.Forms {
        PlacePickerModel.Forms(
            createContainer: { spaceId in
                await router.presentForResult(NewContainerResult.self) { .sheet(.containerNew(spaceId: spaceId, request: $0)) }
            },
            createSpace: {
                await router.presentForResult(NewSpaceResult.self) { .sheet(.spaceNew(request: $0)) }
            },
            openNewSpace: { router.present(.spaceNew(request: nil)) }
        )
    }
}

extension PlacePickerHost where Notice == EmptyView {
    init(
        mode: PlacePickerMode,
        currentContainerId: String? = nil,
        selectedContainerId: String? = nil,
        showsDropZone: Bool = false,
        allowsNewContainer: Bool? = nil,
        busyId: String? = nil,
        placeholder: String = L10n.Picker.filter,
        initialQuery: String = "",
        autoFocusesFilter: Bool? = nil,
        onPick: @escaping (PickedPlace) -> Void
    ) {
        self.init(
            mode: mode,
            currentContainerId: currentContainerId,
            selectedContainerId: selectedContainerId,
            showsDropZone: showsDropZone,
            allowsNewContainer: allowsNewContainer,
            busyId: busyId,
            placeholder: placeholder,
            initialQuery: initialQuery,
            autoFocusesFilter: autoFocusesFilter,
            notice: { EmptyView() },
            onPick: onPick
        )
    }
}

/// The newest `onPick` the host was given (see `PlacePickerHost.body`).
@MainActor
final class PlacePickerHostRelay {
    var onPick: (PickedPlace) -> Void = { _ in }

    func keep(_ onPick: @escaping (PickedPlace) -> Void) {
        self.onPick = onPick
    }
}

extension PlacePickerModel: ShellFocusDriven {}

#if DEBUG
#Preview("Move") {
    ShellPreviewHost {
        NavigationStack {
            PlacePickerHost(mode: .move) { _ in }
                .navigationTitle(L10n.Move.titleMoveUnnamed)
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview("File, with a notice") {
    ShellPreviewHost {
        NavigationStack {
            PlacePickerHost(mode: .file) {
                BannerView(tone: .warning, message: L10n.Move.failed, live: .off)
            } onPick: { _ in }
                .navigationTitle(L10n.Move.titleFileUnnamed)
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview("Choose") {
    ShellPreviewHost {
        NavigationStack {
            PlacePickerHost(mode: .choose, showsDropZone: true) { _ in }
                .navigationTitle(L10n.Add.`where`)
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview("Bind") {
    ShellPreviewHost {
        NavigationStack {
            PlacePickerHost(mode: .bind) { _ in }
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview("Open by code") {
    ShellPreviewHost {
        NavigationStack {
            PlacePickerHost(mode: .open) { _ in }
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview("Nothing at all") {
    ShellPreviewHost(seed: false) {
        NavigationStack {
            PlacePickerHost(mode: .file) { _ in }
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
