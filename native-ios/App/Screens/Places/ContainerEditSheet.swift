import SwiftUI
import InventoryAppModels
import InventoryStrings

/// Edit container (07 §3.8). Placeholder: the screen wave replaces the body.
struct ContainerEditSheet: View {
    let id: String

    init(id: String) {
        self.id = id
    }

    var body: some View {
        ScreenFrame(.modal) {
            ShellPlaceholderContent(title: L10n.ContainerForm.editTitle, systemImage: "shippingbox")
        }
        .navigationTitle(L10n.ContainerForm.editTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen-container-edit")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { ContainerEditSheet(id: "c1") } }
}
