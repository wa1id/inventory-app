import SwiftUI
import InventoryAppModels
import InventoryStrings

/// The Scan tab (06 §8). Placeholder: the screen wave replaces the body.
struct ScanScreen: View {
    @Environment(AppContainer.self) private var app

    var body: some View {
        ScreenFrame(.tabRoot) {
            ShellPlaceholderContent(title: L10n.Scan.title, systemImage: AppTab.scan.systemImage) {
                Button(L10n.DeepLink.title) { app.router.push(.label(token: "0123456789abcdef0123456789abcdef")) }
            }
        }
        .navigationTitle(L10n.Scan.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen-scan")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { ScanScreen() } }
}
