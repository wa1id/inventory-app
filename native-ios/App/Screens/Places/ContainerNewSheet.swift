import SwiftUI
import InventoryAppModels
import InventoryStrings

/// New container in a space (07 §3.6). With a request, the created container is delivered to the
/// opener (the place picker); without one the sheet opens it. Placeholder: the screen wave
/// replaces the body.
struct ContainerNewSheet: View {
    let spaceId: String
    let request: RouteRequest<NewContainerResult>?

    @Environment(AppContainer.self) private var app

    init(spaceId: String, request: RouteRequest<NewContainerResult>?) {
        self.spaceId = spaceId
        self.request = request
    }

    var body: some View {
        ScreenFrame(.modal) {
            ShellPlaceholderContent(title: L10n.ContainerForm.newTitle, systemImage: "shippingbox") {
                Button(L10n.SpaceForm.newTitle) { app.router.present(.spaceNew(request: nil)) }
            }
        }
        .navigationTitle(L10n.ContainerForm.newTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen-container-new")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { ContainerNewSheet(spaceId: "s1", request: nil) } }
}
