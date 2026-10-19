import SwiftUI
import InventoryAppModels
import InventoryStorage

// Environment values every area of the app target reads. The shell sets them;
// previews and tests keep the defaults. Areas add their own entries in their
// own files instead of editing this one.
extension EnvironmentValues {
    /// Plays a haptic event (08 §7). The shell sets it from the AppContainer's
    /// platform player; the default is silent.
    @Entry var haptics: HapticPlayer = { _ in }

    /// Whether this screen is in front: the top of its navigation stack, with
    /// no sheet or full-screen cover over it, in the selected tab (09 §5,
    /// 00-index §5). Screens feed it to their queries and timers.
    @Entry var isScreenFocused: Bool = true

    /// Resolves stored photo URIs against the current app container (02 §3.3,
    /// D-4). Tests and previews may point it at a temporary directory.
    @Entry var photoPathResolver: PhotoPathResolver = PhotoPathResolver()
}
