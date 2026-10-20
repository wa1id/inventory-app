import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// One item: where it is first, then the small edits (RN app/item/[id]/index.tsx, 07 §3.2).
///
/// The photo beside the name and category, or beside "What is it?" for an unnamed Quick Snap
/// shot. Then "Kept in" with Move or File it…, the quantity that saves itself, the tags and
/// notes, Edit details with when it was added, and Delete. The name is the screen's title in the
/// content, where it wraps at any size; the bar shows it once it has scrolled under (RN
/// `useCollapsingTitle`, 07 §0.11's inline variant). `filing` is a filing run from the Drop zone
/// (RN `?filing=1`): the bar counts what waits until the name scrolls under, the name field takes
/// focus once the screen has arrived (VoiceOver goes to the title), and after File it… the screen
/// replaces itself with the next waiting item or goes back once all is filed.
///
/// The logic is ``ItemDetailModel`` (package); ``ItemDetailBody`` draws it and maps its routing
/// to the router.
struct ItemDetailScreen: View {
    let id: String
    let filing: Bool

    init(id: String, filing: Bool) {
        self.id = id
        self.filing = filing
    }

    var body: some View {
        // Keyed by the item: a filing run replaces this screen with the next item's in the same
        // place of the stack, and SwiftUI would otherwise keep the first item's model.
        ItemDetailBody(id: id, filing: filing)
            .id("\(id)|\(filing)")
    }
}

/// The item screen for one item id (see ``ItemDetailScreen``).
struct ItemDetailBody: View {
    let id: String
    let filing: Bool

    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var model: ItemDetailModel?
    @State private var ticker = NowTicker()
    /// A filing run's screen has finished sliding in: the name field may take focus.
    @State private var arrived = false
    @State private var focusedHeading = false
    /// The title block has scrolled under the bar: the bar shows the name.
    @State private var titleCollapsed = false
    /// Where the bar ends, in window coordinates.
    @State private var barBottom: CGFloat = 0
    @AccessibilityFocusState private var headingFocused: Bool
    @AccessibilityFocusState private var fileItFocused: Bool
    @AccessibilityFocusState private var editFocused: Bool
    private let layout = LayoutScale()

    /// How long a pushed screen's slide-in is waited for before the name field takes focus
    /// (RN waited for `transitionEnd`, at most 700 ms; SwiftUI reports no end, and the push
    /// takes about 0.35 s).
    private static let arrivalWait: Duration = .milliseconds(500)

    var body: some View {
        ScreenFrame(.detail) {
            if let model {
                content(model)
                    .inventoryQuery(model)
            } else {
                // Something to appear, so `onAppear` makes the model (an empty view would not).
                Color.clear
            }
        }
        .navigationTitle(titleCollapsed ? (model?.title ?? "") : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // "3 waiting" while the name is in sight (RN `RunProgress`).
            if let progress = model?.progress, !titleCollapsed {
                ToolbarItem(placement: .principal) {
                    Text(verbatim: progress)
                        .textRole(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            ToolbarItem(placement: .primaryAction) { SearchButton() }
        }
        .nowTicker(ticker)
        // A name that arrives while one is typed is said, as RN's live region was; from here
        // rather than the field's row, which the list does not draw while it is scrolled away.
        .announcesOnChange(nameNotice ?? "", enabled: nameNotice != nil)
        // A container, so the screen's identifier does not replace its controls' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen-item")
        .onAppear {
            guard model == nil else { return }
            model = ItemDetailScreen.makeModel(app: app, id: id, filing: filing, address: address)
        }
        .task {
            guard filing else { return }
            try? await Task.sleep(for: Self.arrivalWait)
            arrived = true
        }
        .onChange(of: model?.focusRequest) { _, request in
            guard let request else { return }
            // Once the field has gone, focus moves on to what comes next.
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                switch request.target {
                case .fileIt: fileItFocused = true
                case .editDetails: editFocused = true
                }
            }
        }
        .onChange(of: arrived && model?.stored != nil) { _, ready in
            // With VoiceOver on, the next item of a run announces itself: its title (or "What
            // is it?") takes focus once.
            guard filing, ready, voiceOverEnabled, !focusedHeading else { return }
            focusedHeading = true
            headingFocused = true
        }
        #if DEBUG
        .task(id: model?.stored?.id) {
            if let model, model.stored != nil { await ItemDemo.itemLoaded(model, app: app) }
        }
        #endif
    }

    /// The name field's line about a name that arrived meanwhile, while the field shows.
    private var nameNotice: String? {
        guard let model, model.isNaming else { return nil }
        return model.nameField?.notice
    }

    // MARK: States

    @ViewBuilder
    private func content(_ model: ItemDetailModel) -> some View {
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
            // Read fine, but nothing there: deleted, probably on another phone.
            ItemStateScroll {
                ErrorStateView(
                    cause: .gone,
                    subject: .item,
                    secondary: StateAction(label: L10n.Common.goBack) { close() }
                )
            }
        case .loaded(let item):
            loaded(model, item: item)
        }
    }

    private func loaded(_ model: ItemDetailModel, item: ItemWithContext) -> some View {
        List {
            if model.showsRefreshBanner {
                Section {
                    BannerView(
                        tone: .info,
                        message: L10n.Errors.refreshFailed,
                        primary: BannerAction(label: L10n.Common.tryAgain) { model.retry() }
                    )
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                identity(model, item: item)
            }
            // In line with the cards' contents, and clear of the row's rounded corners (a row
            // clips its content to them even with a clear background).
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(Color.clear)

            Section {
                WhereCard(
                    place: item,
                    name: model.name,
                    links: LocationLine.Links(
                        openSpace: { app.router.openSpace(item.spaceId) },
                        openContainer: { app.router.openContainer(item.containerId) }
                    ),
                    actionFocus: $fileItFocused,
                    onMove: { model.startMoveOrFile() }
                )
                .padding(.vertical, 6)
            }

            if let quantity = model.quantity {
                Section {
                    quantityRow(quantity, name: model.name)
                }
            }

            if model.hasFacts {
                Section {
                    facts(item)
                }
            }

            Section {
                Button {
                    model.openEdit()
                } label: {
                    Label(L10n.Item.editDetails, glyph: .edit)
                }
                .accessibilityLabelIfPresent(model.editAccessibilityLabel)
                .accessibilityIdentifier("item-edit")
                .accessibilityFocused($editFocused)
            } footer: {
                Text(verbatim: model.stamp(now: ticker.now))
                    .textRole(.caption)
            }

            Section {
                deleteButton(model)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollDismissesKeyboard(.interactively)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).minY + proxy.safeAreaInsets.top
        } action: { bottom in
            barBottom = bottom
        }
    }

    // MARK: Parts

    /// The photo beside the name and category, or beside "What is it?" while it has no name;
    /// above them at large sizes.
    private func identity(_ model: ItemDetailModel, item: ItemWithContext) -> some View {
        AdaptiveStack(horizontalAlignment: .leading, verticalAlignment: .center, spacing: 16) {
            Thumb(
                uri: model.thumbUri,
                size: DesignMetrics.thumbDetail,
                action: model.photoUri != nil ? { openPhoto() } : nil,
                accessibilityLabel: model.photoAccessibilityLabel,
                identifier: "item-photo"
            )
            if model.isNaming, let field = model.nameField {
                ItemNameField(model: field, autoFocus: filing && arrived, headingFocus: $headingFocused)
                    .id(field.itemId + String(describing: ObjectIdentifier(field)))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: model.name)
                        .textRole(.itemTitle)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityFocused($headingFocused)
                        .accessibilityIdentifier("item-title")
                    if let category = model.category {
                        Text(verbatim: category)
                            .textRole(.meta)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: layout.isStacked ? nil : DesignMetrics.thumbDetail, alignment: .leading)
        .onGeometryChange(for: Bool.self) { [barBottom] proxy in
            barBottom > 0 && proxy.frame(in: .global).maxY <= barBottom
        } action: { collapsed in
            titleCollapsed = collapsed
        }
    }

    /// "Quantity" level with the large stepper; the stepper under it at large sizes.
    @ViewBuilder
    private func quantityRow(_ quantity: SavedQuantityModel, name: String) -> some View {
        let label = Text(verbatim: L10n.Quantity.label)
            .textRole(.factLabel)
            .foregroundStyle(.secondary)
        if layout.isStacked {
            VStack(alignment: .leading, spacing: 10) {
                label
                SavedQuantityStepper(model: quantity, itemName: name)
            }
            .padding(.vertical, 6)
        } else {
            HStack(alignment: .top, spacing: 12) {
                // Level with the stepper, not with the stepper and its note at zero.
                label
                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                SavedQuantityStepper(model: quantity, itemName: name)
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func facts(_ item: ItemWithContext) -> some View {
        if !item.tags.isEmpty {
            FactRow(label: L10n.Forms.tagsLabel) {
                WrappingHStack(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(Array(item.tags.enumerated()), id: \.offset) { _, tag in
                        TagChip(label: tag)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        if let notes = item.notes, !notes.isEmpty {
            FactRow(label: L10n.Forms.notesLabel, selectableText: notes)
                .padding(.vertical, 4)
        }
    }

    private func deleteButton(_ model: ItemDetailModel) -> some View {
        Button(role: .destructive) {
            guard !model.deleting else { return }
            model.startDelete()
        } label: {
            HStack(spacing: 8) {
                Label {
                    Text(verbatim: L10n.Item.delete)
                } icon: {
                    // In red with the words (a list row draws a label's icon in the accent).
                    Image(glyph: .trash).foregroundStyle(DesignColor.signal)
                }
                if model.deleting {
                    Spacer(minLength: 0)
                    ProgressView()
                }
            }
        }
        .accessibilityLabelIfPresent(model.deleteAccessibilityLabel)
        .accessibilityValue(Text(verbatim: model.deleting ? L10n.A11y.loading : ""))
        .accessibilityIdentifier("item-delete")
    }

    // MARK: Routing

    private func openPhoto() {
        model?.openPhoto()
    }

    private func close() {
        if let address { app.router.close(address) }
    }
}

extension ItemDetailScreen {
    /// The model with the app's wiring: the current repositories, the image store, the
    /// platform's dialogs and haptics, and the router for Move, Edit, the photo and the run.
    static func makeModel(app: AppContainer, id: String, filing: Bool, address: ScreenAddress?) -> ItemDetailModel {
        let router = app.router
        let household = app.household
        return ItemDetailModel(
            id: id,
            filing: filing,
            items: app.repositories.items,
            photos: app.imageStore,
            revision: app.database.revision,
            invalidator: app.database,
            toasts: app.toasts,
            confirm: app.platform.confirm,
            haptics: app.platform.haptics,
            telemetry: app.telemetry,
            isPaired: { household.session != nil },
            announce: app.platform.announce,
            routing: ItemDetailModel.Routing(
                openMove: { filing in
                    await router.presentForResult(MoveResult.self) { .sheet(.move(itemId: id, filing: filing, request: $0)) }
                },
                openEdit: { router.present(.itemEdit(id: id)) },
                openPhoto: { PhotoViewerScreen.present(itemId: id, router: router) },
                isFocused: { address.map { router.isFocused($0) } ?? false },
                openNext: { next in
                    if let address { router.replace(address, with: .item(id: next, filing: true)) }
                },
                close: {
                    if let address { router.close(address) }
                }
            )
        )
    }
}

extension ItemDetailModel: ShellFocusDriven {}

/// A full-screen state (an error, a gone item) that stays centred while it fits and scrolls at
/// the largest text sizes (UI-KIT §4).
struct ItemStateScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// "What is it?" in place of the title of an item that has no name yet (RN `NameItInline`,
/// 07 §3.3, 05 §12): the field, why a save failed, a name that arrived meanwhile, Save name and
/// Use “X”. The heading is a header, so the screen stays titled for VoiceOver; the field is
/// spoken as "Name". Return saves and keeps the keyboard up.
struct ItemNameField: View {
    @Bindable var model: NameItModel
    /// Focus the field: in a filing run, once the screen has arrived.
    let autoFocus: Bool
    /// The heading, which a filing run gives VoiceOver focus.
    var headingFocus: AccessibilityFocusState<Bool>.Binding

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: L10n.Item.NameIt.label)
                .textRole(.heading)
                .accessibilityFocused(headingFocus)
            field
            if let error = model.error {
                FieldMessage(text: error)
            }
            if let notice = model.notice {
                Text(verbatim: notice)
                    .textRole(.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            WrappingHStack(horizontalSpacing: 8, verticalSpacing: 8) {
                // Secondary: File it… on the card below is the screen's one primary.
                LoadingButton(
                    label: L10n.Item.NameIt.save,
                    variant: .secondary,
                    size: .small,
                    isLoading: model.saving,
                    identifier: "item-name-it"
                ) {
                    Task { await model.save() }
                }
                if let offered = model.offered {
                    LoadingButton(
                        label: L10n.Item.NameIt.useName(name: offered),
                        variant: .secondary,
                        size: .small,
                        isDisabled: model.saving,
                        identifier: "item-name-use"
                    ) {
                        model.useOffered()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: fieldFocused) { _, focused in model.focused = focused }
        .onChange(of: autoFocus, initial: true) { _, focus in
            if focus { fieldFocused = true }
        }
    }

    private var field: some View {
        let hasError = model.error != nil
        let thick = fieldFocused || hasError
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return TextField(text: $model.value, prompt: Text(verbatim: L10n.Item.NameIt.placeholder)) {
            Text(verbatim: L10n.Item.NameIt.a11y)
        }
        .textRole(.body)
        .textInputAutocapitalization(.sentences)
        .submitLabel(.done)
        .focused($fieldFocused)
        .onSubmit {
            // The keyboard stays up while it saves and if it did not (RN `submitBehavior`).
            fieldFocused = true
            Task { await model.save() }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(shape.fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .overlay(
            shape.strokeBorder(
                hasError ? DesignColor.signal : (fieldFocused ? Color.accentColor : Color(uiColor: .separator)),
                lineWidth: thick ? 2 : 1
            )
        )
        .contentShape(shape)
        .onTapGesture { fieldFocused = true }
        .accessibilityLabel(Text(verbatim: model.accessibilityLabel))
        .accessibilityIdentifier("item-name")
    }
}

#if DEBUG
#Preview("Named, with a photo") {
    ShellPreviewHost {
        NavigationStack { ItemDetailPreviewRoute(name: "Cordless drill") }
    }
}

#Preview("Unnamed, filing run") {
    ShellPreviewHost {
        NavigationStack { ItemDetailPreviewRoute(name: "", filing: true) }
    }
}

#Preview("None left") {
    ShellPreviewHost {
        NavigationStack { ItemDetailPreviewRoute(name: "Printer ink") }
    }
}

#Preview("Gone") {
    ShellPreviewHost {
        NavigationStack { ItemDetailScreen(id: "missing", filing: false) }
    }
}

/// Finds a seeded item by name and shows its screen.
private struct ItemDetailPreviewRoute: View {
    let name: String
    var filing = false
    @Environment(AppContainer.self) private var app
    @State private var id: String?

    var body: some View {
        Group {
            if let id { ItemDetailScreen(id: id, filing: filing) }
        }
        .task {
            let items = (try? await app.repositories.items.listRecent(limit: 100)) ?? []
            id = items.first { $0.name == name }?.id
        }
    }
}
#endif
