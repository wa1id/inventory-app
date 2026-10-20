import SwiftUI
import InventoryAppModels
import InventoryStrings

/// A container (07 §3.7), large title. Never the drop zone (the router opens its tab instead).
/// Placeholder: the screen wave replaces the body.
struct ContainerDetailScreen: View {
    let id: String

    @Environment(AppContainer.self) private var app

    init(id: String) {
        self.id = id
    }

    var body: some View {
        let id = id
        ShellPlaceholderQuery(key: "container:\(id)", read: { try await $0.containers.getById(id) }) { container in
            let title = container??.name ?? container??.shortCode ?? ""
            ScreenFrame(.detail) {
                ShellPlaceholderContent(title: title.isEmpty ? L10n.ContainerForm.editTitle : title, systemImage: "shippingbox") {
                    Button(L10n.Qr.title) { app.router.push(.qrLabel(containerId: id)) }
                    Button(L10n.Qr.link) { app.router.present(.linkSticker(containerId: id)) }
                    Button(L10n.ContainerForm.editTitle) { app.router.present(.containerEdit(id: id)) }
                    Button(L10n.Add.title) { app.router.present(.addItem(AddParams(containerId: id))) }
                    ShellPlaceholderQuery(key: "items:\(id)", read: { try await $0.items.listByContainer(id) }) { items in
                        ForEach(items ?? [], id: \.id) { item in
                            Button(item.name) { app.router.push(.item(id: item.id, filing: false)) }
                        }
                    }
                }
            }
            .navigationTitle(title)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { SearchButton() }
        }
        .accessibilityIdentifier("screen-container")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { ContainerDetailScreen(id: "unknown") } }
}
