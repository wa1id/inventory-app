import SwiftUI
import InventoryAppModels

/// The app: one composition root for the process, the boot gate as the window's content, the
/// scene phase routed to the app models, deep links to the router and Home Screen quick actions
/// through the scene delegate (09 §13.2, §6; 06 §3.6; DECISIONS U5).
@main
struct InventoryApp: App {
    @UIApplicationDelegateAdaptor(ShellAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var app: AppContainer

    init() {
        // No I/O here: boot runs from the root view's task (09 §3.2 step 0).
        let app = Self.makeContainer()
        _app = State(initialValue: app)
        let router = app.router
        ShellQuickActionInbox.shared.attach { router.performQuickAction(type: $0) }
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let gallery = DebugGallery.requested {
                DebugGallery.view(named: gallery)
            } else {
                root
            }
            #else
            root
            #endif
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            app.activityChanged(AppActivity(phase))
        }
    }

    private var root: some View {
        RootView()
            .shellEnvironment(app)
            .onOpenURL { url in app.router.open(url) }
    }

    @MainActor
    private static func makeContainer() -> AppContainer {
        let platform = ShellPlatform.live()
        #if DEBUG
        // `-demo YES`: the sample inventory in memory, for screenshots (see ShellDemo).
        if let demo = ShellDemo.makeContainer(platform: platform) { return demo }
        #endif
        return AppContainer.live(platform: platform)
    }
}

extension AppActivity {
    /// SwiftUI's scene phase as the models see it.
    init(_ phase: ScenePhase) {
        switch phase {
        case .active: self = .active
        case .background: self = .background
        case .inactive: self = .inactive
        @unknown default: self = .inactive
        }
    }
}
