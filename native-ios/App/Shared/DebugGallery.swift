#if DEBUG
import SwiftUI

/// Debug builds only. The launch argument `-gallery <name>` shows a gallery
/// instead of the app, so views can be screenshotted on the simulator without
/// navigating to them, e.g. `scripts/mac.sh launch out.png -gallery components
/// -galleryPage 2`. Each area owns its gallery view; add a case here when a
/// new area adds one.
enum DebugGallery {
    static var requested: String? { UserDefaults.standard.string(forKey: "gallery") }
    static var page: Int { UserDefaults.standard.integer(forKey: "galleryPage") }

    @MainActor @ViewBuilder
    static func view(named name: String) -> some View {
        switch name {
        case "components": ComponentsGallery(page: page)
        case "media": MediaGallery(page: page)
        default: ContentUnavailableView("No gallery named \(name)", systemImage: "questionmark.square.dashed")
        }
    }
}
#endif
