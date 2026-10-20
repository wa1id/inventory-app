import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// The Quick Snap review, pushed inside the capture cover with the back button hidden (05 §6).
/// `QuickSnapReviewNavigation` maps to the router: `.leave` → close the cover, `.keepShooting` /
/// `.tryAgain` → `router.replaceModal(containing: address, with: .cover(.capture(route, request: nil)))`,
/// `.openItem` → `router.push(.item(…))`, `.viewDropZone` → `router.goToTab(.dropZone)`.
/// Placeholder: the screen wave replaces the body.
struct QuickSnapReviewScreen: View {
    let route: QuickSnapReviewRoute

    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address

    init(route: QuickSnapReviewRoute) {
        self.route = route
    }

    var body: some View {
        ScreenFrame(.detail) {
            ShellPlaceholderContent(title: L10n.Review.title, systemImage: "square.stack.3d.up") {
                Button(L10n.Review.keepShooting) {
                    if let address {
                        let next = CaptureRoute(containerId: route.containerId, mode: .fast, since: route.since, expectedBase: route.expected)
                        app.router.replaceModal(containing: address, with: .cover(.capture(next, request: nil)))
                    }
                }
                .accessibilityIdentifier("review-keep-shooting")
                Button(L10n.Review.done) {
                    if let address, let level = app.router.state.modalLevel(containing: address) {
                        app.router.close(app.router.modals[level].address)
                    }
                }
                .accessibilityIdentifier("review-done")
            }
        }
        .navigationTitle(L10n.Review.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .accessibilityIdentifier("screen-review")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { QuickSnapReviewScreen(route: QuickSnapReviewRoute(containerId: DropZone.containerId, since: 0, expected: 2)) } }
}
