import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// Edit space (07 §3.13): rename, re-icon or recolour it, or delete it with everything in it.
/// Save is the primary action in the bottom bar; Delete is quiet red text at the end of the form,
/// behind a confirm that spells out what goes with it. The drop zone's system space gets the
/// locked state instead of a form.
///
/// Router calls: saved → `router.close(address)` (only while in front); deleted →
/// `router.goToTab(.spaces)`; Go to Spaces (gone) → `router.goToTab(.spaces)`; the locked state →
/// `router.goToTab(.dropZone)`.
struct SpaceEditSheet: View {
    let id: String

    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address
    @State private var model: SpaceEditModel?

    init(id: String) {
        self.id = id
    }

    var body: some View {
        Group {
            if id == DropZone.spaceId {
                ScreenFrame(.modal) {
                    PlacesFullScreenState {
                        DropZoneLocked { app.router.goToTab(.dropZone) }
                    }
                }
            } else if let model {
                SpaceEditForm(model: model)
                    .inventoryQuery(model)
            } else {
                ScreenFrame(.modal) { Color.clear }
            }
        }
        .navigationTitle(L10n.SpaceForm.editTitle)
        .navigationBarTitleDisplayMode(.inline)
        // A container element: an identifier on the plain stack would replace every child's own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen-space-edit")
        .onAppear {
            guard model == nil, id != DropZone.spaceId else { return }
            model = Self.makeModel(app: app, id: id, address: address)
        }
    }

    /// The sheet's model wired to the app: the current repositories, the image store for the
    /// photos a delete orphans, and the router at `address`.
    static func makeModel(app: AppContainer, id: String, address: ScreenAddress?) -> SpaceEditModel {
        let router = app.router
        let model = SpaceEditModel(
            id: id,
            spaces: PlacesRepositories.spaces(app),
            containers: PlacesRepositories.containers(app),
            photos: app.imageStore,
            revision: app.database.revision,
            invalidator: app.database,
            toasts: app.toasts,
            confirm: app.platform.confirm,
            haptics: app.platform.haptics,
            telemetry: app.telemetry,
            isFocused: { address.map { router.isFocused($0) } ?? true },
            navigate: { navigation in
                switch navigation {
                case .close:
                    if let address { router.close(address) }
                case .goToSpaces:
                    router.goToTab(.spaces)
                }
            }
        )
        #if DEBUG
        PlacesDemo.prepare(model)
        #endif
        return model
    }
}

private struct SpaceEditForm: View {
    let model: SpaceEditModel

    @Environment(AppContainer.self) private var app
    @FocusState private var focus: SpaceFieldsFocus?

    var body: some View {
        switch model.blocking {
        case .failed(let cause):
            ScreenFrame(.modal) {
                PlacesFullScreenState {
                    ErrorStateView(cause: .failed(cause), subject: .space, onRetry: { model.space.reload() })
                }
            }
        case .loading:
            ScreenFrame(.modal) { PlacesLoading(variant: .rows, rows: 3, thumb: nil) }
        case .gone:
            ScreenFrame(.modal) {
                PlacesFullScreenState {
                    ErrorStateView(cause: .gone, subject: .space, secondary: StateAction(label: L10n.Common.goToSpaces) {
                        app.router.goToTab(.spaces)
                    })
                }
            }
        case nil:
            form
        }
    }

    private var form: some View {
        ScrollViewReader { proxy in
            fields
                .placesRevealsNotice(model.notice != nil, proxy: proxy)
        }
    }

    private var fields: some View {
        ScreenFrame(.modal) {
            FormLayout {
                if let notice = model.notice {
                    SaveNotice(copy: notice, action: model.isGone ? BannerAction(label: L10n.Common.goToSpaces) { app.router.goToTab(.spaces) } : nil)
                        .id(PlacesFormNotice.id)
                }
            } content: {
                SpaceFields(
                    values: Binding(get: { model.values }, set: { model.change($0) }),
                    nameError: model.nameError,
                    onSubmit: save,
                    previewMeta: model.previewMeta,
                    previewFallbackName: model.previewFallbackName,
                    focus: $focus
                )
                Section {
                    PlacesDeleteRow(
                        label: L10n.SpaceForm.delete,
                        hint: L10n.SpaceForm.deleteHint,
                        isLoading: model.isDeleting,
                        isDisabled: model.isDeleteDisabled,
                        identifier: "space-delete"
                    ) {
                        Task { await model.delete() }
                    }
                }
            }
        } bottomBar: {
            BottomBar {
                LoadingButton(
                    label: L10n.SpaceForm.save,
                    isLoading: model.isSaving,
                    isDisabled: model.isSaveDisabled,
                    fullWidth: true,
                    identifier: "space-save",
                    action: save
                )
            }
        }
        .placesDirtyGuard(model.dirtyGuard)
        .onChange(of: model.nameFocusRequests) { focus = .name }
    }

    private func save() {
        Task { await model.save() }
    }
}

#if DEBUG
#Preview("Garage") {
    ShellPreviewHost {
        NavigationStack {
            PlacesPreviewRecord(.space("Garage")) { SpaceEditSheet(id: $0) }
        }
    }
}

#Preview("Gone") {
    ShellPreviewHost {
        NavigationStack { SpaceEditSheet(id: "deleted-elsewhere") }
    }
}

#Preview("Drop zone") {
    ShellPreviewHost {
        NavigationStack { SpaceEditSheet(id: DropZone.spaceId) }
    }
}
#endif
