import SwiftUI
import InventoryAppModels
import InventoryStrings

/// New space (07 §3.11). With a request, the created space is delivered to the opener
/// (`app.router.results.deliver(request, …)`); without one the sheet opens the new space itself.
/// Placeholder: the screen wave replaces the body.
struct SpaceNewSheet: View {
    let request: RouteRequest<NewSpaceResult>?

    init(request: RouteRequest<NewSpaceResult>?) {
        self.request = request
    }

    var body: some View {
        ScreenFrame(.modal) {
            ShellPlaceholderContent(title: L10n.SpaceForm.newTitle, systemImage: AppTab.spaces.systemImage)
        }
        .navigationTitle(L10n.SpaceForm.newTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen-space-new")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { SpaceNewSheet(request: nil) } }
}
