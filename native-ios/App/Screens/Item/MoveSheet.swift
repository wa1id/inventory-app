import SwiftUI
import InventoryAppModels
import InventoryStrings

/// Move or file an item (07 §3.5). The opener waits for a `MoveResult` through `request`
/// (`MoveModel(request:routeResults: app.router.results, …)`). Placeholder: the screen wave
/// replaces the body.
struct MoveSheet: View {
    let itemId: String
    let filing: Bool
    let request: RouteRequest<MoveResult>?

    init(itemId: String, filing: Bool, request: RouteRequest<MoveResult>?) {
        self.itemId = itemId
        self.filing = filing
        self.request = request
    }

    var body: some View {
        let title = filing ? L10n.Move.titleFileUnnamed : L10n.Move.titleMoveUnnamed
        ScreenFrame(.modal) {
            ShellPlaceholderContent(title: title, systemImage: "folder")
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen-move")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { MoveSheet(itemId: "i1", filing: false, request: nil) } }
}
