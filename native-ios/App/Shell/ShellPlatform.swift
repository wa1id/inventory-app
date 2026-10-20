import AVFoundation
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
            cameraAuthorization: { cameraAuthorization() },
            requestCameraAccess: { await AVCaptureDevice.requestAccess(for: .video) },
            confirm: dialogs,
            actionSheets: dialogs
        )
    }

    /// Posts a VoiceOver announcement. Queued ones wait behind current speech, as RN's
    /// `announceForAccessibilityWithOptions(…, { queue: true })` did for toasts (08 §9.2 (10));
    /// every other announcement interrupts.
    @MainActor
    static func announce(_ text: String, queued: Bool = false) {
        guard !text.isEmpty else { return }
        if queued {
            let attributed = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
            UIAccessibility.post(notification: .announcement, argument: attributed)
        } else {
            AccessibilityNotification.Announcement(text).post()
        }
    }

    @MainActor
    static func cameraAuthorization() -> CameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }
}
