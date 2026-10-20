import SwiftUI
import InventoryAppModels
import InventoryStrings

/// A QR label opened from the system Camera or handed over by Scan (06 §9). The model's
/// `LabelLinkModel.close()` goes in a removal hook (`router.onRemoval(of: address)`), never in
/// `onDisappear`. Placeholder: the screen wave replaces the body.
struct LabelLinkScreen: View {
    /// `ScanRules.tokenParam`'s token (trimmed); the repository decides whether it is ours.
    let token: String

    @Environment(AppContainer.self) private var app

    init(token: String) {
        self.token = token
    }

    var body: some View {
        ScreenFrame(.detail) {
            ShellPlaceholderContent(title: L10n.DeepLink.title, systemImage: "qrcode", detail: token) {
                Button(L10n.Common.goToHome) { app.router.goToTab(.home) }
            }
        }
        .navigationTitle(L10n.DeepLink.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen-label")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { LabelLinkScreen(token: "0123456789abcdef0123456789abcdef") } }
}
