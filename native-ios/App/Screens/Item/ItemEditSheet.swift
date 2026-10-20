import SwiftUI
import InventoryAppModels
import InventoryStrings

/// Edit details (07 §3.4). A dirty form registers `.sheetCloseGuard { await guard.attemptClose() }`
/// and `.interactiveDismissDisabled(guard.interactiveDismissDisabled)`. Placeholder: the screen
/// wave replaces the body.
struct ItemEditSheet: View {
    let id: String

    init(id: String) {
        self.id = id
    }

    var body: some View {
        ScreenFrame(.modal) {
            ShellPlaceholderContent(title: L10n.EditItem.title, systemImage: "pencil")
        }
        .navigationTitle(L10n.EditItem.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen-item-edit")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { ItemEditSheet(id: "i1") } }
}
