import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryServices
import InventoryStrings

/// The camera, full screen (05 §4): single, request (with `request`, the Add sheet waiting for
/// one photo) or fast (Quick Snap). `CaptureModel.disappeared()` goes in a removal hook
/// (`router.onRemoval(of: address)`), never in `onDisappear`; `CaptureNavigation` maps to the
/// router: `.back` → `router.close(address)`, `.addItem` → `router.replaceModal(containing:with:)`
/// with `.sheet(.addItem(AddParams(containerId:photo:)))`, `.review` → `router.push(.quickSnapReview(…))`
/// inside this cover. The delivery is `{ app.router.results.deliver(request, $0) }`. Placeholder:
/// the screen wave replaces the body.
struct CaptureScreen: View {
    let route: CaptureRoute
    let request: RouteRequest<StoredImage>?

    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address

    init(route: CaptureRoute, request: RouteRequest<StoredImage>?) {
        self.route = route
        self.request = request
    }

    var body: some View {
        ScreenFrame(.camera) {
            ShellPlaceholderContent(title: L10n.Tabs.quickSnapAction, systemImage: "camera") {
                Button(L10n.Capture.close) {
                    if let address { app.router.close(address) }
                }
                .accessibilityIdentifier("capture-close")
                if route.mode == .fast {
                    Button(L10n.Capture.done) {
                        app.router.push(.quickSnapReview(QuickSnapReviewRoute(containerId: route.containerId, since: route.since ?? 0, expected: 0)))
                    }
                    .accessibilityIdentifier("capture-done")
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("screen-capture")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { CaptureScreen(route: .quickSnap, request: nil) } }
}
