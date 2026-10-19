#if DEBUG
import SwiftUI

/// Debug-only gallery of the shared components (see DebugGallery).
struct ComponentsGallery: View {
    let page: Int

    var body: some View {
        ContentUnavailableView("Components", systemImage: "square.stack.3d.up")
    }
}
#endif
