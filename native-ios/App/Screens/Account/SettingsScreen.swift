import SwiftUI
import InventoryAppModels
import InventoryStrings

/// Settings (06 §12), pushed on Home's stack. Placeholder: the screen wave replaces the body.
struct SettingsScreen: View {
    @Environment(AppContainer.self) private var app

    var body: some View {
        ScreenFrame(.detail) {
            ShellPlaceholderContent(title: L10n.Settings.title, systemImage: "gearshape") {
                Button(L10n.Settings.household) { app.router.push(.household) }
                Button(L10n.Settings.backup) { app.router.push(.backup) }
                Button(L10n.Settings.privacy) { app.router.push(.privacy) }
                Button(L10n.Settings.howItWorks) { app.onboarding.replay() }
            }
        }
        .navigationTitle(L10n.Settings.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen-settings")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { SettingsScreen() } }
}
