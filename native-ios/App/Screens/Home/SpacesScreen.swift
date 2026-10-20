import SwiftUI
import InventoryAppModels
import InventoryStrings

/// Spaces (06 §6). Placeholder: the screen wave replaces the body.
struct SpacesScreen: View {
    @Environment(AppContainer.self) private var app

    var body: some View {
        ScreenFrame(.tabRoot) {
            ShellPlaceholderContent(title: L10n.Spaces.title, systemImage: AppTab.spaces.systemImage) {
                Button(L10n.Spaces.newSpace) { app.router.present(.spaceNew(request: nil)) }
                ShellPlaceholderQuery(key: "spaces", read: { try await $0.spaces.listWithCounts() }) { spaces in
                    ForEach(spaces ?? [], id: \.space.id) { row in
                        Button(row.space.name) { app.router.openSpace(row.space.id) }
                    }
                }
            }
        }
        .navigationTitle(L10n.Spaces.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { SearchButton() }
        }
        .accessibilityIdentifier("screen-spaces")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { SpacesScreen() } }
}
