import SwiftUI
import InventoryAppModels
import InventoryStrings

/// Edit space (07 §3.13). Placeholder: the screen wave replaces the body.
struct SpaceEditSheet: View {
    let id: String

    init(id: String) {
        self.id = id
    }

    var body: some View {
        ScreenFrame(.modal) {
            ShellPlaceholderContent(title: L10n.SpaceForm.editTitle, systemImage: AppTab.spaces.systemImage)
        }
        .navigationTitle(L10n.SpaceForm.editTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen-space-edit")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { SpaceEditSheet(id: "s1") } }
}
