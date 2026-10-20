import SwiftUI
import InventoryAppModels
import InventoryStrings

/// Privacy and your data (06 §13). Placeholder: the screen wave replaces the body.
struct PrivacyScreen: View {
    var body: some View {
        ScreenFrame(.detail) {
            ShellPlaceholderContent(title: L10n.Privacy.title, systemImage: "hand.raised")
        }
        .navigationTitle(L10n.Privacy.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen-privacy")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { PrivacyScreen() } }
}
