import SwiftUI
import InventoryAppModels
import InventoryStrings

/// Linking a printed sticker to a container, full screen (07 §3.10). Placeholder: the screen wave
/// replaces the body.
struct LinkStickerScreen: View {
    let containerId: String

    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address

    init(containerId: String) {
        self.containerId = containerId
    }

    var body: some View {
        ScreenFrame(.camera) {
            ShellPlaceholderContent(title: L10n.Qr.link, systemImage: "qrcode.viewfinder") {
                Button(L10n.Common.close) {
                    if let address { app.router.close(address) }
                }
                .accessibilityIdentifier("link-close")
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("screen-link-sticker")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { LinkStickerScreen(containerId: "c1") } }
}
