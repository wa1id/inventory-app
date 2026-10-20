import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// New container in a space (07 §3.6): its type, and a name only if wanted.
///
/// With a request (the place picker's "New container in …"), the created container is delivered
/// with `app.router.results.deliver(request, NewContainerResult(container))` and the sheet closes
/// in the same step (`router.close(address)`), so the picker, and a Move sheet under it that only
/// closes while it is in front, carry on with the sheet gone (UI-KIT §5.1). Without a request, or
/// when nobody waits any more, the sheet opens the container instead (`router.close(address)` then
/// `router.openContainer(id)`). The drop zone's system space gets the locked state.
struct ContainerNewSheet: View {
    let spaceId: String
    let request: RouteRequest<NewContainerResult>?

    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address
    @State private var model: ContainerNewModel?

    init(spaceId: String, request: RouteRequest<NewContainerResult>?) {
        self.spaceId = spaceId
        self.request = request
    }

    var body: some View {
        Group {
            if spaceId == DropZone.spaceId {
                ScreenFrame(.modal) {
                    CenteredStateScroll {
                        DropZoneLocked { app.router.goToTab(.dropZone) }
                    }
                }
            } else if let model {
                ContainerNewForm(model: model)
                    .inventoryQuery(model)
            } else {
                ScreenFrame(.modal) { Color.clear }
            }
        }
        .navigationTitle(L10n.ContainerForm.newTitle)
        .navigationBarTitleDisplayMode(.inline)
        // A container element: an identifier on the plain stack would replace every child's own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen-container-new")
        .onAppear {
            guard model == nil, spaceId != DropZone.spaceId else { return }
            model = Self.makeModel(app: app, spaceId: spaceId, request: request, address: address)
        }
    }

    /// The sheet's model wired to the app: the current repositories, the router's results, and
    /// closing or replacing this sheet at `address`.
    static func makeModel(
        app: AppContainer,
        spaceId: String,
        request: RouteRequest<NewContainerResult>?,
        address: ScreenAddress?
    ) -> ContainerNewModel {
        let router = app.router
        let model = ContainerNewModel(
            spaceId: spaceId,
            request: request,
            routeResults: router.results,
            spaces: PlacesRepositories.spaces(app),
            containers: PlacesRepositories.containers(app),
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
                case .openContainer(let id):
                    // In place of the sheet: a new container is there to be filled.
                    router.close(address)
                    router.openContainer(id)
                }
            }
        )
        #if DEBUG
        PlacesDemo.prepare(model)
        #endif
        return model
    }
}

private struct ContainerNewForm: View {
    let model: ContainerNewModel

    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address

    var body: some View {
        Group {
            if model.isSpaceGone {
                // The space was deleted, probably on another phone: nothing to add to.
                ScreenFrame(.modal) {
                    CenteredStateScroll {
                        ErrorStateView(cause: .gone, subject: .space, secondary: StateAction(label: L10n.Common.goBack) {
                            if let address { app.router.close(address) }
                        })
                    }
                }
            } else {
                form
            }
        }
        // Over the gone state too, as RN's guard sat above its early return: typing is still
        // asked about on Cancel.
        .placesDirtyGuard(model.dirtyGuard)
    }

    private var form: some View {
        ScreenFrame(.modal) {
            FormLayout {
                if let notice = model.notice {
                    SaveNotice(copy: notice)
                }
            } content: {
                Section {
                    TypeGrid(
                        label: L10n.ContainerForm.typeLabel,
                        value: Binding(get: { model.visualType }, set: { model.setVisualType($0) })
                    )
                } header: {
                    if let context = model.contextLine, let space = model.spaceData {
                        HStack(spacing: 8) {
                            SpacePip(color: space.color, size: 10)
                            Text(verbatim: context)
                        }
                        .textCase(nil)
                        .accessibilityElement(children: .combine)
                    }
                }
                Section {
                    LabeledTextField(
                        label: L10n.ContainerForm.nameLabel,
                        text: Binding(get: { model.name }, set: { model.setName($0) }),
                        placeholder: L10n.ContainerForm.namePlaceholder,
                        hint: L10n.ContainerForm.nameHint,
                        isOptional: true,
                        input: LabeledFieldInput(submitLabel: .done, onSubmit: save, capitalization: .sentences),
                        identifier: "container-name"
                    )
                }
            }
        } bottomBar: {
            BottomBar {
                LoadingButton(
                    label: L10n.ContainerForm.create,
                    isLoading: model.isSaving,
                    fullWidth: true,
                    identifier: "container-create",
                    action: save
                )
            }
        }
    }

    private func save() {
        Task { await model.save() }
    }
}

#if DEBUG
#Preview("In Garage") {
    ShellPreviewHost {
        NavigationStack {
            PlacesPreviewRecord(.space("Garage")) { ContainerNewSheet(spaceId: $0, request: nil) }
        }
    }
}

#Preview("Space gone") {
    ShellPreviewHost {
        NavigationStack { ContainerNewSheet(spaceId: "deleted-elsewhere", request: nil) }
    }
}

#Preview("Drop zone") {
    ShellPreviewHost {
        NavigationStack { ContainerNewSheet(spaceId: DropZone.spaceId, request: nil) }
    }
}
#endif
