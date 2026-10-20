import SwiftUI
import InventoryAppModels
import InventoryStrings

/// The tabs: Home · Spaces · [Add] · Scan · Drop zone (RN app/(tabs)/_layout.tsx + TabBar.tsx;
/// 06 §4, DECISIONS U4, U5).
///
/// - Each destination tab has its own navigation stack bound to the router.
/// - Add is a tab the selection binding refuses: tapping it plays `tap` and presents the Add sheet
///   without switching tabs; a 350 ms long press opens Quick Snap (``ShellTabBarBridge``).
/// - Selecting the selected tab again sends its re-tap signal (`Router.reselections`).
/// - Home's focus feeds `Router.searchFocus`, so a search button elsewhere ends in one
///   `focusRequests` bump once Home is in front.
/// - The Drop zone badge counts what waits there (none at 0 or before the first read, "99+" above
///   99), drawn as yellow tape: waiting is not an alarm.
/// - Sidebar-adaptable, for iPad (U4). Sheets and covers come from the router's modal stack.
/// - The shared drop-zone read follows the tab shell's focus: in front unless something is
///   presented over it.
struct MainShell: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.shellTabBarChrome) private var tabBarChrome

    var body: some View {
        let router = app.router
        let dropZone = app.dropZone
        let waiting = dropZone.loading ? 0 : dropZone.count
        TabView(selection: Binding(get: { router.selectedTab }, set: { router.selectTab($0) })) {
            Tab(value: AppTab.home) {
                ShellTabStack(tab: .home) { HomeScreen() }
            } label: {
                ShellTabLabel(tab: .home)
            }
            Tab(value: AppTab.spaces) {
                ShellTabStack(tab: .spaces) { SpacesScreen() }
            } label: {
                ShellTabLabel(tab: .spaces)
            }
            Tab(value: AppTab.add) {
                // Never shown: selecting Add presents the Add sheet instead.
                Color.clear
            } label: {
                // RN TabBar.tsx:183-189: "Add an item", the long-press hint, and Quick Snap as a
                // custom action (with the long press's haptic).
                ShellTabLabel(tab: .add)
                    .accessibilityHint(L10n.Tabs.addHint)
                    .accessibilityAction(named: L10n.Tabs.quickSnapAction) { router.addLongPressed() }
            }
            Tab(value: AppTab.scan) {
                ShellTabStack(tab: .scan) { ScanScreen() }
            } label: {
                ShellTabLabel(tab: .scan)
            }
            Tab(value: AppTab.dropZone) {
                ShellTabStack(tab: .dropZone) { DropZoneScreen() }
            } label: {
                ShellTabLabel(tab: .dropZone, waiting: waiting)
            }
            .badge(AppTab.badgeText(waiting: waiting).map { Text($0) })
        }
        .tabViewStyle(.sidebarAdaptable)
        .background {
            ShellTabBarBridge(app: app, chrome: tabBarChrome, waiting: waiting, shellFocused: router.isTabShellFocused)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .modifier(ShellModalPresentation(level: 0))
        .onChange(of: router.isTabShellFocused, initial: true) { _, focused in
            dropZone.focusChanged(focused, revision: app.database.revision)
        }
        // A search button elsewhere asked for Home's field: Home takes the request when it comes
        // to the front and raises `searchFocus.focusRequests` once the transition is over.
        .onChange(of: router.isFocused(.tabRoot(.home)), initial: true) { _, focused in
            router.searchFocus.homeFocusChanged(focused)
        }
        .onChange(of: app.database.revision) { _, revision in
            dropZone.revisionChanged(revision)
        }
        // Replaying onboarding takes the tabs away (RN unmounted DropZoneProvider): the shared
        // read stops following writes until they are back.
        .onDisappear { dropZone.focusChanged(false) }
        .onAppear { dropZone.focusChanged(router.isTabShellFocused, revision: app.database.revision) }
    }
}

/// A tab's label: its title and symbol, RN's VoiceOver label ("Add an item", "Drop zone, 3
/// waiting") and RN's testID as the accessibility identifier.
private struct ShellTabLabel: View {
    let tab: AppTab
    var waiting = 0

    var body: some View {
        Label(tab.title, systemImage: tab.systemImage)
            .accessibilityLabel(tab.accessibilityLabel(waiting: waiting))
            .accessibilityIdentifier(tab.accessibilityIdentifier)
    }
}

#if DEBUG
// DEBUG only (previews, the demo, tests): kept out of Release builds.
#Preview("Main shell") {
    ShellPreviewHost {
        MainShell()
    }
}
#endif
