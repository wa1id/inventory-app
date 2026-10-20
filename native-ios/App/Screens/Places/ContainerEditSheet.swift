import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// Edit container (07 §3.8): rename, retype or move it to another space, or delete it. The type
/// is the same tile grid as when creating it, the spaces are all on screen as a list, and the
/// label code is said to stay as it is, because it is printed. The drop zone gets the locked
/// state instead of a form.
///
/// Router calls: saved → `router.close(address)` (only while in front); deleted →
/// `router.dismissAll()` then `router.openSpace(spaceId)`, so a container opened from search or a
/// label never stays in the stack; Go to Spaces (gone) → `router.goToTab(.spaces)`.
struct ContainerEditSheet: View {
    let id: String

    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address
    @State private var model: ContainerEditModel?

    init(id: String) {
        self.id = id
    }

    var body: some View {
        Group {
            if id == DropZone.containerId {
                ScreenFrame(.modal) {
                    CenteredStateScroll {
                        DropZoneLocked { app.router.goToTab(.dropZone) }
                    }
                }
            } else if let model {
                ContainerEditForm(model: model)
                    .inventoryQuery(model)
            } else {
                ScreenFrame(.modal) { Color.clear }
            }
        }
        .navigationTitle(L10n.ContainerForm.editTitle)
        .navigationBarTitleDisplayMode(.inline)
        // A container element: an identifier on the plain stack would replace every child's own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen-container-edit")
        .onAppear {
            guard model == nil, id != DropZone.containerId else { return }
            model = Self.makeModel(app: app, id: id, address: address)
        }
    }

    /// The sheet's model wired to the app: the current repositories, the image store for the
    /// photos a delete orphans, and the router at `address`.
    static func makeModel(app: AppContainer, id: String, address: ScreenAddress?) -> ContainerEditModel {
        let router = app.router
        let model = ContainerEditModel(
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
                case .openSpace(let spaceId):
                    // Not just back: when the space screen was never opened (the container came
                    // from search or a label) that would leave the deleted container in the stack.
                    router.dismissAll()
                    router.openSpace(spaceId)
                }
            }
        )
        #if DEBUG
        PlacesDemo.prepare(model)
        #endif
        return model
    }
}

private struct ContainerEditForm: View {
    let model: ContainerEditModel

    @Environment(AppContainer.self) private var app

    var body: some View {
        switch model.blocking {
        case .failed(let cause):
            ScreenFrame(.modal) {
                CenteredStateScroll {
                    ErrorStateView(cause: .failed(cause), subject: .container, onRetry: { model.container.reload() })
                }
            }
        case .loading:
            ScreenFrame(.modal) { PlacesLoading(variant: .rows, rows: 3, thumb: nil) }
        case .gone:
            ScreenFrame(.modal) {
                CenteredStateScroll {
                    ErrorStateView(cause: .gone, subject: .container, secondary: StateAction(label: L10n.Common.goToSpaces) {
                        app.router.goToTab(.spaces)
                    })
                }
            }
        case nil:
            if let stored = model.stored {
                form(stored)
            }
        }
    }

    private func form(_ stored: Container) -> some View {
        ScreenFrame(.modal) {
            FormLayout {
                if let notice = model.notice {
                    SaveNotice(copy: notice, action: model.isGone ? BannerAction(label: L10n.Common.goToSpaces) { app.router.goToTab(.spaces) } : nil)
                }
            } content: {
                // Type, then name, as when it was created.
                Section {
                    TypeGrid(
                        label: L10n.ContainerForm.typeLabel,
                        value: Binding(get: { model.values.visualType }, set: { model.setVisualType($0) })
                    )
                }
                Section {
                    LabeledTextField(
                        label: L10n.ContainerForm.nameLabel,
                        text: Binding(get: { model.values.name }, set: { model.setName($0) }),
                        // Empty, it goes by its code, so the code is what the field shows.
                        placeholder: stored.shortCode,
                        hint: L10n.ContainerForm.nameHint,
                        isOptional: true,
                        input: LabeledFieldInput(submitLabel: .done, onSubmit: save, capitalization: .sentences),
                        identifier: "container-name"
                    )
                    // The code it goes by, as the tape it is on the box.
                    HStack(spacing: 8) {
                        Tape(code: stored.shortCode, size: .small)
                        Text(verbatim: L10n.ContainerForm.codeNote)
                            .textRole(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: model.codeAccessibilityLabel ?? ""))
                    .accessibilityAddTraits(.isStaticText)
                }
                spaceSection
                Section {
                    PlacesDeleteRow(
                        label: L10n.ContainerForm.delete,
                        hint: L10n.ContainerForm.deleteHint,
                        isLoading: model.isDeleting,
                        isDisabled: model.isDeleteDisabled,
                        identifier: "container-delete"
                    ) {
                        Task { await model.delete() }
                    }
                }
            }
        } bottomBar: {
            BottomBar {
                LoadingButton(
                    label: L10n.ContainerForm.save,
                    isLoading: model.isSaving,
                    isDisabled: model.isSaveDisabled,
                    fullWidth: true,
                    identifier: "container-save",
                    action: save
                )
            }
        }
        .placesDirtyGuard(model.dirtyGuard)
    }

    @ViewBuilder
    private var spaceSection: some View {
        Section {
            switch model.spaceChoice {
            case .options(let spaces):
                ChoiceList(
                    options: spaces.map { space in
                        ChoiceOption(
                            value: space.id,
                            title: space.name,
                            leading: AnyView(SpaceTile(icon: space.icon, color: space.color, size: 32)),
                            identifier: "space-option-\(space.id)"
                        )
                    },
                    selection: Binding(get: { model.values.spaceId }, set: { model.setSpace($0) }),
                    accessibilityLabel: L10n.ContainerForm.spaceLabel
                )
            case .failed(let copy):
                BannerView(
                    tone: .warning,
                    title: copy.title,
                    message: copy.body,
                    primary: BannerAction(label: L10n.Common.tryAgain) { model.retrySpaces() },
                    chrome: .row
                )
            case .loading:
                SkeletonView(variant: .rows, rows: 3, thumb: nil)
                    .listRowInsets(EdgeInsets())
            }
        } header: {
            Text(verbatim: L10n.ContainerForm.spaceLabel)
        }
    }

    private func save() {
        Task { await model.save() }
    }
}

#if DEBUG
#Preview("Tool chest") {
    ShellPreviewHost {
        NavigationStack {
            PlacesPreviewRecord(.container("Tool chest")) { ContainerEditSheet(id: $0) }
        }
    }
}

#Preview("Gone") {
    ShellPreviewHost {
        NavigationStack { ContainerEditSheet(id: "deleted-elsewhere") }
    }
}

#Preview("Drop zone") {
    ShellPreviewHost {
        NavigationStack { ContainerEditSheet(id: DropZone.containerId) }
    }
}
#endif
