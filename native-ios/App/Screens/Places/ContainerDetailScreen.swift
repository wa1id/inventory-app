import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// A container (07 §3.7), large title (D-9): its space as a link, its type and count, its code on
/// the big tape with the QR label entry, and its contents with a compact stepper on each row.
/// Never the drop zone (the router opens its tab instead).
///
/// Router calls: the crumb → `router.openSpace(spaceId)`; the QR entry →
/// `router.push(.qrLabel(containerId: id))`; a row → `router.push(.item(id:filing: false))`; Add
/// here → `router.present(.addItem(AddParams(containerId: id)))`; Take a photo →
/// `router.present(.capture(CaptureRoute(containerId: id, mode: .single), request: nil))`; Edit →
/// `router.present(.containerEdit(id: id))`; Go to Spaces → `router.goToTab(.spaces)`.
struct ContainerDetailScreen: View {
    let id: String

    @Environment(AppContainer.self) private var app
    @State private var model: ContainerDetailModel?

    init(id: String) {
        self.id = id
    }

    var body: some View {
        Group {
            if let model {
                ContainerDetailContent(model: model)
                    .inventoryQuery(model)
            } else {
                ScreenFrame(.detail) { Color.clear }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { SearchButton() }
            if let model, let editLabel = model.editLabel {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        app.router.present(.containerEdit(id: id))
                    } label: {
                        Label(editLabel, glyph: .edit)
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("container-edit")
                }
            }
        }
        // A container element: an identifier on the plain stack would replace every child's own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen-container")
        .onAppear {
            // The drop zone is a real container row, but its screen is the Drop zone tab.
            if id == DropZone.containerId {
                app.router.goToTab(.dropZone)
                return
            }
            guard model == nil else { return }
            model = Self.makeModel(app: app, id: id)
        }
    }

    static func makeModel(app: AppContainer, id: String) -> ContainerDetailModel {
        let categories = app.categories
        return ContainerDetailModel(
            id: id,
            spaces: PlacesRepositories.spaces(app),
            containers: PlacesRepositories.containers(app),
            items: PlacesRepositories.items(app),
            quantities: app.makeRowQuantityModels(),
            revision: app.database.revision,
            rememberCategories: { categories.rememberCategories($0) },
            now: app.now
        )
    }
}

private struct ContainerDetailContent: View {
    let model: ContainerDetailModel

    @Environment(AppContainer.self) private var app
    private let layout = LayoutScale()

    var body: some View {
        ScreenFrame(.detail) {
            switch model.blocking {
            case .failed(let cause):
                PlacesFullScreenState {
                    ErrorStateView(cause: .failed(cause), subject: .container, onRetry: { model.reloadAll() })
                }
            case .loading:
                PlacesLoading(variant: .detail)
            case .gone:
                PlacesFullScreenState {
                    ErrorStateView(cause: .gone, subject: .container, secondary: StateAction(label: L10n.Common.goToSpaces) {
                        app.router.goToTab(.spaces)
                    })
                }
            case nil:
                if let container = model.containerData {
                    list(container)
                }
            }
        } bottomBar: {
            if model.blocking == nil && model.hasBottomBar {
                BottomBar {
                    // One bar: the camera as an icon, "Add here" as the primary under the thumb.
                    HStack(spacing: 12) {
                        Button(action: takePhoto) {
                            // The symbol inside text, so the button takes a text button's height
                            // and sits level with Add here.
                            Text(Image(glyph: .camera))
                                .frame(minWidth: 32)
                        }
                        .buttonStyle(.bordered)
                        .buttonSizing(.fitted)
                        .accessibilityLabel(Text(verbatim: L10n.Container.takePhotoA11y))
                        .accessibilityIdentifier("items-capture")
                        LoadingButton(label: L10n.Container.addHere, glyph: .plus, fullWidth: true, identifier: "items-add", action: addHere)
                    }
                }
            }
        }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.large)
    }

    private func list(_ container: ContainerWithCounts) -> some View {
        List {
            Section {
                head(container)
                    .listRowBackground(Color.clear)
                    // In line with the large title, and clear of the section's rounded clip.
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 18, trailing: 0))
            }
            if model.showsRefreshBanner {
                Section {
                    BannerView(
                        tone: .info,
                        message: L10n.Errors.refreshFailed,
                        primary: BannerAction(label: L10n.Common.tryAgain) { model.reloadAll() },
                        chrome: .row,
                        identifier: "refresh-banner"
                    )
                }
            }
            contents(container)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        // Typing a count in a row's stepper is not cut short by a scroll; a drag puts the
        // number pad away.
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await model.refresh() }
    }

    private func head(_ container: ContainerWithCounts) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let crumb = model.crumb {
                ContainerSpaceCrumb(crumb: crumb) { app.router.openSpace(crumb.id) }
            } else if model.keepsCrumbRoom {
                // Keeps the head from jumping when the space arrives.
                Color.clear.frame(height: DesignMetrics.minTouchTarget).accessibilityHidden(true)
            }
            Text(verbatim: model.subline)
                .textRole(.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            AdaptiveStack(horizontalAlignment: .leading, spacing: 12) {
                Tape(code: container.shortCode, size: .large)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: model.codeAccessibilityLabel))
                    .accessibilityAddTraits(.isStaticText)
                if !layout.isStacked { Spacer(minLength: 0) }
                LoadingButton(
                    label: model.qrLabel,
                    glyph: .qr,
                    variant: .secondary,
                    size: .small,
                    accessibilityLabel: model.qrAccessibilityLabel,
                    identifier: "container-qr"
                ) {
                    app.router.push(.qrLabel(containerId: model.id))
                }
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func contents(_ container: ContainerWithCounts) -> some View {
        switch model.contents {
        case .rows(let rows):
            Section {
                ForEach(rows) { item in
                    ContainerContentRow(item: item, model: model) {
                        app.router.push(.item(id: item.id, filing: false))
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Text(verbatim: L10n.Container.inHere)
                    Text(verbatim: "\(rows.count)").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
        case .empty:
            Section {
                EmptyStateView(
                    title: model.emptyTitle,
                    message: L10n.Container.Empty.body,
                    glyph: Glyph.container(container.visualType),
                    primary: StateAction(label: L10n.Container.addHere, glyph: .plus, identifier: "items-empty", action: addHere),
                    secondary: StateAction(label: L10n.Container.takePhoto, glyph: .camera, identifier: "items-capture-empty", action: takePhoto)
                )
                .listRowBackground(Color.clear)
            }
        case .failed(let cause):
            Section {
                ErrorStateView(cause: .failed(cause), onRetry: { model.items.reload() })
                    .listRowBackground(Color.clear)
            }
        }
    }

    private func addHere() {
        app.router.present(.addItem(AddParams(containerId: model.id)))
    }

    private func takePhoto() {
        // A container is a single-item entry point.
        app.router.present(.capture(CaptureRoute(containerId: model.id, mode: .single), request: nil))
    }
}

/// "● Garage ›": the way back up to the space, a link rather than plain text, so the space is one
/// tap away however the container was opened (RN `SpaceCrumb`).
private struct ContainerSpaceCrumb: View {
    let crumb: ContainerDetailModel.Crumb
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                SpacePip(color: crumb.color, size: 10)
                Text(verbatim: crumb.name)
                    .textRole(.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Image(glyph: .chevronRight)
                    .font(.footnote.weight(.semibold))
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: DesignMetrics.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: L10n.Container.crumbA11y(space: crumb.name)))
        .accessibilityAddTraits(.isLink)
        .accessibilityRemoveTraits(.isButton)
        .accessibilityIdentifier("container-space")
    }
}

/// One item with its compact stepper, picked out for a moment when it has just arrived from Add
/// (RN `ArrivalHighlight`): the selected fill and a 3 pt ink bar hold 600 ms, then fade over
/// 1200 ms; under Reduce Motion they hold 1800 ms and then go at once. Decided once per row.
private struct ContainerContentRow: View {
    let item: ItemWithContext
    let model: ContainerDetailModel
    let onPress: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The highlight is drawn (only then does the row replace the list's own background, so the
    /// row's press highlight is the system's otherwise).
    @State private var isArriving = false
    @State private var highlight: Double = 0

    var body: some View {
        ItemRow(item: item, line: .detail, tool: .stepper(model.quantities.model(for: item)), onPress: onPress)
            .listRowBackground(isArriving ? arrivalBackground : nil)
            .task(id: item.id) {
                guard model.claimsArrival(item) else { return }
                isArriving = true
                highlight = 1
                try? await Task.sleep(for: .milliseconds(600 + (reduceMotion ? 1200 : 0)))
                guard !Task.isCancelled else { return }
                let fade = Motion.motionMs(1200, reduced: reduceMotion)
                if fade == 0 {
                    highlight = 0
                    isArriving = false
                } else {
                    withAnimation(.easeOut(duration: Double(fade) / 1000)) {
                        highlight = 0
                    } completion: {
                        isArriving = false
                    }
                }
            }
    }

    private var arrivalBackground: some View {
        ZStack(alignment: .leading) {
            Color(uiColor: .secondarySystemGroupedBackground)
            Color(uiColor: .systemFill).opacity(highlight)
            Rectangle().fill(Color.accentColor).frame(width: 3).opacity(highlight)
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Tool chest") {
    ShellPreviewHost {
        NavigationStack {
            PlacesPreviewRecord(.container("Tool chest")) { ContainerDetailScreen(id: $0) }
        }
    }
}

#Preview("Empty") {
    ShellPreviewHost(seed: false) {
        PlacesPreviewEmptyContainer()
    }
}

#Preview("Gone") {
    ShellPreviewHost {
        NavigationStack { ContainerDetailScreen(id: "deleted-elsewhere") }
    }
}

/// An empty bin in a new space, made in the preview's empty inventory.
private struct PlacesPreviewEmptyContainer: View {
    @Environment(AppContainer.self) private var app
    @State private var id: String?

    var body: some View {
        NavigationStack {
            if let id { ContainerDetailScreen(id: id) } else { ProgressView() }
        }
        .task {
            guard let space = try? await app.repositories.spaces.create(CreateSpaceInput(name: "Shed", icon: "🪴", color: "#2E9E4F")) else { return }
            id = try? await app.repositories.containers.create(CreateContainerInput(spaceId: space.id, name: "Seed tray", visualType: .bin)).id
        }
    }
}
#endif
