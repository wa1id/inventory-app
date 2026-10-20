import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// Edit details (RN app/item/[id]/edit.tsx, 07 §3.4): name, category, tags and notes, all on
/// screen at once, with Save changes in the bottom bar.
///
/// Quantity is not here (it saves itself on the item screen), nor the place (that is Move). The
/// form is seeded once from the first read and saves with that version's lock; a change made on
/// another phone meanwhile is filled in and announced in a warning banner above the fields. The
/// shell's Cancel asks "Discard your changes?" when the form holds real changes, and the sheet
/// resists a swipe-down while it is dirty or saving.
///
/// The logic is ``EditDetailsModel`` (package).
struct ItemEditSheet: View {
    let id: String

    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address
    @State private var model: EditDetailsModel?
    @FocusState private var nameFocus: ItemEditNameField?
    @FocusState private var detailsFocus: ItemDetailsField?

    init(id: String) {
        self.id = id
    }

    var body: some View {
        ScreenFrame(.modal) {
            if let model {
                content(model)
                    .inventoryQuery(model)
            } else {
                // Something to appear, so `onAppear` makes the model (an empty view would not).
                Color.clear
            }
        } bottomBar: {
            if let model, case .form = model.phase {
                BottomBar {
                    LoadingButton(
                        label: L10n.EditItem.save,
                        isLoading: model.saving,
                        fullWidth: true,
                        identifier: "item-save-changes"
                    ) {
                        model.startSave()
                    }
                }
            }
        }
        .navigationTitle(L10n.EditItem.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheetCloseGuard { await model?.attemptClose() ?? true }
        .interactiveDismissDisabled(model?.dirtyGuard.interactiveDismissDisabled ?? false)
        // A container, so the screen's identifier does not replace its controls' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen-item-edit")
        .onAppear {
            guard model == nil else { return }
            model = Self.makeModel(app: app, id: id, address: address)
        }
        .onChange(of: app.connection.state, initial: true) { _, state in
            model?.setRevoked(state == .revoked)
        }
        .onChange(of: model?.nameFocusRequests) { _, requests in
            if (requests ?? 0) > 0 { nameFocus = .name }
        }
        #if DEBUG
        .task(id: model?.seed?.id) {
            if let model, model.seed != nil { await ItemDemo.editSeeded(model, app: app, address: address) }
        }
        #endif
    }

    @ViewBuilder
    private func content(_ model: EditDetailsModel) -> some View {
        switch model.phase {
        case .loading:
            ScrollView {
                SkeletonView(variant: .detail)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .failed(let cause):
            ItemStateScroll {
                ErrorStateView(cause: .failed(cause), subject: .item, onRetry: { model.retry() })
            }
        case .gone:
            ItemStateScroll {
                ErrorStateView(
                    cause: .gone,
                    subject: .item,
                    secondary: StateAction(label: L10n.Common.close) { close() }
                )
            }
        case .form:
            form(model)
        }
    }

    private func form(_ model: EditDetailsModel) -> some View {
        @Bindable var model = model
        return FormLayout {
            // Above the fields, so it is seen whatever was scrolled to.
            if let notice = model.notice {
                BannerView(tone: .warning, title: notice.title, message: notice.message, live: .assertive, identifier: "item-edit-notice")
            }
        } content: {
            Section {
                nameRow(model)
            }
            Section {
                ItemDetailsFields(values: $model.values, suggestions: model.categorySuggestions, focus: $detailsFocus)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// The read-only photo beside the name it goes with, so it does not read as an empty slot;
    /// above it at large sizes. Photos of existing items cannot be replaced (05 §15).
    private func nameRow(_ model: EditDetailsModel) -> some View {
        @Bindable var model = model
        return AdaptiveStack(horizontalAlignment: .leading, verticalAlignment: .center, spacing: 12) {
            if let photo = model.photoUri {
                Thumb(uri: photo, size: DesignMetrics.thumb)
            }
            LabeledTextField(
                label: L10n.EditItem.nameLabel,
                text: $model.values.name,
                placeholder: L10n.Item.NameIt.placeholder,
                error: model.nameError,
                isRequired: !model.nameIsOptional,
                input: LabeledFieldInput(
                    submitLabel: .next,
                    onSubmit: { detailsFocus = .category },
                    capitalization: .sentences
                ),
                identifier: "item-name",
                focus: $nameFocus,
                field: .name
            )
        }
    }

    private func close() {
        if let address { app.router.close(address) }
    }

    /// The model with the app's wiring: the current repositories, the database, toasts, the
    /// platform's confirmation and haptics, the category memory and the router.
    static func makeModel(app: AppContainer, id: String, address: ScreenAddress?) -> EditDetailsModel {
        let router = app.router
        let categories = app.categories
        return EditDetailsModel(
            id: id,
            items: app.repositories.items,
            revision: app.database.revision,
            invalidator: app.database,
            toasts: app.toasts,
            confirm: app.platform.confirm,
            haptics: app.platform.haptics,
            telemetry: app.telemetry,
            categories: EditDetailsModel.Categories(
                suggest: { categories.suggestions(for: $0) },
                record: { categories.record($0) }
            ),
            routing: EditDetailsModel.Routing(
                isFocused: { address.map { router.isFocused($0) } ?? false },
                close: {
                    if let address { router.close(address) }
                }
            )
        )
    }
}

/// The name field's focus (the details fields have their own, `ItemDetailsField`).
enum ItemEditNameField: Hashable {
    case name
}

extension EditDetailsModel: ShellFocusDriven {}

#if DEBUG
#Preview("Edit details") {
    ShellPreviewHost {
        NavigationStack { ItemEditPreviewRoute(name: "Cordless drill") }
    }
}

#Preview("Unnamed") {
    ShellPreviewHost {
        NavigationStack { ItemEditPreviewRoute(name: "") }
    }
}

#Preview("Gone") {
    ShellPreviewHost {
        NavigationStack { ItemEditSheet(id: "missing") }
    }
}

/// Finds a seeded item by name and edits it.
private struct ItemEditPreviewRoute: View {
    let name: String
    @Environment(AppContainer.self) private var app
    @State private var id: String?

    var body: some View {
        Group {
            if let id { ItemEditSheet(id: id) }
        }
        .task {
            let items = (try? await app.repositories.items.listRecent(limit: 100)) ?? []
            id = items.first { $0.name == name }?.id
        }
    }
}
#endif
