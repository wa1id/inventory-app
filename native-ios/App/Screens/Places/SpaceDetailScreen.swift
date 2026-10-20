import SwiftUI
import InventoryAppModels
import InventoryStrings

/// A space (07 §3.12), large title. Placeholder: the screen wave replaces the body.
struct SpaceDetailScreen: View {
    let id: String

    @Environment(AppContainer.self) private var app

    init(id: String) {
        self.id = id
    }

    var body: some View {
        let id = id
        ShellPlaceholderQuery(key: "space:\(id)", read: { try await $0.spaces.getById(id) }) { space in
            ScreenFrame(.detail) {
                ShellPlaceholderContent(title: space??.name ?? L10n.Spaces.title, systemImage: AppTab.spaces.systemImage) {
                    Button(L10n.SpaceForm.editTitle) { app.router.present(.spaceEdit(id: id)) }
                    Button(L10n.ContainerForm.newTitle) { app.router.present(.containerNew(spaceId: id, request: nil)) }
                    ShellPlaceholderQuery(key: "containers:\(id)", read: { try await $0.containers.listBySpace(id) }) { containers in
                        ForEach(containers ?? [], id: \.container.id) { row in
                            Button(row.container.name ?? row.container.shortCode) { app.router.openContainer(row.container.id) }
                        }
                    }
                }
            }
            .navigationTitle(space??.name ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { SearchButton() }
        }
        .accessibilityIdentifier("screen-space")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { SpaceDetailScreen(id: "unknown") } }
}
