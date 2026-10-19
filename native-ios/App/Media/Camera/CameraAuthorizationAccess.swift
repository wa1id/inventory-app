import AVFoundation
import InventoryAppModels
import InventoryCore

/// The camera permission as AVFoundation keeps it, for `CameraPermissionModel` (05 §16.1,
/// 06 §8.5). The status is read synchronously, so RN's black "still reading" wait does not exist.
enum CameraAuthorizationAccess {
    /// expo-camera's mapping kept: `.denied` and `.restricted` cannot ask again; anything unknown
    /// is treated as denied, so the screen points to Settings rather than a prompt that never
    /// comes.
    // RN: node_modules/expo-camera/ios/Common/CameraPermissionsRequester.swift:32-50
    static func authorization(_ status: AVAuthorizationStatus) -> CameraAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .denied
        }
    }

    /// `AVCaptureDevice.authorizationStatus(for: .video)`, mapped.
    static func read() -> CameraAuthorization {
        authorization(AVCaptureDevice.authorizationStatus(for: .video))
    }

    /// The system prompt (`AVCaptureDevice.requestAccess(for: .video)`); true when granted.
    static func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }
}

extension CameraPermissionModel {
    /// The permission of this device's camera, for the capture screen or the scanner.
    @MainActor
    static func device(purpose: CameraPermissionPurpose, telemetry: TelemetryReporter = .shared) -> CameraPermissionModel {
        CameraPermissionModel(
            purpose: purpose,
            readAuthorization: { CameraAuthorizationAccess.read() },
            requestAccess: { await CameraAuthorizationAccess.request() },
            telemetry: telemetry
        )
    }
}
