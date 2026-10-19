import CoreGraphics
import Observation

/// Tap to focus on the capture preview: the focus square's geometry and life (05 §8.2).
// RN: src/ui/components/TapToFocusLayer.tsx
public enum TapToFocus {
    /// The focus square's side in points (RN `FOCUS_SPOT_SIZE`).
    public static let spotSize: Double = 72
    /// How long the square stays (RN `FOCUS_SPOT_MS`); a new tap replaces it.
    public static let spotDuration: Duration = .milliseconds(700)

    /// The square's top-left corner, so it is centred on the tap rather than hanging from its
    /// corner (RN `focusSpotOffset`: `{left: x − 36, top: y − 36}`).
    // RN: src/ui/components/TapToFocusLayer.tsx:10-12
    public static func focusSpotOffset(x: Double, y: Double) -> CGPoint {
        CGPoint(x: x - spotSize / 2, y: y - spotSize / 2)
    }
}

/// What the capture device supports, read from `AVCaptureDevice` by the camera service.
public struct CameraFocusCapabilities: Sendable, Hashable {
    public var focusPointOfInterest: Bool
    public var autoFocus: Bool
    public var continuousAutoFocus: Bool
    public var exposurePointOfInterest: Bool
    public var autoExpose: Bool
    public var continuousAutoExposure: Bool

    public init(
        focusPointOfInterest: Bool,
        autoFocus: Bool,
        continuousAutoFocus: Bool,
        exposurePointOfInterest: Bool,
        autoExpose: Bool,
        continuousAutoExposure: Bool
    ) {
        self.focusPointOfInterest = focusPointOfInterest
        self.autoFocus = autoFocus
        self.continuousAutoFocus = continuousAutoFocus
        self.exposurePointOfInterest = exposurePointOfInterest
        self.autoExpose = autoExpose
        self.continuousAutoExposure = continuousAutoExposure
    }

    /// A back camera that supports everything (every iPhone back camera does).
    public static let all = CameraFocusCapabilities(
        focusPointOfInterest: true,
        autoFocus: true,
        continuousAutoFocus: true,
        exposurePointOfInterest: true,
        autoExpose: true,
        continuousAutoExposure: true
    )
}

/// `AVCaptureDevice.FocusMode` without AVFoundation (the modes the camera uses).
public enum CameraFocusMode: String, Sendable, Hashable {
    /// One-shot: focus once at the point of interest, then hold.
    case autoFocus
    case continuousAutoFocus
}

/// `AVCaptureDevice.ExposureMode` without AVFoundation (the modes the camera uses).
public enum CameraExposureMode: String, Sendable, Hashable {
    /// One-shot: meter once at the point of interest, then hold.
    case autoExpose
    case continuousAutoExposure
}

/// One `lockForConfiguration` worth of focus and exposure settings, decided as data so the
/// decision is tested without a camera (DECISIONS U7, 05 §8.4 "AVCam style").
///
/// The camera service applies a value field by field: a nil point or mode is left as it is,
/// because the device does not support it. Smooth autofocus stays off for stills (it is tuned for
/// video and slows focus pulls).
public struct CameraFocusSettings: Sendable, Hashable {
    /// The device point of interest (0…1 in sensor space, from
    /// `AVCaptureVideoPreviewLayer.captureDevicePointConverted(fromLayerPoint:)`).
    public var focusPointOfInterest: CGPoint?
    public var focusMode: CameraFocusMode?
    public var exposurePointOfInterest: CGPoint?
    public var exposureMode: CameraExposureMode?
    /// `isSubjectAreaChangeMonitoringEnabled`: on after a tap, so moving the phone ends it.
    public var subjectAreaChangeMonitoring: Bool
    /// `isSmoothAutoFocusEnabled`: always false for stills.
    public var smoothAutoFocus: Bool { false }

    public init(
        focusPointOfInterest: CGPoint?,
        focusMode: CameraFocusMode?,
        exposurePointOfInterest: CGPoint?,
        exposureMode: CameraExposureMode?,
        subjectAreaChangeMonitoring: Bool
    ) {
        self.focusPointOfInterest = focusPointOfInterest
        self.focusMode = focusMode
        self.exposurePointOfInterest = exposurePointOfInterest
        self.exposureMode = exposureMode
        self.subjectAreaChangeMonitoring = subjectAreaChangeMonitoring
    }

    /// The centre of the sensor, where the camera meters when nobody has tapped.
    public static let centre = CGPoint(x: 0.5, y: 0.5)

    /// Before any tap, and when the session is configured: continuous autofocus and exposure
    /// across the frame (RN `autofocus="off"` mapped to `.continuousAutoFocus`, issue #44).
    public static func continuous(_ device: CameraFocusCapabilities) -> CameraFocusSettings {
        settings(focus: .continuousAutoFocus, exposure: .continuousAutoExposure, at: centre, monitor: false, device)
    }

    /// A tap at `devicePoint`: one-shot autofocus and exposure there, with subject-area-change
    /// monitoring so the camera goes back to continuous when the scene changes (AVCam
    /// `focus(with: .autoFocus, exposureMode: .autoExpose, at:, monitorSubjectAreaChange: true)`).
    public static func tap(at devicePoint: CGPoint, _ device: CameraFocusCapabilities) -> CameraFocusSettings {
        settings(focus: .autoFocus, exposure: .autoExpose, at: devicePoint, monitor: true, device)
    }

    /// `AVCaptureDevice.subjectAreaDidChangeNotification`: back to continuous focus and exposure
    /// at the centre, monitoring off until the next tap.
    public static func subjectAreaChanged(_ device: CameraFocusCapabilities) -> CameraFocusSettings {
        continuous(device)
    }

    /// AVCam's rule: set a point only when the device supports both the point and the mode.
    private static func settings(
        focus: CameraFocusMode,
        exposure: CameraExposureMode,
        at point: CGPoint,
        monitor: Bool,
        _ device: CameraFocusCapabilities
    ) -> CameraFocusSettings {
        let focusSupported = switch focus {
        case .autoFocus: device.autoFocus
        case .continuousAutoFocus: device.continuousAutoFocus
        }
        let exposureSupported = switch exposure {
        case .autoExpose: device.autoExpose
        case .continuousAutoExposure: device.continuousAutoExposure
        }
        let focusApplies = device.focusPointOfInterest && focusSupported
        let exposureApplies = device.exposurePointOfInterest && exposureSupported
        return CameraFocusSettings(
            focusPointOfInterest: focusApplies ? point : nil,
            focusMode: focusApplies ? focus : nil,
            exposurePointOfInterest: exposureApplies ? point : nil,
            exposureMode: exposureApplies ? exposure : nil,
            subjectAreaChangeMonitoring: monitor
        )
    }
}

/// The focus square over the preview (RN `TapToFocusLayer`): where it is and when it goes.
///
/// The view calls ``tap(at:)`` with the tap's location in the preview's coordinate space, draws
/// the square at ``spotOrigin`` while ``spot`` is set, and hands the same layer point to the
/// camera service, which converts it with `captureDevicePointConverted(fromLayerPoint:)` and
/// applies ``CameraFocusSettings/tap(at:_:)``.
@MainActor
@Observable
public final class TapToFocusModel {
    /// The last tap, while its square is showing.
    public private(set) var spot: CGPoint?

    private let clock: any Clock<Duration>
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// The square's top-left corner, centred on ``spot``.
    public var spotOrigin: CGPoint? {
        spot.map { TapToFocus.focusSpotOffset(x: $0.x, y: $0.y) }
    }

    /// Shows the square at `point` for 700 ms; a new tap replaces it and restarts the wait.
    public func tap(at point: CGPoint) {
        spot = point
        clearTask?.cancel()
        clearTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: TapToFocus.spotDuration)
            } catch {
                return
            }
            // A newer tap cancelled this one after its wait ended: its square stays.
            guard !Task.isCancelled else { return }
            self?.spot = nil
        }
    }

    /// Takes the square away at once (the screen is going).
    public func reset() {
        clearTask?.cancel()
        clearTask = nil
        spot = nil
    }
}
