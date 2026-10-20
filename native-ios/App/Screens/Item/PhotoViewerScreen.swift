import SwiftUI
import InventoryAppModels
import InventoryStrings

/// An item's photo, full screen (05 §12). Placeholder: the screen wave replaces the body.
struct PhotoViewerScreen: View {
    let itemId: String

    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address

    init(itemId: String) {
        self.itemId = itemId
    }

    var body: some View {
        ScreenFrame(.camera) {
            ShellPlaceholderContent(title: L10n.Photo.close, systemImage: "photo") {
                Button(L10n.Common.close) {
                    if let address { app.router.close(address) }
                }
                .accessibilityIdentifier("photo-close")
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("screen-photo")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { PhotoViewerScreen(itemId: "i1") } }
}
