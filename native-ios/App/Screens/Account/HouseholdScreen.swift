import SwiftUI
import InventoryAppModels
import InventoryStrings

/// The household (04 §12). Placeholder: the screen wave replaces the body.
struct HouseholdScreen: View {
    var body: some View {
        ScreenFrame(.detail) {
            ShellPlaceholderContent(title: L10n.Household.screenTitle, systemImage: "server.rack")
        }
        .navigationTitle(L10n.Household.screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen-household")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { HouseholdScreen() } }
}
