import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Inventory
import InventoryAppModels
import InventoryCore
import InventoryStorage

/// The shell on an iPad (DECISIONS U4): the top tab bar and the sidebar (Add's long press, the
/// tape badge), the readable column, a narrow window (Split View, Slide Over), the end of a pop
/// answering a search-focus request, and the scene phase a hosted window sees. The iPad-only
/// tests run with `DEVICE=ipad scripts/mac.sh apptest`.
@Suite("Shell on iPad (hosted)", .serialized)
@MainActor
struct ShellIPadTests {
    static func isPad() -> Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private func tabBarController(in host: ShellTestWindow) async throws -> UITabBarController {
        var controller: UITabBarController?
        await ShellTestWait.until("the tab bar controller") {
            controller = ShellTabBarCoordinator.tabBarController(in: host.window.rootViewController)
            return controller != nil
        }
        return try #require(controller)
    }

    /// The labels showing the badge `text` in the Drop zone items of the tab bar controller's
    /// chrome that are on screen.
    private func badgeLabels(_ text: String, in controller: UITabBarController) -> [UILabel] {
        ShellTabBarCoordinator.tabChromeViews(in: controller).flatMap { view in
            ShellTabBarCoordinator.itemViews(titled: AppTab.dropZone.title, in: view)
                .filter(ShellTabBarCoordinator.isShowing)
                .flatMap { ShellTapeBadge.labels(in: $0).filter { $0.text == text } }
        }
    }

    private func isTape(_ label: UILabel) -> Bool {
        guard label.textColor == ShellTabBarCoordinator.tapeInk, let badge = label.superview else { return false }
        return badge.backgroundColor == ShellTabBarCoordinator.tape
            || badge.subviews.contains { $0 is ShellTapeBadgeBackdrop && $0.backgroundColor == ShellTabBarCoordinator.tape }
    }

    @Test("the top tab bar: Add takes the long press, the Drop zone badge is tape with ink text, no bottom chrome", .enabled("iPad only") { await ShellIPadTests.isPad() })
    func floatingTabBar() async throws {
        let app = AppContainer.preview()
        await app.boot.run()
        let chrome = ShellTabBarChrome()
        let host = try ShellTestWindow(MainShell().shellEnvironment(app).environment(\.shellTabBarChrome, chrome))
        defer { host.close() }
        let controller = try await tabBarController(in: host)
        #expect(controller.traitCollection.horizontalSizeClass == .regular)
        await ShellTestWait.until("the badge drawn as tape") {
            let labels = badgeLabels("4", in: controller)
            return !labels.isEmpty && labels.allSatisfy(isTape)
        }
        // The bottom bar is not on screen; Add is the top bar's item.
        #expect(controller.tabBar.window == nil)
        let frames = ShellTabBarCoordinator.addItemFrames(in: controller)
        #expect(frames.count == 1)
        #expect((frames.first?.maxY ?? .infinity) < 120)
        #expect(controller.view.gestureRecognizers?.contains { ($0 as? UILongPressGestureRecognizer)?.minimumPressDuration == 0.35 } == true)
        // Nothing along the bottom edge: the toast keeps to the safe area.
        try await Task.sleep(for: .milliseconds(300))
        #expect(chrome.height == nil)

        // Selecting another tab redraws the bar's items: the badge stays tape.
        app.router.selectTab(.spaces)
        try await Task.sleep(for: .milliseconds(600))
        let labels = badgeLabels("4", in: controller)
        #expect(!labels.isEmpty)
        #expect(labels.allSatisfy(isTape))

        // Over the Scan tab's camera the top bar draws dark, and gives it back afterwards.
        func isDark() -> Bool {
            ShellTabBarCoordinator.tabChromeViews(in: controller).contains { $0.overrideUserInterfaceStyle == .dark }
        }
        app.router.selectTab(.scan)
        await ShellTestWait.until("the dark top bar") { isDark() }
        app.router.selectTab(.home)
        await ShellTestWait.until("the top bar's own style") { !isDark() }
    }

    @Test("the sidebar: the Add row takes the long press and the Drop zone count sits on tape", .enabled("iPad only") { await ShellIPadTests.isPad() })
    func sidebar() async throws {
        let app = AppContainer.preview()
        await app.boot.run()
        let host = try ShellTestWindow(MainShell().shellEnvironment(app))
        defer { host.close() }
        let controller = try await tabBarController(in: host)
        await ShellTestWait.until("the badge") { app.dropZone.count == 4 }
        controller.sidebar.isHidden = false
        await ShellTestWait.until("the sidebar's count drawn on tape") {
            let labels = badgeLabels("4", in: controller)
            return !labels.isEmpty && labels.allSatisfy(isTape)
        }
        let frames = ShellTabBarCoordinator.addItemFrames(in: controller)
        #expect(frames.count == 1)
        // A row of the sidebar, along the leading edge.
        #expect((frames.first?.minX ?? .infinity) < 100)
        #expect((frames.first?.width ?? 0) > 150)
        // The window closes with the sidebar open: hiding it first would leave its animation
        // running in a window that is gone, which UIKit refuses (a targeted preview off-window).
    }

    @Test("the readable column: a wide stack's large title and rows line up on a centred 640 pt column", .enabled("iPad only") { await ShellIPadTests.isPad() })
    func readableColumn() async throws {
        let app = AppContainer.preview()
        await app.boot.run()
        let host = try ShellTestWindow(MainShell().shellEnvironment(app))
        defer { host.close() }
        _ = try await tabBarController(in: host)
        let width = host.window.bounds.width
        let inset = ShellReadableColumn.inset(forWidth: width)
        #expect(inset == ((width - 640) / 2).rounded(.down))
        var navigation: UINavigationController?
        await ShellTestWait.until("Home's bar on the column") {
            navigation = host.window.shellDescendants.lazy.compactMap { $0.next as? UINavigationController }.first
            guard let navigation else { return false }
            return navigation.navigationBar.directionalLayoutMargins.leading == navigation.systemMinimumLayoutMargins.leading + inset
        }
        let bar = try #require(navigation?.navigationBar)
        #expect(bar.directionalLayoutMargins.trailing == (navigation?.systemMinimumLayoutMargins.trailing ?? 0) + inset)
        // The list spans the window (it scrolls from anywhere); its rows keep to the column.
        let list = try #require(navigation?.view.shellDescendants.compactMap { $0 as? UICollectionView }.first { $0.bounds.width >= width - 1 })
        await ShellTestWait.until("the rows") { !list.visibleCells.isEmpty }
        for cell in list.visibleCells {
            let frame = cell.convert(cell.bounds, to: host.window)
            #expect(frame.minX >= inset - 0.5)
            #expect(frame.maxX <= width - inset + 0.5)
        }
    }

    @Test("a narrow window (Split View, Slide Over) gets the bottom tab bar, the toast chrome and no column")
    func narrowWindow() async throws {
        let app = AppContainer.preview()
        await app.boot.run()
        let chrome = ShellTabBarChrome()
        let host = try ShellTestWindow(
            MainShell().shellEnvironment(app).environment(\.shellTabBarChrome, chrome),
            size: CGSize(width: 320, height: 900),
            horizontalSizeClass: .compact
        )
        defer { host.close() }
        let controller = try await tabBarController(in: host)
        await ShellTestWait.until("the bottom bar") { controller.tabBar.window != nil && ShellTabBarCoordinator.isShowing(controller.tabBar) }
        #expect(controller.tabBar.items?.map(\.title) == AppTab.allCases.map(\.title))
        let frames = ShellTabBarCoordinator.addItemFrames(in: controller)
        #expect(frames.count >= 1)
        let barFrame = controller.tabBar.convert(controller.tabBar.bounds, to: controller.view)
        #expect(frames.allSatisfy { barFrame.insetBy(dx: -1, dy: -1).contains($0) })
        await ShellTestWait.until("the toast chrome") { chrome.height != nil }
        #expect(ShellReadableColumn.inset(forWidth: 320) == 0)
        // The bar's margins are the system's: no column at this width.
        let navigation = host.window.shellDescendants.lazy.compactMap { $0.next as? UINavigationController }.first
        if let navigation {
            #expect(navigation.navigationBar.directionalLayoutMargins.leading <= navigation.systemMinimumLayoutMargins.leading + 0.5)
        }
        // The components stack at this width (LayoutScale's rule, 08 §9.2 (14)).
        #expect(LayoutScale.isStacked(dynamicTypeSize: .large, windowWidth: 320))
    }

    @Test("a pop on a tab's stack answers a search-focus request waiting for it, with no fallback")
    func popEndAnswersSearchFocus() async throws {
        let directory = URL.temporaryDirectory.appending(path: "shell-ipad-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The fallback never fires on this clock, and there is no Home screen (with its own probe):
        // only the stack's report of the pop's end can answer.
        let app = AppContainer.test(
            resolver: PhotoPathResolver(
                documents: directory.appending(path: "Documents", directoryHint: .isDirectory),
                caches: directory.appending(path: "Caches", directoryHint: .isDirectory)),
            preferences: InMemoryPreferences([PreferenceKey.onboardingCompleted: "true"]),
            clock: ShellFrozenClock())
        await app.boot.run()
        let host = try ShellTestWindow(ShellTabStack(tab: .home) { Color.clear }.shellEnvironment(app))
        defer { host.close() }
        app.router.push(.settings)
        try await Task.sleep(for: .milliseconds(900))
        let before = app.router.searchFocus.focusRequests

        app.router.focusSearch()
        // MainShell reports Home's focus; here the test does.
        app.router.searchFocus.homeFocusChanged(true)
        #expect(app.router.searchFocus.isWaitingForTransition)
        await ShellTestWait.until("the field focused after the pop", timeout: .seconds(3)) {
            app.router.searchFocus.focusRequests == before + 1
        }
        #expect(!app.router.searchFocus.isWaitingForTransition)
    }

    @Test("a hosted window reports the scene's real phase, not background")
    func hostedScenePhase() async throws {
        let box = ShellPhaseBox()
        let host = try ShellTestWindow(ShellPhaseReader(box: box))
        defer { host.close() }
        await ShellTestWait.until("the phase") { box.phase != nil }
        // Active on an iPhone; the iPad simulator can keep the test host's scene inactive.
        let scene = try #require(host.window.windowScene)
        #expect(box.phase == ShellTestScenePhase.phase(of: scene.activationState))
        #expect(box.phase != .background)
    }
}

/// A clock whose sleeps never end (the search focus's fallback never fires).
struct ShellFrozenClock: Clock {
    typealias Instant = ContinuousClock.Instant

    var now: Instant { ContinuousClock.now }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try await Task.sleep(for: .seconds(3600))
    }
}

@MainActor
final class ShellPhaseBox {
    var phase: ScenePhase?
}

private struct ShellPhaseReader: View {
    let box: ShellPhaseBox
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Color.clear
            .onAppear { box.phase = phase }
            .onChange(of: phase) { _, phase in box.phase = phase }
    }
}
