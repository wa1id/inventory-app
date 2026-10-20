import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// The Drop zone (06 §7). Placeholder: the screen wave replaces the body.
struct DropZoneScreen: View {
    @Environment(AppContainer.self) private var app

    var body: some View {
        ScreenFrame(.tabRoot) {
            ShellPlaceholderContent(title: L10n.DropZone.title, systemImage: AppTab.dropZone.systemImage) {
                Button(L10n.DropZone.quickSnap) { app.router.openQuickSnap() }
                ForEach(app.dropZone.items) { item in
                    Button(item.name.isEmpty ? L10n.Item.fileIt : item.name) {
                        app.router.push(.item(id: item.id, filing: true))
                    }
                }
            }
        }
        .navigationTitle(L10n.DropZone.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { SearchButton() }
        }
        .accessibilityIdentifier("screen-drop-zone")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { DropZoneScreen() } }
}
