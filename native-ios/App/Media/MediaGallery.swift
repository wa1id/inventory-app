#if DEBUG
import SwiftUI

/// Debug-only gallery of the camera, scanner and QR views (see DebugGallery).
struct MediaGallery: View {
    let page: Int

    var body: some View {
        ContentUnavailableView("Media", systemImage: "camera")
    }
}
#endif
