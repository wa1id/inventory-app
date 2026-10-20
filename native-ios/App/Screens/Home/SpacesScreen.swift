import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// The Spaces tab: the house, room by room, and where the owner sets it up (RN
/// app/(tabs)/spaces.tsx; 06 §6).
///
/// One inset-grouped section of space rows (a space is recognised by its tinted icon tile
/// before its name is read), closed by a "New space" row so the next step is in reach at the end
/// of the list. `SpacesScreenModel` reads `spaces.listWithCounts()`; a failed first read is
/// never "no spaces yet". A re-tap of the tab scrolls back to the top.
struct SpacesScreen: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.isScreenFocused) private var isScreenFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: SpacesScreenModel?
    @State private var scroller = HomeListScroller()

    var body: some View {
        ScreenFrame(.tabRoot) {
            if let model {
                content(model)
                    .inventoryQuery(model.query)
            } else {
                // One frame, until `onAppear` has made the model (an empty body never appears).
                Color.clear
            }
        }
        .navigationTitle(L10n.Spaces.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SearchButton(identifier: "spaces-search")
                Button {
                    newSpace()
                } label: {
                    Label(L10n.Spaces.newSpace, glyph: .plus)
                }
                .accessibilityIdentifier("spaces-create")
            }
        }
        .onChange(of: app.router.reselections[.spaces] ?? 0) { _, _ in
            guard isScreenFocused else { return }
            scroller.scrollToTop(animated: !reduceMotion)
        }
        .accessibilityIdentifier("screen-spaces")
        .onAppear {
            guard model == nil else { return }
            let household = app.household
            model = SpacesScreenModel(repositories: app.repositories, revision: app.database.revision) {
                household.session != nil
            }
        }
    }

    @ViewBuilder
    private func content(_ model: SpacesScreenModel) -> some View {
        if let placeholder = model.placeholder {
            HomeFillingState(placement: placeholder.isLoading ? .top : .center, banner: model.showsRefreshBanner ? refreshBanner(model) : nil) {
                switch placeholder {
                case .loading:
                    SkeletonView(variant: .rows).padding(.horizontal)
                case .failed(let cause):
                    ErrorStateView(cause: .failed(cause), onRetry: { model.retry() })
                case .start(let offersJoin):
                    EmptyStateView(
                        title: L10n.Spaces.Start.title,
                        message: L10n.Spaces.Start.body,
                        glyph: .spaces,
                        primary: StateAction(label: L10n.Spaces.Start.action, glyph: .plus, identifier: "spaces-empty") { newSpace() },
                        // A phone that has not joined may be about to: its household already has spaces.
                        secondary: offersJoin ? StateAction(label: L10n.Spaces.Start.join) { app.router.push(.household) } : nil
                    )
                }
            }
            .homeListScroller(scroller)
            .refreshable { await model.refresh() }
        } else {
            list(model)
        }
    }

    private func list(_ model: SpacesScreenModel) -> some View {
        List {
            if let subtitle = model.subtitle {
                HomeTitleNote {
                    Text(verbatim: subtitle)
                        .textRole(.meta)
                        .foregroundStyle(.secondary)
                }
            }
            // Offline has the connection banner; anything else is said here, over the old list.
            if model.showsRefreshBanner {
                Section { refreshBanner(model) }
            }
            Section {
                ForEach(model.spaces, id: \.id) { space in
                    SpaceRow(space: space) { app.router.openSpace(space.id) }
                }
                if model.showsNewSpaceRow {
                    HomeNewSpaceRow { newSpace() }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .homeListScroller(scroller)
        .refreshable { await model.refresh() }
    }

    private func refreshBanner(_ model: SpacesScreenModel) -> BannerView {
        BannerView(
            tone: .info,
            message: L10n.Errors.refreshFailed,
            primary: BannerAction(label: L10n.Common.tryAgain) { model.retry() },
            chrome: .row
        )
    }

    private func newSpace() {
        app.router.present(.spaceNew(request: nil))
    }
}

/// "New space" as the last row of the list (RN `NewSpaceRow`): a plus where the space tiles are,
/// so the label lines up with the names above.
private struct HomeNewSpaceRow: View {
    let action: () -> Void

    var body: some View {
        ListRow(action: action, minHeight: 48, accessibilityLabel: L10n.Spaces.newSpace, identifier: "spaces-create-row") {
            Image(glyph: .plus)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .frame(width: 56)
        } content: {
            Text(verbatim: L10n.Spaces.newSpace)
                .textRole(.name)
        }
    }
}

private extension SpacesScreenModel.Placeholder {
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

#Preview("Spaces") {
    ShellPreviewHost { NavigationStack { SpacesScreen() } }
}

#Preview("No spaces yet") {
    ShellPreviewHost(seed: false) { NavigationStack { SpacesScreen() } }
}
