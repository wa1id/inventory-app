import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// New space (07 §3.11): a preset in one tap, or a name, icon and colour of one's own.
///
/// With a request (the place picker had no space to offer a container in), the created space is
/// delivered to the opener with `app.router.results.deliver(request, …)` and the sheet closes in
/// the same step (`router.close(address)`); without one, or when nobody waits any more, the sheet
/// opens the new space instead (`router.close(address)` then `router.openSpace(id)`).
struct SpaceNewSheet: View {
    let request: RouteRequest<NewSpaceResult>?

    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address
    @State private var model: SpaceNewModel?

    init(request: RouteRequest<NewSpaceResult>?) {
        self.request = request
    }

    var body: some View {
        Group {
            if let model {
                SpaceNewForm(model: model)
                    .inventoryQuery(model)
            } else {
                ScreenFrame(.modal) { Color.clear }
            }
        }
        .navigationTitle(L10n.SpaceForm.newTitle)
        .navigationBarTitleDisplayMode(.inline)
        // A container element: an identifier on the plain stack would replace every child's own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen-space-new")
        .onAppear {
            guard model == nil else { return }
            model = Self.makeModel(app: app, request: request, address: address)
        }
    }

    /// The sheet's model wired to the app: the current repositories, the router's results, and
    /// closing or replacing this sheet at `address`.
    static func makeModel(app: AppContainer, request: RouteRequest<NewSpaceResult>?, address: ScreenAddress?) -> SpaceNewModel {
        let router = app.router
        let model = SpaceNewModel(
            request: request,
            routeResults: router.results,
            spaces: PlacesRepositories.spaces(app),
            revision: app.database.revision,
            invalidator: app.database,
            toasts: app.toasts,
            confirm: app.platform.confirm,
            haptics: app.platform.haptics,
            telemetry: app.telemetry,
            isFocused: { address.map { router.isFocused($0) } ?? true },
            navigate: { navigation in
                guard let address else { return }
                switch navigation {
                case .close:
                    router.close(address)
                case .openSpace(let id):
                    // In place of the sheet, so Back from the space returns to where this started.
                    router.close(address)
                    router.openSpace(id)
                }
            }
        )
        #if DEBUG
        PlacesDemo.prepare(model)
        #endif
        return model
    }
}

private struct SpaceNewForm: View {
    let model: SpaceNewModel

    @FocusState private var focus: SpaceFieldsFocus?

    var body: some View {
        ScrollViewReader { proxy in
            form
                .onChange(of: model.nameFocusRequests) {
                    focus = .name
                    // Once the keyboard is up, bring "Your own" to the top, so the name's error
                    // under the field is not left behind the bottom bar.
                    Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        withAnimation { proxy.scrollTo(Self.lastPresetID, anchor: .top) }
                    }
                }
                .placesRevealsNotice(model.notice != nil, proxy: proxy)
        }
    }

    private static var lastPresetID: String { SpacePalette.presets.last?.name ?? "" }

    private var form: some View {
        ScreenFrame(.modal) {
            FormLayout {
                if let notice = model.notice {
                    SaveNotice(copy: notice).id(PlacesFormNotice.id)
                }
            } content: {
                Section {
                    ForEach(model.presets) { tile in
                        SpacePresetRow(tile: tile) {
                            Task { await model.pickPreset(tile.preset) }
                        }
                        .id(tile.id)
                    }
                } header: {
                    Text(verbatim: L10n.SpaceForm.quickAdd).accessibilityAddTraits(.isHeader)
                }
                .headerProminence(.increased)
                SpaceFields(
                    values: Binding(get: { model.values }, set: { model.change($0) }),
                    nameError: model.nameError,
                    onSubmit: create,
                    // A new space has nothing to count yet.
                    previewMeta: L10n.SpaceForm.previewNew,
                    focus: $focus,
                    heading: L10n.SpaceForm.yourOwn
                )
            }
        } bottomBar: {
            BottomBar {
                LoadingButton(
                    label: L10n.SpaceForm.create,
                    isLoading: model.isCreatingCustom,
                    isDisabled: model.isCreateDisabled,
                    fullWidth: true,
                    identifier: "space-create-custom",
                    action: create
                )
            }
        }
        .placesDirtyGuard(model.dirtyGuard)
    }

    private func create() {
        Task { await model.createCustom() }
    }
}

/// One quick-add preset: its tile, its name and, when taken, "Already added" (RN `PresetTile`).
/// A tap creates the space at once; a taken one stays readable but is not pressable, and only a
/// wait dims the others. Its spinner joins after 150 ms.
private struct SpacePresetRow: View {
    let tile: SpaceNewModel.PresetTile
    let action: () -> Void

    @State private var spinner = DelayedFlag(delay: .milliseconds(Motion.delay.spinner))

    var body: some View {
        ListRow(
            action: action,
            isDisabled: tile.isDisabled,
            minHeight: 48,
            accessibilityLabel: tile.accessibilityLabel,
            identifier: tile.identifier
        ) {
            SpaceTile(icon: tile.preset.icon, color: tile.preset.color, size: 48)
        } content: {
            Text(verbatim: tile.preset.name)
                .textRole(.name)
                .foregroundStyle(tile.isTaken ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            if tile.isTaken {
                Text(verbatim: L10n.SpaceForm.alreadyAdded)
                    .textRole(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } aside: {
            if spinner.value {
                ProgressView()
            }
        }
        .opacity(tile.isDimmed ? 0.45 : 1)
        .accessibilityValue(Text(verbatim: tile.isBusy ? L10n.A11y.loading : ""))
        .onChange(of: tile.isBusy, initial: true) { _, busy in spinner.setActive(busy) }
    }
}

#if DEBUG
#Preview("New space") {
    ShellPreviewHost {
        NavigationStack { SpaceNewSheet(request: nil) }
    }
}

#Preview("Nothing taken yet") {
    ShellPreviewHost(seed: false) {
        NavigationStack { SpaceNewSheet(request: nil) }
    }
}
#endif
