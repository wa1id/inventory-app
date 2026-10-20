import SwiftUI
import InventoryAppModels
import InventoryStrings

/// The search button in tab-root and detail toolbars: Home with the keyboard up, wherever it was
/// pressed (RN `SearchButton`, ScreenFrame.tsx:100-114; `focusSearch`).
struct SearchButton: View {
    var identifier: String = "search-button"
    @Environment(AppContainer.self) private var app

    var body: some View {
        Button {
            app.router.focusSearch()
        } label: {
            Label(L10n.A11y.searchHousehold, systemImage: "magnifyingglass")
        }
        .labelStyle(.iconOnly)
        .accessibilityHint(L10n.A11y.searchHint)
        .accessibilityIdentifier(identifier)
    }
}

#Preview {
    NavigationStack {
        Text(L10n.Spaces.title)
            .toolbar { ToolbarItem { SearchButton() } }
    }
    .environment(AppContainer.preview())
}
