import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

extension QuickSnapReviewModel: ShellFocusDriven {}

/// The end of a Quick Snap set (RN `app/capture/review.tsx`, 05 §6): what it saved, what still
/// needs a name, and the way back. Pushed inside the camera's cover, title "Review", no back
/// button; the edge swipe still goes back to where the set started, without `fast_review_done`
/// or the Done toast (05 §3, Q13; `CaptureNavigator` closes the camera under it).
///
/// The rows are a filtered read of the container, re-read when the screen comes into focus, on
/// every write while it is in front (a pipeline landing) and on pull to refresh, so late
/// recognition results appear live. `QuickSnapReviewNavigator` maps the model's exits onto the
/// router: Done closes the cover, Keep shooting and Try again replace it with a new camera, a
/// row pushes the item screen, the toast's View goes to the Drop zone tab.
struct QuickSnapReviewScreen: View {
    let route: QuickSnapReviewRoute

    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: QuickSnapReviewModel?

    init(route: QuickSnapReviewRoute) {
        self.route = route
    }

    var body: some View {
        ScreenFrame(.detail) {
            if let model {
                content(model)
                    .inventoryQuery(model)
            } else {
                // Something to appear: an empty frame never does, so the model would never be made.
                Color.clear
            }
        } bottomBar: {
            BottomBar {
                LoadingButton(label: L10n.Review.keepShooting, variant: .secondary, fullWidth: true, identifier: "fast-review-more") {
                    model?.keepShooting()
                }
            } primary: {
                LoadingButton(label: L10n.Review.done, fullWidth: true, identifier: "fast-review-done") {
                    model?.done()
                }
            }
        }
        .navigationTitle(L10n.Review.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .background {
            QuickSnapReviewSwipeBack()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        // A container carries the screen's id; on the bare tree it would replace the buttons'.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen-review")
        .onAppear(perform: build)
    }

    @ViewBuilder
    private func content(_ model: QuickSnapReviewModel) -> some View {
        switch model.placeholder {
        case .none, .skeleton:
            list(model)
        case .error(let cause):
            fullScreen(model) {
                ErrorStateView(cause: .failed(cause), onRetry: { Task { await model.reload() } })
            }
        case .emptied:
            fullScreen(model) {
                EmptyStateView(
                    title: L10n.Review.Emptied.title,
                    message: L10n.Review.Emptied.body
                )
            }
        case .nothing:
            fullScreen(model) {
                EmptyStateView(
                    title: L10n.Review.Nothing.title,
                    message: L10n.Review.Nothing.body,
                    glyph: .camera,
                    primary: StateAction(label: L10n.Review.Nothing.action, glyph: .camera, identifier: "fast-review-try-again") {
                        model.tryAgain()
                    }
                )
            }
        }
    }

    /// The header, the refresh banner and the rows, or the rows' shape while photos are still on
    /// their way.
    private func list(_ model: QuickSnapReviewModel) -> some View {
        let rows = model.list
        return List {
            if model.showsHeader {
                // A clear row rather than a section header, whose style greys the title.
                Section {
                    QuickSnapReviewHead(title: model.title, status: model.statusText, isAlert: model.status == .maybeLost)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                }
            }
            if model.showsRefreshBanner {
                Section {
                    refreshBanner(model)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if rows.isEmpty, case .skeleton(let count) = model.placeholder {
                Section {
                    SkeletonView(variant: .rows, rows: count, thumb: DesignMetrics.thumbPhoto)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(rows, id: \.id) { item in
                        ItemRow(
                            item: item,
                            line: .detail,
                            tool: .delete { Task { await model.delete(item.id) } },
                            thumb: DesignMetrics.thumbPhoto
                        ) {
                            model.openItem(item.id)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .refreshable { await model.refresh() }
        .animation(reduceMotion ? nil : .easeInOut(duration: Double(Motion.duration.expand) / 1000), value: rows.map(\.id))
    }

    /// A state that fills the screen: centred while it fits, scrolling at the largest sizes, and
    /// pulled to refresh like the list.
    private func fullScreen(_ model: QuickSnapReviewModel, @ViewBuilder state makeState: () -> some View) -> some View {
        let state = makeState()
        return GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    if model.showsRefreshBanner {
                        refreshBanner(model)
                            .padding(.horizontal, 16)
                    }
                    state
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .refreshable { await model.refresh() }
        }
    }

    /// Over stale rows when a refresh failed for any reason but the connection's own (RN
    /// `needsRefreshBanner`).
    private func refreshBanner(_ model: QuickSnapReviewModel) -> some View {
        BannerView(
            tone: .info,
            message: L10n.Errors.refreshFailed,
            primary: BannerAction(label: L10n.Common.tryAgain, identifier: "fast-review-refresh-retry") {
                Task { await model.reload() }
            },
            identifier: "fast-review-refresh-failed"
        )
    }

    private func build() {
        guard model == nil else { return }
        let router = app.router
        let navigator = address.map { QuickSnapReviewNavigator(router: router, address: $0) }
        let household = app.household
        model = QuickSnapReviewModel(
            route: route,
            items: app.repositories.items,
            photos: app.imageStore,
            isPaired: { household.session != nil },
            invalidator: app.database,
            toasts: app.toasts,
            confirm: app.platform.confirm,
            haptics: app.platform.haptics,
            telemetry: app.telemetry,
            clock: app.clock,
            navigate: { navigator?.navigate($0) }
        )
    }
}

/// "4 saved to the drop zone" over "Saving 2 more…" (RN review head): the title is a heading;
/// the status line is read out whenever it changes (RN: a polite live region), in the signal
/// colour once photos may have been lost.
private struct QuickSnapReviewHead: View {
    let title: String?
    let status: String
    let isAlert: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(verbatim: title)
                    .textRole(.title, header: true)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("fast-review-title")
            }
            Text(verbatim: status)
                .textRole(.meta)
                .foregroundStyle(isAlert ? DesignColor.signal : Color.secondary)
                .accessibilityIdentifier("fast-review-status")
                .announcesOnChange(status, queued: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

/// Keeps the iOS edge swipe on the review, whose back button is hidden (RN set only
/// `headerBackVisible: false`, so the swipe worked; SwiftUI turns it off with the button, 05 Q13).
///
/// While the review is in front it answers the navigation controller's pop gesture itself, and
/// hands it back to the controller's own delegate as soon as the review is covered or leaves.
struct QuickSnapReviewSwipeBack: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var navigation: UINavigationController?
        private weak var previousDelegate: (any UIGestureRecognizerDelegate)?
        private var isAnswering = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let navigation = navigationController, let pop = navigation.interactivePopGestureRecognizer else { return }
            self.navigation = navigation
            if !isAnswering {
                previousDelegate = pop.delegate
                pop.delegate = self
                isAnswering = true
            }
            pop.isEnabled = true
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            handBack()
        }

        private func handBack() {
            guard isAnswering else { return }
            isAnswering = false
            if let pop = navigation?.interactivePopGestureRecognizer, pop.delegate === self {
                pop.delegate = previousDelegate
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigation?.viewControllers.count ?? 0) > 1
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}

#if DEBUG
#Preview("Shots arriving") {
    ShellPreviewHost {
        NavigationStack {
            QuickSnapReviewScreen(route: QuickSnapReviewRoute(containerId: DropZone.containerId, since: 0, expected: 6))
        }
    }
}

#Preview("All landed") {
    ShellPreviewHost {
        NavigationStack {
            QuickSnapReviewScreen(route: QuickSnapReviewRoute(containerId: DropZone.containerId, since: 0, expected: 2))
        }
    }
}

#Preview("Saving the first photo") {
    ShellPreviewHost(seed: false) {
        NavigationStack {
            QuickSnapReviewScreen(route: QuickSnapReviewRoute(containerId: DropZone.containerId, since: 0, expected: 2))
        }
    }
}

#Preview("Nothing saved") {
    ShellPreviewHost(seed: false) {
        NavigationStack {
            QuickSnapReviewScreen(route: QuickSnapReviewRoute(containerId: DropZone.containerId, since: 0, expected: 0))
        }
    }
}
#endif
