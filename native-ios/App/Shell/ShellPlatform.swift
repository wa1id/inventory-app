import SwiftUI
import UIKit
import InventoryAppModels

/// The UIKit side of the composition root: haptics, VoiceOver, dialogs, Settings and the camera
/// permission, as the `AppPlatform` the container takes.
enum ShellPlatform {
    @MainActor
    static func live() -> AppPlatform {
        let haptics = ShellHapticEngine()
        let dialogs = ShellDialogPresenter()
        return AppPlatform(
            haptics: haptics.player,
            announce: { announce($0) },
            announceQueued: { announce($0, queued: true) },
            isVoiceOverRunning: { UIAccessibility.isVoiceOverRunning },
            deviceName: { UIDevice.current.name },
            openURL: { UIApplication.shared.open($0) },
            openSettings: {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            },
            cameraAuthorization: { CameraAuthorizationAccess.read() },
            requestCameraAccess: { await CameraAuthorizationAccess.request() },
            confirm: dialogs,
            actionSheets: dialogs
        )
    }

    /// Posts a VoiceOver announcement. Queued ones wait behind current speech, as RN's
    /// `announceForAccessibilityWithOptions(…, { queue: true })` did for toasts (08 §9.2 (10));
    /// every other announcement interrupts.
    @MainActor
    static func announce(_ text: String, queued: Bool = false) {
        if queued {
            ComponentAnnouncer.announceQueued(text)
        } else {
            ComponentAnnouncer.announce(text)
        }
    }
}
