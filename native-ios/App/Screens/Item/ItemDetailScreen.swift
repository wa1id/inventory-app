import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// An item (07 §3.2), large title; `filing` is a filing run from the Drop zone (RN `?filing=1`).
/// Placeholder: the screen wave replaces the body.
struct ItemDetailScreen: View {
    let id: String
    let filing: Bool

    @Environment(AppContainer.self) private var app

    init(id: String, filing: Bool) {
        self.id = id
        self.filing = filing
    }

    var body: some View {
        let id = id
        ShellPlaceholderQuery(key: "item:\(id)", read: { try await $0.items.getById(id) }) { item in
            ScreenFrame(.detail) {
                ShellPlaceholderContent(title: item??.name ?? L10n.Item.editDetails, systemImage: "tag") {
                    Button(L10n.Item.editDetails) { app.router.present(.itemEdit(id: id)) }
                    Button(filing ? L10n.Item.fileIt : L10n.Item.move) {
                        Task {
                            let moved = await app.router.presentForResult(MoveResult.self) {
                                .sheet(.move(itemId: id, filing: filing, request: $0))
                            }
                            if moved != nil { app.database.invalidate() }
                        }
                    }
                    .accessibilityIdentifier("item-move")
                    Button(L10n.Photo.close) { app.router.present(.photo(itemId: id)) }
                }
            }
            .navigationTitle(item??.name ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { SearchButton() }
        }
        .accessibilityIdentifier("screen-item")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { ItemDetailScreen(id: "unknown", filing: false) } }
}
