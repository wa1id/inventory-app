import SwiftUI
import InventoryAppModels

/// The boot gate (RN `RootNavigator`, app/_layout.tsx:104-221; 09 §2.4, §3.2): the database
/// failure first, then the boot view while the database, onboarding or the household session is
/// loading, then onboarding or the main shell. Boot runs from here, once (`AppBoot.run()` is
/// cancellation-safe). Once the gate has passed, the overlay window for toasts and the
/// removed-phone layer is installed; deep links and quick actions wait until the main shell shows.
struct RootView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var overlay: ShellOverlayController?
    @State private var tabBarChrome = ShellTabBarChrome()

    var body: some View {
        let phase = app.boot.phase
        ZStack {
            switch phase {
            case .failed:
                BootFailedView { Task { await app.database.retry() } }
            case .booting:
                BootView()
            case .onboarding:
                OnboardingScreen()
            case .main:
                MainShell()
            }
        }
        .background {
            if phase == .onboarding || phase == .main {
                ShellWindowSceneReader { scene in installOverlay(on: scene) }
            }
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            CGSize(
                width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            )
        } action: { size in
            windowSize = size
        }
        .environment(\.shellWindowSize, windowSize)
        .environment(\.shellTabBarChrome, tabBarChrome)
        .task { await app.boot.run() }
        .onChange(of: phase, initial: true) { _, phase in
            app.rootPhaseChanged(phase)
        }
        .onChange(of: voiceOverEnabled, initial: true) { _, enabled in
            app.toasts.isVoiceOverRunning = enabled
        }
        #if DEBUG
        .task(id: phase == .main) {
            if phase == .main { await ShellDemo.run(app) }
        }
        #endif
    }

    @State private var windowSize: CGSize = .zero

    private func installOverlay(on scene: UIWindowScene) {
        if overlay == nil { overlay = ShellOverlayController(app: app, tabBarChrome: tabBarChrome) }
        overlay?.install(on: scene)
    }
}

#Preview("Main") {
    @Previewable @State var app = AppContainer.preview()
    RootView().shellEnvironment(app)
}

#Preview("Onboarding") {
    @Previewable @State var app = AppContainer.preview(onboardingCompleted: false)
    RootView().shellEnvironment(app)
}
