import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Inventory
import InventoryAppModels
import InventoryStrings

@Suite("Root view and deep links (hosted)", .serialized)
@MainActor
struct ShellRootViewTests {
    @Test("a deep link while onboarding is pending waits, and opens the label on Home once onboarding completes")
    func deepLinkDuringOnboarding() async throws {
        let app = AppContainer.preview(onboardingCompleted: false)
        let host = try ShellTestWindow(RootView().shellEnvironment(app))
        defer { host.close() }

        await ShellTestWait.until("onboarding") { app.boot.phase == .onboarding }
        #expect(!app.router.acceptsNavigation)
        #expect(app.router.open(try #require(URL(string: "inventory://c/0123456789abcdef0123456789abcdef"))))
        #expect(app.router.pendingExternalRequest == .deepLink(.label(token: "0123456789abcdef0123456789abcdef")))
        #expect(app.router.path(.home).isEmpty)

        app.onboarding.complete()
        await ShellTestWait.until("the label pushed on Home") { !app.router.path(.home).isEmpty }
        #expect(app.router.selectedTab == .home)
        #expect(app.router.path(.home).map(\.route) == [.label(token: "0123456789abcdef0123456789abcdef")])
        #expect(app.router.pendingExternalRequest == nil)
    }

    @Test("a deep link once the main shell shows opens at once; replaying onboarding resets navigation")
    func deepLinkWhenReady() async throws {
        let app = AppContainer.preview()
        let host = try ShellTestWindow(RootView().shellEnvironment(app))
        defer { host.close() }

        await ShellTestWait.until("the main shell") { app.boot.phase == .main && app.router.acceptsNavigation }
        app.router.open(try #require(URL(string: "com.wystudio.inventory://c/abc")))
        #expect(app.router.path(.home).map(\.route) == [.label(token: "abc")])

        app.onboarding.replay()
        await ShellTestWait.until("navigation reset") { !app.router.acceptsNavigation }
        #expect(app.router.state == RouterState())
    }

    @Test("the scene phase maps onto the models' activity")
    func activity() {
        #expect(AppActivity(ScenePhase.active) == .active)
        #expect(AppActivity(ScenePhase.inactive) == .inactive)
        #expect(AppActivity(ScenePhase.background) == .background)
    }

    @Test("Info.plist keeps both URL schemes and offers the Quick Snap quick action (02 §9, U5)")
    func infoPlist() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let types = try #require(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(Set(schemes) == DeepLink.schemes)
        let shortcuts = try #require(info["UIApplicationShortcutItems"] as? [[String: Any]])
        #expect(shortcuts.count == 1)
        #expect(shortcuts.first?["UIApplicationShortcutItemType"] as? String == AppQuickAction.quickSnap.rawValue)
        #expect(shortcuts.first?["UIApplicationShortcutItemTitle"] as? String == L10n.Tabs.quickSnapAction)
        #expect(shortcuts.first?["UIApplicationShortcutItemIconSymbolName"] as? String == "camera")
        let ats = try #require(info["NSAppTransportSecurity"] as? [String: Any])
        #expect(ats["NSAllowsLocalNetworking"] as? Bool == true)
        #expect(info["UIRequiredDeviceCapabilities"] as? [String] == ["arm64"])
        #expect(info["NSCameraUsageDescription"] != nil)
        #expect(info["NSPhotoLibraryUsageDescription"] != nil)
    }

    @Test("a quick action posted before the router is attached waits for it")
    func quickActionInbox() {
        let inbox = ShellQuickActionInbox()
        var received: [String] = []
        inbox.post(AppQuickAction.quickSnap.rawValue)
        inbox.attach { received.append($0) }
        inbox.post("later")
        #expect(received == [AppQuickAction.quickSnap.rawValue, "later"])
    }
}
