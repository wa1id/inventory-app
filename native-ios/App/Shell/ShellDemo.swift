#if DEBUG
import Foundation
import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStrings

/// Debug builds only: launch arguments that put the shell in a state for screenshots, since the
/// simulator cannot be tapped from a script.
///
/// - `-demo YES`: the sample inventory in memory (nothing on the device is read or written);
///   `-demoOnboarding YES` starts on onboarding.
/// - `-demoHousehold offline|revoked`: joined to a household whose server is unreachable (the
///   connection banner after 2.5 s) or answers 401 (the removed-phone layer).
/// - `-demoOpen settings|label|add|addOverSheet|capture|review|move`: opens that route once the
///   main shell shows.
/// - `-demoToast info|error|action`: shows that toast once the main shell shows.
/// - `-demoTab spaces|scan|dropZone`: selects that tab first.
enum ShellDemo {
    private static var defaults: UserDefaults { .standard }

    @MainActor
    static func makeContainer(platform: AppPlatform) -> AppContainer? {
        guard defaults.bool(forKey: "demo") else { return nil }
        let household = defaults.string(forKey: "demoHousehold")
        let session = household.map { _ in
            HouseholdSession(origin: "https://box.example", token: "demo-token", deviceId: "demo-device", deviceName: "iPhone", householdName: "Home")
        }
        let transport: any HTTPTransport = household == "revoked" ? ShellDemoUnauthorizedTransport() : ShellOfflineTransport()
        return AppContainer.preview(
            platform: platform,
            onboardingCompleted: !defaults.bool(forKey: "demoOnboarding"),
            householdSession: session,
            transport: transport
        )
    }

    /// Runs the requested steps, once per process.
    @MainActor
    static func run(_ app: AppContainer) async {
        guard defaults.bool(forKey: "demo"), !ran else { return }
        ran = true
        let router = app.router
        switch defaults.string(forKey: "demoTab") {
        case "spaces": router.selectTab(.spaces)
        case "scan": router.selectTab(.scan)
        case "dropZone": router.selectTab(.dropZone)
        default: break
        }
        try? await Task.sleep(for: .milliseconds(400))
        switch defaults.string(forKey: "demoOpen") {
        case "settings":
            router.push(.settings)
        case "label":
            router.open(URL(string: "inventory://c/0123456789abcdef0123456789abcdef") ?? URL(filePath: "/"))
        case "add":
            router.present(.addItem(AddParams()))
        case "addOverSheet":
            router.present(.addItem(AddParams()))
            try? await Task.sleep(for: .milliseconds(700))
            router.present(.containerNew(spaceId: DropZone.spaceId, request: nil))
        case "capture":
            router.openQuickSnap()
        case "review":
            router.openQuickSnap()
            try? await Task.sleep(for: .milliseconds(700))
            router.push(.quickSnapReview(QuickSnapReviewRoute(containerId: DropZone.containerId, since: 0, expected: 2)))
        case "move":
            router.present(.move(itemId: "demo", filing: true, request: nil))
        default:
            break
        }
        try? await Task.sleep(for: .milliseconds(700))
        switch defaults.string(forKey: "demoToast") {
        case "info":
            app.toasts.show(ToastOptions(message: L10n.Move.undone, duration: .seconds(60)))
        case "error":
            app.toasts.show(ToastOptions(message: L10n.Move.failed, tone: .error, duration: .seconds(60)))
        case "action":
            app.toasts.show(ToastOptions(
                message: L10n.Move.movedTo(container: "Tool chest", space: "Garage"),
                action: ToastAction(label: L10n.Common.undo) {},
                duration: .seconds(60)))
        default:
            break
        }
    }

    @MainActor private static var ran = false
}

/// Every request answered 401, as for a phone removed from the household.
private struct ShellDemoUnauthorizedTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        HTTPResponse(status: 401, headers: ["content-type": "application/json"], body: Data(#"{"error":"unauthorized"}"#.utf8))
    }
}
#endif
