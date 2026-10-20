import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// Home: her first screen (RN app/(tabs)/index.tsx; 06 §5). It answers "where is it?" and "do
/// we still have it?" in place, and shows the household at a glance.
///
/// One inset-grouped list under the household's large title: the summary lines, the stale-data
/// banner, the unpaired notice, the drop-zone card and Recently added; typing in the search
/// field (the navigation bar's, always shown) replaces them with results in place. Item rows
/// carry where each thing is and a quantity chip, so most searches end without opening
/// anything. The list is `app.home` (`HomeModel`, kept by the container), grouped into
/// sections by `HomeSections`; this view adds what only a view can do: the keyboard, scrolling,
/// navigation and animation.
///
/// - The search buttons elsewhere (`router.focusSearch()`) land here with the keyboard up: each
///   `searchFocus.focusRequests` bump presents the search field. A re-tap of the Home tab at its
///   root scrolls to the top, or from the top focuses the field.
/// - A chip that opens near the bottom scrolls its row into view, after putting the keyboard
///   away (the stepper would open behind it).
/// - Search stays on Home (U5); there is no search tab.
struct HomeScreen: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.isScreenFocused) private var isScreenFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.haptics) private var haptics

    /// The chip rows' write-through quantity models, one per item shown.
    @State private var quantities: ItemRowQuantityModels?
    /// The search field is active (RN's field focus, which makes the list compact).
    @State private var searchPresented = false
    @FocusState private var searchFieldFocused: Bool
    @State private var scroller = HomeListScroller()
    /// Where the open chip's row is, in window coordinates, for revealing it.
    @State private var expandedFrame = HomeExpandedFrameBox()
    @State private var revealTask: Task<Void, Never>?

    var body: some View {
        let home = app.home
        let sections = HomeSections.sections(home.entries)
        ScreenFrame(.tabRoot) {
            list(home: home, sections: sections)
                .inventoryQuery(home)
        }
        .navigationTitle(home.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    app.router.push(.settings)
                } label: {
                    Label(L10n.Home.settings, glyph: .settings)
                }
                .accessibilityIdentifier("home-settings")
            }
        }
        // The stock field takes no identifier or label of its own: UI tests find it as
        // `app.searchFields.firstMatch`, and VoiceOver reads its prompt.
        .searchable(
            text: Binding(get: { home.query }, set: { setQuery($0) }),
            isPresented: $searchPresented,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(verbatim: L10n.Home.searchPlaceholder)
        )
        .searchFocused($searchFieldFocused)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onSubmit(of: .search) {
            // The summary is said now, or when the results land; the field lets go.
            home.submitSearch()
            searchFieldFocused = false
        }
        // Initial too: `app.home` outlives this view (replaying onboarding makes a new Home over
        // the same model), so a field left focused by the last Home must not keep this one
        // compact with no search showing.
        .onChange(of: searchPresented, initial: true) { _, presented in
            withAnimation(layoutAnimation) { home.setFieldFocused(presented) }
        }
        .onChange(of: app.router.searchFocus.focusRequests) { _, _ in
            focusSearchField()
        }
        .onChange(of: app.router.reselections[.home] ?? 0) { _, _ in
            reselected()
        }
        .onChange(of: HomeSections.itemIds(sections)) { _, ids in
            quantities?.keep(only: ids)
        }
        .background {
            HomeTransitionProbe(isWaiting: app.router.searchFocus.isWaitingForTransition) {
                app.router.searchFocus.transitionEnded()
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        // One container takes the screen's identifier, so the list keeps its own (`home-list`).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen-home")
        #if DEBUG
        // After the screen's identifier, which would otherwise replace this one.
        .overlay(alignment: .bottomLeading) { HomeDebugReselections(count: app.router.reselections[.home] ?? 0) }
        #endif
        .onAppear {
            if quantities == nil { quantities = app.makeRowQuantityModels() }
        }
    }

    // MARK: The list

    private func list(home: HomeModel, sections: [HomeSections.Section]) -> some View {
        List {
            if !home.isCompact {
                HomeTitleNote {
                    HomeSummaryLines(summary: home.summaryLine, whereLine: home.whereLine, paired: home.paired, reconnecting: home.reconnecting)
                }
            }
            ForEach(sections) { section in
                self.section(section, home: home)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("home-list")
        .homeListScroller(scroller)
        .refreshable { await home.refresh() }
        .onChange(of: home.scrollToTopRequests) { _, _ in
            // Results start at the top, not wherever Recently added was scrolled to.
            scroller.scrollToTop(animated: false)
        }
    }

    @ViewBuilder
    private func section(_ section: HomeSections.Section, home: HomeModel) -> some View {
        switch section.kind {
        case .refreshFailed:
            Section {
                BannerView(
                    tone: .info,
                    message: L10n.Errors.refreshFailed,
                    primary: BannerAction(label: L10n.Common.tryAgain) { home.retry() },
                    chrome: .row
                )
            }
            .modifier(HomeOlderResults(dimmed: home.dim))
        case .notice:
            Section {
                // Part of the page rather than news: read in order, not announced.
                BannerView(
                    tone: .info,
                    glyph: .phone,
                    title: L10n.Home.Unpaired.title,
                    message: L10n.Home.Unpaired.body,
                    primary: BannerAction(label: L10n.Home.Unpaired.join, identifier: "unpaired-join") {
                        app.router.push(.household)
                    },
                    secondary: BannerAction(label: L10n.Common.notNow, accessibilityHint: L10n.Home.Unpaired.notNowHint) {
                        home.dismissNotice()
                    },
                    live: .off,
                    chrome: .row
                )
            }
        case .dropZone:
            Section {
                HomeDropZoneCard(
                    items: home.dropZone.items,
                    count: home.dropZone.count,
                    onSort: { app.router.goToTab(.dropZone) },
                    onQuickSnap: { app.router.openQuickSnap() }
                )
            }
        case .status(let status):
            statusSection(status, home: home)
        case .rows:
            Section {
                ForEach(section.rows) { row in
                    self.row(row, home: home)
                        .modifier(HomeOlderResults(dimmed: home.dim))
                }
            } header: {
                if section.title != nil || section.summary != nil || !section.totals.isEmpty {
                    HomeSectionHeader(summary: section.summary, title: section.title, count: section.count, totals: section.totals)
                        .modifier(HomeOlderResults(dimmed: home.dim))
                }
            } footer: {
                if section.showsMore {
                    LoadingButton(
                        label: L10n.Common.showMore,
                        variant: .quiet,
                        accessibilityLabel: L10n.Home.recentMoreA11y,
                        identifier: "recent-more"
                    ) {
                        home.showMore()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ row: HomeSections.Row, home: HomeModel) -> some View {
        switch row {
        case .item(_, let item):
            ItemRow(
                item: item,
                line: .where,
                tool: chip(for: item, home: home),
                terms: home.highlightTerms,
                onPress: { openItem(item.id) }
            )
            .modifier(HomeExpandedFrame(isExpanded: home.expandedId == item.id, box: expandedFrame))
        case .place(_, let hit):
            PlaceRow(
                hit: hit,
                spaces: home.spacesById,
                containers: home.containersById,
                terms: home.search.results?.terms ?? [],
                onPress: { openPlace(hit) }
            )
        }
    }

    private func chip(for item: ItemWithContext, home: HomeModel) -> ItemRow.Tool {
        guard let quantities else { return .none }
        return .chip(quantities.model(for: item), isExpanded: home.expandedId == item.id) {
            toggleExpand(item.id, home: home)
        }
    }

    // MARK: States

    @ViewBuilder
    private func statusSection(_ status: HomeList.Status, home: HomeModel) -> some View {
        Section {
            switch status {
            case .loading:
                SkeletonView(variant: .list, rows: 4)
                    .homeStateRow()
            case .searching:
                if home.searchSkeletonVisible {
                    SkeletonView(variant: .rows, rows: 5)
                        .homeStateRow()
                }
            case .error:
                if home.overviewWaitingForServer {
                    // The connection banner already says the home server is not answering and
                    // offers the one Try again; the list fills in once it answers.
                    Text(verbatim: L10n.Home.waitingForServer)
                        .textRole(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("home-waiting")
                        .homeStateRow()
                } else if let cause = home.overviewCause {
                    // Never an empty list: a failed read must not look like "you own nothing".
                    ErrorStateView(cause: .failed(cause), onRetry: { home.reloadOverview() }, identifier: "home-error")
                        .homeStateRow()
                }
            case .searchFailed:
                if let cause = home.search.cause {
                    ErrorStateView(cause: .failed(cause), title: home.searchFailedCopy?.title, onRetry: { home.search.retry() })
                        .homeStateRow()
                }
            case .noResults:
                EmptyStateView(
                    title: L10n.Search.None.title(query: home.trimmedQuery),
                    message: L10n.Search.None.body,
                    glyph: .search,
                    secondary: StateAction(label: L10n.Search.None.add(query: home.trimmedQuery), glyph: .plus, identifier: "search-add-missing") {
                        app.router.present(.addItem(AddParams(name: home.trimmedQuery)))
                    }
                )
                .homeStateRow()
            case .empty:
                emptyState(home: home)
                    .homeStateRow()
            }
        }
    }

    @ViewBuilder
    private func emptyState(home: HomeModel) -> some View {
        if home.paired {
            EmptyStateView(
                title: L10n.Home.Empty.Paired.titleIn(household: home.title),
                message: L10n.Home.Empty.Paired.body,
                primary: StateAction(label: L10n.Home.Empty.Paired.add, glyph: .plus) { addItem() },
                identifier: "home-empty"
            )
        } else if home.startHere {
            EmptyStateView(
                title: L10n.Home.Empty.Unpaired.title,
                message: L10n.Home.Empty.Unpaired.body,
                primary: StateAction(label: L10n.Home.Empty.Unpaired.join) { app.router.push(.household) },
                secondary: StateAction(label: L10n.Home.Empty.Unpaired.start) { app.router.present(.spaceNew(request: nil)) },
                identifier: "home-empty"
            )
        } else {
            EmptyStateView(
                title: L10n.Home.Empty.Local.title,
                message: L10n.Home.Empty.Local.body,
                primary: StateAction(label: L10n.Home.Empty.Local.add, glyph: .plus) { addItem() },
                identifier: "home-empty"
            )
        }
    }

    // MARK: Actions

    private var layoutAnimation: Animation? {
        HomeLayoutMotion.animation(reduceMotion: reduceMotion)
    }

    private func setQuery(_ text: String) {
        let home = app.home
        let previous = home.query
        home.setQuery(text)
        // The field's clear button (RN played `choice`); not Cancel, which closes the search.
        if HomeSearchFieldRules.isClear(from: previous, to: text) {
            Task { @MainActor in
                await Task.yield()
                if searchPresented { haptics(.choice) }
            }
        }
    }

    /// Opening a result puts the keyboard away; the query stays for the way back.
    private func openItem(_ id: String) {
        searchFieldFocused = false
        app.router.push(.item(id: id, filing: false))
    }

    /// The drop zone's records go to the Drop zone tab, never to their own screens.
    private func openPlace(_ hit: LocationSearchResult) {
        searchFieldFocused = false
        if hit.kind == .space {
            app.router.openSpace(hit.id)
        } else {
            app.router.openContainer(hit.id)
        }
    }

    private func addItem() {
        app.router.present(.addItem(AddParams()))
    }

    /// The keyboard up in the search field: present the search, or focus the field it shows.
    private func focusSearchField() {
        if searchPresented {
            searchFieldFocused = true
        } else {
            searchPresented = true
        }
    }

    /// Re-tapping Home at its root: back to the top, and from the top into the field.
    private func reselected() {
        guard isScreenFocused else { return }
        if scroller.isScrolledDown {
            scroller.scrollToTop(animated: !reduceMotion)
        } else {
            focusSearchField()
        }
    }

    /// One open chip at a time. The keyboard goes first, since the stepper would open behind it;
    /// once the row has its new height, a row not entirely on screen scrolls up just enough to
    /// show the stepper, Done and 12 pt below them (RN `revealExpanded`).
    private func toggleExpand(_ id: String, home: HomeModel) {
        searchFieldFocused = false
        let opening = home.expandedId != id
        expandedFrame.rect = nil
        home.toggleExpand(id)
        revealTask?.cancel()
        guard opening else { return }
        revealTask = Task { @MainActor in
            // The row's new height, and the keyboard out of the way.
            try? await Task.sleep(for: .milliseconds(Motion.duration.expand + 220))
            guard !Task.isCancelled, home.expandedId == id, let frame = expandedFrame.rect else { return }
            scroller.reveal(frame, margin: 12, animated: !reduceMotion)
        }
    }
}

/// Where the open chip's row is: a plain box, so the frame changing as the list scrolls never
/// redraws the screen.
@MainActor
private final class HomeExpandedFrameBox {
    var rect: CGRect?
}

/// Reports where a row is while its chip is open (every row keeps the same modifier, so opening
/// a chip never remakes its row).
private struct HomeExpandedFrame: ViewModifier {
    let isExpanded: Bool
    let box: HomeExpandedFrameBox

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
            if isExpanded { box.rect = rect }
        }
    }
}

/// Results for the previous query stay for continuity while the new one runs, at half
/// opacity, never tappable and hidden from VoiceOver (RN app/(tabs)/index.tsx:697-713). The
/// modifier is always there, so dimming never remakes a row.
private struct HomeOlderResults: ViewModifier {
    let dimmed: Bool

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.5 : 1)
            .allowsHitTesting(!dimmed)
            .accessibilityHidden(dimmed)
    }
}

#if DEBUG
/// For the shell's UI tests (ShellModalUITests): how many re-taps of Home reached the screen.
/// Demo mode only, two points square and just off the left edge of the window, so screenshots
/// never show it and the accessibility audits, which look only at what is on screen, never take
/// it for text someone has to read (UI tests still find it by its identifier).
private struct HomeDebugReselections: View {
    let count: Int

    var body: some View {
        if UserDefaults.standard.bool(forKey: "demo") {
            // Clear text rather than a clear shape: an invisible shape is not an element.
            Text(verbatim: "\(count)")
                .font(.system(size: 2))
                .foregroundStyle(.clear)
                .frame(width: 2, height: 2)
                .offset(x: -40)
                .allowsHitTesting(false)
                .accessibilityIdentifier("debug-home-reselections")
        }
    }
}

#Preview("Overview") {
    ShellPreviewHost { NavigationStack { HomeScreen() } }
}

#Preview("Searching") {
    ShellPreviewHost { NavigationStack { HomeScreen().homePreviewQuery("tool") } }
}

#Preview("No results") {
    ShellPreviewHost { NavigationStack { HomeScreen().homePreviewQuery("zebra") } }
}

#Preview("Empty, not joined") {
    ShellPreviewHost(seed: false) { NavigationStack { HomeScreen() } }
}

extension View {
    /// Types `query` into Home's search once the preview's container is up.
    func homePreviewQuery(_ query: String) -> some View {
        modifier(HomePreviewQuery(query: query))
    }
}

private struct HomePreviewQuery: ViewModifier {
    let query: String
    @Environment(AppContainer.self) private var app

    func body(content: Content) -> some View {
        content.task { app.home.setQuery(query) }
    }
}
#endif
