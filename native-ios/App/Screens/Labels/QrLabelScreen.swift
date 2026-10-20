import SwiftUI
import InventoryAppModels
import InventoryStrings

/// A container's QR label (07 §3.9). Placeholder: the screen wave replaces the body.
struct QrLabelScreen: View {
    let containerId: String

    @Environment(AppContainer.self) private var app

    init(containerId: String) {
        self.containerId = containerId
    }

    var body: some View {
        ScreenFrame(.detail) {
            ShellPlaceholderContent(title: L10n.Qr.title, systemImage: "qrcode") {
                Button(L10n.Qr.link) { app.router.present(.linkSticker(containerId: containerId)) }
            }
        }
        .navigationTitle(L10n.Qr.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen-qr-label")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { QrLabelScreen(containerId: "c1") } }
}
