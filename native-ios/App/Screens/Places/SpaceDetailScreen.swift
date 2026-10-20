import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// A space (07 §3.12): its containers sorted by label, New container, Edit. Large title (D-9):
/// the space's name is the navigation title and its tile and counts sit under it. The drop
/// zone's system space is the Drop zone tab, never this screen.
///
/// Router calls: a container row → `router.openContainer(id)`; New container (bottom bar and the
/// empty state) → `router.present(.containerNew(spaceId: id, request: nil))`; Edit →
/// `router.present(.spaceEdit(id: id))`; Go to Spaces → `router.goToTab(.spaces)`.
struct SpaceDetailScreen: View {
    let id: String

    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address
    @State private var model: SpaceDetailModel?

    init(id: String) {
        self.id = id
    }

    var body: some View {
        Group {
            if let model {
                SpaceDetailContent(model: model)
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
                        app.router.present(.spaceEdit(id: id))
                    } label: {
                        Label(editLabel, glyph: .edit)
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("space-edit")
                }
            }
        }
        // A container element: an identifier on the plain stack would replace every child's own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen-space")
        .onAppear {
            // An old link to the drop zone's system space goes to its tab instead. The screen
            // takes itself off its stack first (RN's goToTab popped it), or the tab it was pushed
            // on would bounce to the drop zone every time it shows.
            if id == DropZone.spaceId {
                if let address { app.router.close(address) }
                app.router.goToTab(.dropZone)
                return
            }
            guard model == nil else { return }
            model = Self.makeModel(app: app, id: id)
        }
    }

    static func makeModel(app: AppContainer, id: String) -> SpaceDetailModel {
        SpaceDetailModel(id: id, spaces: PlacesRepositories.spaces(app), containers: PlacesRepositories.containers(app), revision: app.database.revision)
    }
}

private struct SpaceDetailContent: View {
    let model: SpaceDetailModel

    @Environment(AppContainer.self) private var app

    var body: some View {
        ScreenFrame(.detail) {
            switch model.blocking {
            case .failed(let cause):
                CenteredStateScroll {
                    ErrorStateView(cause: .failed(cause), subject: .space, onRetry: { model.reloadAll() })
                }
            case .loading:
                PlacesLoading(variant: .list)
            case .gone:
                CenteredStateScroll {
                    ErrorStateView(cause: .gone, subject: .space, secondary: StateAction(label: L10n.Common.goToSpaces) {
                        app.router.goToTab(.spaces)
                    })
                }
            case nil:
                if let space = model.spaceData {
                    list(space)
                }
            }
        } bottomBar: {
            if model.blocking == nil && model.hasBottomBar {
                BottomBar {
                    LoadingButton(
                        label: L10n.Spaces.newContainer,
                        glyph: .plus,
                        variant: .secondary,
                        fullWidth: true,
                        identifier: "containers-create",
                        action: newContainer
                    )
                    .accessibilityShowsLargeContentViewer()
                }
                // Pinned chrome stops at RN's button cap (08 §6: 1.6 → xxxLarge): uncapped, the
                // label took two lines and the bar a fifth of the screen at AX5.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
        }
        .navigationTitle(model.spaceData?.name ?? "")
        .navigationBarTitleDisplayMode(.large)
        .announcesOnChange(L10n.Errors.refreshFailed, enabled: model.blocking == nil && model.showsRefreshBanner)
    }

    private func list(_ space: Space) -> some View {
        List {
            Section {
                HStack(spacing: 16) {
                    SpaceTile(icon: space.icon, color: space.color, size: 64, surface: .page)
                    if let meta = model.meta {
                        Text(verbatim: meta)
                            .textRole(.meta)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            // RN's cap for the meta role (08 §6: 2.0 → AX1), as on the container
                            // screen's head: uncapped, the counts took four lines beside the tile
                            // on a 375 pt phone at AX5 and pushed the containers off the screen.
                            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // The counts are their own element: a row of static content is otherwise read
                // as one, framed round the tile as well.
                .accessibilityElement(children: .contain)
                .listRowBackground(Color.clear)
                // In line with the large title, and clear of the section's rounded clip.
                .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
            }
            if model.showsRefreshBanner {
                Section {
                    BannerView(
                        tone: .info,
                        message: L10n.Errors.refreshFailed,
                        primary: BannerAction(label: L10n.Common.tryAgain) { model.reloadAll() },
                        // Announced by the screen, once (a row scrolled away and back would
                        // say it again).
                        live: .off,
                        chrome: .row,
                        identifier: "refresh-banner"
                    )
                }
            }
            contents(space)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .refreshable { await model.refresh() }
    }

    @ViewBuilder
    private func contents(_ space: Space) -> some View {
        switch model.contents {
        case .rows(let rows):
            Section {
                ForEach(rows) { row in
                    ContainerRow(container: ContainerRowData(row), context: .space) {
                        app.router.openContainer(row.id)
                    }
                }
            }
        case .empty:
            Section {
                EmptyStateView(
                    title: model.emptyTitle,
                    message: L10n.Spaces.NoContainers.body,
                    glyph: .box,
                    primary: StateAction(label: L10n.Spaces.NoContainers.action, glyph: .plus, identifier: "containers-empty", action: newContainer)
                )
                .placesStateRow()
            }
        case .failed(let cause):
            Section {
                ErrorStateView(cause: .failed(cause), onRetry: { model.containers.reload() })
                    .placesStateRow()
            }
        case .loading:
            Section {
                SkeletonView(variant: .rows, rows: 4, thumb: nil)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
        }
    }

    private func newContainer() {
        app.router.present(.containerNew(spaceId: model.id, request: nil))
    }
}

#if DEBUG
#Preview("Garage") {
    ShellPreviewHost {
        NavigationStack {
            PlacesPreviewRecord(.space("Garage")) { SpaceDetailScreen(id: $0) }
        }
    }
}

#Preview("No containers") {
    ShellPreviewHost(seed: false) {
        PlacesPreviewEmptySpace()
    }
}

#Preview("Gone") {
    ShellPreviewHost {
        NavigationStack { SpaceDetailScreen(id: "deleted-elsewhere") }
    }
}

/// A space with nothing in it, made in the preview's empty inventory.
private struct PlacesPreviewEmptySpace: View {
    @Environment(AppContainer.self) private var app
    @State private var id: String?

    var body: some View {
        NavigationStack {
            if let id { SpaceDetailScreen(id: id) } else { ProgressView() }
        }
        .task {
            id = try? await app.repositories.spaces.create(CreateSpaceInput(name: "Shed", icon: "🪴", color: "#2E9E4F")).id
        }
    }
}
#endif
