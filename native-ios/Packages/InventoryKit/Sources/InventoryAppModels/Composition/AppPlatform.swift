import Foundation

/// What the composition root needs from UIKit, as closures and objects the app target fills in
/// (`ShellPlatform.live()` there), so the container builds and tests without UIKit.
@MainActor
public struct AppPlatform {
    /// Plays a haptic event with the prepared UIKit feedback generators (08 §7).
    public var haptics: HapticPlayer
    /// Posts a VoiceOver announcement that interrupts (`AccessibilityNotification.Announcement`):
    /// the reconnecting copy, error states, the removed-phone layer.
    public var announce: @MainActor @Sendable (String) -> Void
    /// Posts a VoiceOver announcement queued behind current speech (toasts; RN `{ queue: true }`).
    public var announceQueued: @MainActor @Sendable (String) -> Void
    /// Whether VoiceOver runs now (toast lives double while it does).
    public var isVoiceOverRunning: @MainActor @Sendable () -> Bool
    /// The device's name (`UIDevice.current.name`), the join form's default phone name.
    public var deviceName: @MainActor @Sendable () -> String?
    /// Opens a URL outside the app.
    public var openURL: @MainActor @Sendable (URL) -> Void
    /// Opens the app's page in Settings (the camera permission's "Open Settings").
    public var openSettings: @MainActor @Sendable () -> Void
    /// `AVCaptureDevice.authorizationStatus(for: .video)`, mapped.
    public var cameraAuthorization: @MainActor @Sendable () -> CameraAuthorization
    /// `await AVCaptureDevice.requestAccess(for: .video)`.
    public var requestCameraAccess: @Sendable () async -> Bool
    /// Asks a confirmation in a system alert above every sheet (RN `confirm`).
    public var confirm: any ConfirmPresenting
    /// Shows a system action sheet (RN `showActionSheet`; the Add sheet's photo options).
    public var actionSheets: any ShellActionSheetPresenting

    public init(
        haptics: @escaping HapticPlayer,
        announce: @escaping @MainActor @Sendable (String) -> Void,
        announceQueued: @escaping @MainActor @Sendable (String) -> Void,
        isVoiceOverRunning: @escaping @MainActor @Sendable () -> Bool,
        deviceName: @escaping @MainActor @Sendable () -> String?,
        openURL: @escaping @MainActor @Sendable (URL) -> Void,
        openSettings: @escaping @MainActor @Sendable () -> Void,
        cameraAuthorization: @escaping @MainActor @Sendable () -> CameraAuthorization,
        requestCameraAccess: @escaping @Sendable () async -> Bool,
        confirm: any ConfirmPresenting,
        actionSheets: any ShellActionSheetPresenting
    ) {
        self.haptics = haptics
        self.announce = announce
        self.announceQueued = announceQueued
        self.isVoiceOverRunning = isVoiceOverRunning
        self.deviceName = deviceName
        self.openURL = openURL
        self.openSettings = openSettings
        self.cameraAuthorization = cameraAuthorization
        self.requestCameraAccess = requestCameraAccess
        self.confirm = confirm
        self.actionSheets = actionSheets
    }

    /// Does nothing and answers every question with no: for tests and previews.
    public static func silent(
        confirm: any ConfirmPresenting = ShellSilentDialogs(),
        actionSheets: any ShellActionSheetPresenting = ShellSilentDialogs()
    ) -> AppPlatform {
        AppPlatform(
            haptics: { _ in },
            announce: { _ in },
            announceQueued: { _ in },
            isVoiceOverRunning: { false },
            deviceName: { nil },
            openURL: { _ in },
            openSettings: {},
            cameraAuthorization: { .authorized },
            requestCameraAccess: { true },
            confirm: confirm,
            actionSheets: actionSheets
        )
    }
}

/// A short list of choices in a system action sheet (RN `showActionSheet`, src/ui/confirm.ts;
/// 07 §0.8): Cancel last, destructive options marked.
public struct ShellActionSheet: Sendable {
    public struct Option: Sendable {
        public var label: String
        public var destructive: Bool
        public var handler: @MainActor @Sendable () -> Void

        public init(label: String, destructive: Bool = false, handler: @escaping @MainActor @Sendable () -> Void) {
            self.label = label
            self.destructive = destructive
            self.handler = handler
        }
    }

    public var title: String?
    public var options: [Option]
    /// `L10n.Common.cancel` unless given.
    public var cancelLabel: String?

    public init(title: String? = nil, options: [Option], cancelLabel: String? = nil) {
        self.title = title
        self.options = options
        self.cancelLabel = cancelLabel
    }
}

/// Shows a ``ShellActionSheet``; choosing an option runs its handler, Cancel runs nothing.
@MainActor
public protocol ShellActionSheetPresenting: AnyObject {
    func showActionSheet(_ sheet: ShellActionSheet)
}

/// Dialogs that never show: confirmations answer no, action sheets run nothing.
@MainActor
public final class ShellSilentDialogs: ConfirmPresenting, ShellActionSheetPresenting {
    public init() {}

    public func confirm(_ options: ConfirmOptions) async -> Bool { false }

    public func showActionSheet(_ sheet: ShellActionSheet) {}
}
