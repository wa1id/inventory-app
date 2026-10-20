import SwiftUI
import Testing
import UIKit
@testable import Inventory
import InventoryAppModels

@Suite("Main shell tab bar (hosted)", .serialized)
@MainActor
struct ShellTabBarTests {
    @Test("the bar TabView builds has five items in RN's order, an Add button the bridge can find, and the tape badge")
    func tabBar() async throws {
        let app = AppContainer.preview()
        await app.boot.run()
        let tabBarChrome = ShellTabBarChrome()
        // A phone-sized compact window, so an iPad shows the bottom bar too.
        let host = try ShellTestWindow(
            MainShell().shellEnvironment(app).environment(\.shellTabBarChrome, tabBarChrome),
            size: CGSize(width: 402, height: 874),
            horizontalSizeClass: .compact
        )
        defer { host.close() }

        var controller: UITabBarController?
        await ShellTestWait.until("the tab bar controller") {
            controller = ShellTabBarCoordinator.tabBarController(in: host.window.rootViewController)
            return controller != nil
        }
        let tabBar = try #require(controller?.tabBar)
        await ShellTestWait.until("the badge") { app.dropZone.count == 4 }
        try await Task.sleep(for: .milliseconds(500))

        #expect(tabBar.items?.map(\.title) == AppTab.allCases.map(\.title))
        let buttons = ShellTabBarCoordinator.itemButtons(in: tabBar)
        let add = try #require(buttons[.add])
        let center = add.convert(CGPoint(x: add.bounds.midX, y: add.bounds.midY), to: tabBar)
        #expect(ShellTabBarCoordinator.isOnAddItem(center, in: tabBar))
        if let home = buttons[.home] {
            let homeCenter = home.convert(CGPoint(x: home.bounds.midX, y: home.bounds.midY), to: tabBar)
            #expect(!ShellTabBarCoordinator.isOnAddItem(homeCenter, in: tabBar))
        }
        #expect(tabBar.items?.last?.badgeValue == "4")
        #expect(tabBar.items?.map(\.accessibilityIdentifier) == AppTab.allCases.map(\.accessibilityIdentifier))
        // The long press sits on the tab bar controller's view and takes touches on Add only.
        let tabs = try #require(controller)
        #expect(tabs.view.gestureRecognizers?.contains { ($0 as? UILongPressGestureRecognizer)?.minimumPressDuration == 0.35 } == true)
        let addFrames = ShellTabBarCoordinator.addItemFrames(in: tabs)
        #expect(addFrames.contains { $0.contains(add.convert(CGPoint(x: add.bounds.midX, y: add.bounds.midY), to: tabs.view)) })
        // The badge is tape with ink text.
        let badgeLabels = ShellTapeBadge.labels(in: tabBar).filter { $0.text == "4" }
        #expect(!badgeLabels.isEmpty)
        #expect(badgeLabels.allSatisfy { $0.textColor == ShellTabBarCoordinator.tapeInk && $0.superview?.backgroundColor == ShellTabBarCoordinator.tape })

        // The tab bar is the toasts' bottom chrome while nothing is presented. It never registers
        // with ToastCenter, where it could outrank a pushed screen's bottom bar.
        await ShellTestWait.until("the chrome report") { tabBarChrome.height != nil }
        let chrome = try #require(tabBarChrome.height)
        #expect(chrome > 40 && chrome < 200)
        #expect(app.toasts.chromeHeight == nil)
        app.router.present(.sheet(.spaceNew(request: nil)))
        await ShellTestWait.until("the chrome released under a sheet") { tabBarChrome.height == nil }
        app.router.dismissTop()
        await ShellTestWait.until("the chrome back") { tabBarChrome.height != nil }
    }

    @Test("the toast floats above the taller of the focused screen's bottom bar and the tab bar")
    func toastChrome() {
        #expect(ShellTabBarChrome.toastChrome(registered: nil, tabBar: nil) == nil)
        #expect(ShellTabBarChrome.toastChrome(registered: nil, tabBar: 83) == 83)
        #expect(ShellTabBarChrome.toastChrome(registered: 150, tabBar: nil) == 150)
        // A pushed screen's bottom bar over the tab bar, whichever reported last.
        #expect(ShellTabBarChrome.toastChrome(registered: 160, tabBar: 83) == 160)
        #expect(ShellTabBarChrome.toastChrome(registered: 40, tabBar: 83) == 83)
    }

    @Test("a search button on another tab's pushed screen lands on Home and asks its field to focus once")
    func focusSearch() async throws {
        let app = AppContainer.preview()
        await app.boot.run()
        let host = try ShellTestWindow(MainShell().shellEnvironment(app))
        defer { host.close() }
        app.router.selectTab(.spaces)
        app.router.push(.space(id: "s1"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(app.router.searchFocus.focusRequests == 0)

        app.router.focusSearch()
        #expect(app.router.selectedTab == .home)
        await ShellTestWait.until("Home's field asked to focus") { app.router.searchFocus.focusRequests == 1 }
        try await Task.sleep(for: .milliseconds(700))
        #expect(app.router.searchFocus.focusRequests == 1)
        #expect(app.router.searchFocus.pending == nil)
    }

    @Test("selecting Add through the TabView binding presents the Add sheet and keeps the tab")
    func addSelection() async throws {
        let app = AppContainer.preview()
        await app.boot.run()
        app.router.selectTab(.spaces)
        app.router.selectTab(.add)
        #expect(app.router.selectedTab == .spaces)
        #expect(app.router.modals.map(\.route) == [.sheet(.addItem(AddParams()))])
    }
}
