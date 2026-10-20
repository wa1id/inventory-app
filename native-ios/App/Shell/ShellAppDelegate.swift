import UIKit

/// Home Screen quick actions on their way to the router. The scene delegate posts the action's
/// type here (a launch from a quick action, or one performed while running); the app attaches
/// the router once its container exists, and anything posted before that waits.
@MainActor
final class ShellQuickActionInbox {
    static let shared = ShellQuickActionInbox()

    private var handler: ((String) -> Void)?
    private var waiting: [String] = []

    /// Sends every action to `handler` from now on, starting with any that waited.
    func attach(_ handler: @escaping (String) -> Void) {
        self.handler = handler
        let waiting = waiting
        self.waiting = []
        waiting.forEach(handler)
    }

    func post(_ type: String) {
        if let handler {
            handler(type)
        } else {
            waiting.append(type)
        }
    }
}

/// Gives the window scene a delegate of ours, for quick actions; SwiftUI still owns the window.
final class ShellAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = ShellSceneDelegate.self
        return configuration
    }
}

/// Receives the "Quick Snap" quick action: at launch (`connectionOptions.shortcutItem`) and while
/// running (`windowScene(_:performActionFor:)`).
final class ShellSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem {
            ShellQuickActionInbox.shared.post(item.type)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        ShellQuickActionInbox.shared.post(shortcutItem.type)
        completionHandler(true)
    }
}
