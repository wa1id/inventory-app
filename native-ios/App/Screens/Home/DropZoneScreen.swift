import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// The Drop zone tab: the holding area for things added "somewhere" or photographed with Quick
/// Snap, and the owner's filing queue (RN app/(tabs)/drop-zone.tsx; 06 §7).
///
/// Capturing and filing are separate jobs done at different moments, so this screen makes the
/// second one cheap: "File…" opens the move sheet and the row leaves as soon as it is filed
/// (the move sheet's "Filed in …" toast with Undo is the confirmation); opening a row starts a
/// filing run on the item screen. The list is the shared drop-zone read (`app.dropZone`, also
/// behind the tab badge and Home's card), which the tab shell already drives, so this screen
/// never attaches `.inventoryQuery` to it. "Added just now" ages while the tab is in front.
struct DropZoneScreen: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.isScreenFocused) private var isScreenFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.shellWindowSize) private var windowSize
    @State private var model: DropZoneScreenModel?
    @State private var ticker = NowTicker()
    @State private var scroller = HomeListScroller()

    private let layout = LayoutScale()

    var body: some View {
        ScreenFrame(.tabRoot) {
            if let model {
                content(model)
                    .onChange(of: model.dropZone.readGeneration, initial: true) { _, _ in
                        model.itemsChanged()
                    }
            } else {
                // One frame, until `onAppear` has made the model (an empty body never appears).
                Color.clear
            }
        }
        .nowTicker(ticker)
        .navigationTitle(L10n.DropZone.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { SearchButton(identifier: "drop-zone-search") }
        }
        .onChange(of: app.router.reselections[.dropZone] ?? 0) { _, _ in
            guard isScreenFocused else { return }
            scroller.scrollToTop(animated: !reduceMotion)
        }
        .accessibilityIdentifier("screen-drop-zone")
        .onAppear {
            guard model == nil else { return }
            model = Self.makeModel(app: app)
        }
    }

    /// The screen's model wired to the app: the shared read, the move sheet for a result
    /// through the router, the category memory, and the layout animation (none under Reduce
    /// Motion). Hosted tests build it the same way.
    static func makeModel(app: AppContainer) -> DropZoneScreenModel {
        let router = app.router
        let categories = app.categories
        return DropZoneScreenModel(
            dropZone: app.dropZone,
            openMove: { itemId in
                // No filing run: the list itself is the run.
                await router.presentForResult(MoveResult.self) { .sheet(.move(itemId: itemId, filing: false, request: $0)) }
            },
            rememberCategories: { categories.rememberCategories($0) },
            animate: { change in
                withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: Double(Motion.duration.expand) / 1000)) {
                    change()
                }
            }
        )
    }

    @ViewBuilder
    private func content(_ model: DropZoneScreenModel) -> some View {
        let thumb = CGFloat(thumbSize)
        if let placeholder = model.placeholder {
            HomeFillingState(placement: placeholder.isLoading ? .top : .center, banner: model.showsRefreshBanner ? refreshBanner(model) : nil) {
                switch placeholder {
                case .loading:
                    SkeletonView(variant: .rows, thumb: thumb).padding(.horizontal)
                case .failed(let cause):
                    ErrorStateView(cause: .failed(cause), onRetry: { model.retry() })
                case .allFiled:
                    EmptyStateView(
                        title: L10n.DropZone.EmptyAll.title,
                        message: L10n.DropZone.EmptyAll.body,
                        glyph: .inbox,
                        primary: StateAction(label: L10n.DropZone.EmptyAll.action, glyph: .layers) { app.router.openQuickSnap() },
                        identifier: "drop-zone-empty"
                    )
                }
            }
            .homeListScroller(scroller)
            .refreshable { await model.refresh() }
        } else {
            list(model, thumb: thumb)
        }
    }

    private func list(_ model: DropZoneScreenModel, thumb: CGFloat) -> some View {
        List {
            if let subtitle = model.subtitle {
                // Quick Snap sits under the intro, not beside the title, which it crowded at
                // 360 pt. With nothing waiting, the empty state's primary is the one Quick Snap.
                HomeTitleNote {
                    Text(verbatim: subtitle)
                        .textRole(.meta)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.showsQuickSnap {
                        LoadingButton(label: L10n.DropZone.quickSnap, glyph: .layers, variant: .secondary, size: .small, identifier: "drop-zone-capture") {
                            app.router.openQuickSnap()
                        }
                        .padding(.top, 6)
                    }
                }
            }
            // Offline has the connection banner; anything else is said here, over the old list.
            if model.showsRefreshBanner {
                Section { refreshBanner(model) }
            }
            Section {
                ForEach(model.rows) { item in
                    ItemRow(
                        item: item,
                        line: .added,
                        tool: .file({ Task { await model.file(item.id) } }),
                        now: ticker.now,
                        thumb: thumb,
                        onPress: { app.router.push(.item(id: item.id, filing: true)) }
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .homeListScroller(scroller)
        .refreshable { await model.refresh() }
    }

    private func refreshBanner(_ model: DropZoneScreenModel) -> BannerView {
        BannerView(
            tone: .info,
            message: L10n.Errors.refreshFailed,
            primary: BannerAction(label: L10n.Common.tryAgain) { model.retry() },
            chrome: .row
        )
    }

    /// 76 pt photos where the second line keeps room beside them, else 56 (RN's 390 pt rule).
    private var thumbSize: Int {
        let width = windowSize.width > 0 ? windowSize.width : 393
        return DropZoneScreenModel.thumbSize(windowWidth: width, fontScale: Self.fontScale(dynamicTypeSize), stacked: layout.isStacked)
    }

    /// RN's iOS font scale for a Dynamic Type size (1 at Large; the accessibility sizes stack
    /// anyway).
    static func fontScale(_ size: DynamicTypeSize) -> Double {
        switch size {
        case .xSmall: 0.823
        case .small: 0.882
        case .medium: 0.941
        case .large: 1
        case .xLarge: 1.118
        case .xxLarge: 1.235
        case .xxxLarge: 1.353
        default: 1.786
        }
    }
}

private extension DropZoneScreenModel.Placeholder {
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

#Preview("Waiting") {
    ShellPreviewHost { NavigationStack { DropZoneScreen() } }
}

#Preview("Everything filed") {
    ShellPreviewHost(seed: false) { NavigationStack { DropZoneScreen() } }
}
