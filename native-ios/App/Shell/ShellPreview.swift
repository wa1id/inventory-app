import SwiftUI
import InventoryAppModels

extension View {
    /// What every screen reads from the environment: the container, the router and the shared
    /// values (haptics, the photo resolver, announcements).
    func shellEnvironment(_ app: AppContainer) -> some View {
        environment(app)
            .environment(app.router)
            .environment(\.haptics, app.platform.haptics)
            .environment(\.photoPathResolver, app.photoPathResolver)
            .environment(\.shellAnnounce, app.platform.announce)
    }
}

#if DEBUG
// DEBUG only (previews, the demo, tests): kept out of Release builds.
/// Runs a preview against ``AppContainer/preview(platform:seed:onboardingCompleted:)``: boots it
/// (an in-memory database seeded with sample data, no network) and shows `content` once the
/// database is ready, with the shell's environment.
///
/// ```swift
/// #Preview { ShellPreviewHost { NavigationStack { SpacesScreen() } } }
/// ```
struct ShellPreviewHost<Content: View>: View {
    @State private var app: AppContainer
    private let content: Content

    /// - Parameters:
    ///   - seed: fill the database with the sample inventory.
    ///   - onboardingCompleted: false to preview onboarding.
    init(seed: Bool = true, onboardingCompleted: Bool = true, @ViewBuilder content: () -> Content) {
        _app = State(initialValue: AppContainer.preview(seed: seed, onboardingCompleted: onboardingCompleted))
        self.content = content()
    }

    var body: some View {
        Group {
            if app.database.status == .ready {
                content
            } else {
                ProgressView()
            }
        }
        .shellEnvironment(app)
        .task { await app.boot.run() }
    }
}
#endif
