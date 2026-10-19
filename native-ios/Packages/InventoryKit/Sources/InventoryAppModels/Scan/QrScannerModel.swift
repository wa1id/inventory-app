import InventoryStrings
import Observation

/// The QR scanner shared by the Scan tab and the sticker-link cover (RN `QrScanner`, 06 §8.4),
/// without the camera: when the camera runs, which codes are handed over, the locked reticle, the
/// torch and the failure panel.
///
/// The view runs `DataScannerViewController` (or an `AVCaptureMetadataOutput`) only while
/// ``cameraRuns``, reports focus with ``focusGained()`` / ``focusLost()``, sends every recognised
/// payload to ``codeDetected(_:)``, and shows the permission gate from ``permission`` while it is
/// not granted.
@MainActor
@Observable
public final class QrScannerModel {
    /// The title pill: "Scan a label", "Scan the sticker for Tool chest".
    public let title: String
    /// The camera permission (purpose `scan`).
    public let permission: CameraPermissionModel
    /// The arming rules.
    public let scanGuard: ScanGuard

    /// The host wants the camera (RN `active`): off while a notice waits for an answer.
    public private(set) var isActive: Bool
    /// The screen is in front (focused tab, top of its stack, nothing presented over it).
    public private(set) var isFocused = false
    public private(set) var torchOn = false
    /// The reticle shows the accent: a code was read and is being handed over.
    public private(set) var isLocked = false
    /// The camera did not start: the failure panel replaces the footer and the torch.
    public private(set) var mountFailed = false
    /// Reduce Motion: the 250 ms reticle lock becomes 0.
    public var reduceMotion = false

    /// Called once per accepted scan with the raw payload, after the reticle lock.
    @ObservationIgnored public var onScan: (@MainActor (String) async -> Void)?

    private let clock: any Clock<Duration>
    private let torchLabelOn: String?
    private let torchLabelOff: String?

    /// - Parameters:
    ///   - active: The host's initial `active` (no arming for it: focus arms).
    ///   - torchLabelOn: Overrides `strings.camera.torchState(on: true)`.
    ///   - torchLabelOff: Overrides `strings.camera.torchState(on: false)`.
    public init(
        title: String,
        permission: CameraPermissionModel,
        active: Bool = true,
        torchLabelOn: String? = nil,
        torchLabelOff: String? = nil,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.title = title
        self.permission = permission
        isActive = active
        self.torchLabelOn = torchLabelOn
        self.torchLabelOff = torchLabelOff
        self.clock = clock
        scanGuard = ScanGuard(clock: clock)
    }

    /// Run the camera only while in front and active: a background tab must not hold it (battery,
    /// the camera light, other apps).
    public var cameraRuns: Bool { isFocused && isActive && permission.isGranted }

    /// The torch button is shown (hidden once the camera failed to start).
    public var showsTorch: Bool { !mountFailed }

    /// The host's footer is drawn (only while the camera is up and has not failed).
    public var showsFooter: Bool { !mountFailed }

    /// The torch button's label: the state it is in.
    public var torchLabel: String {
        torchOn
            ? torchLabelOn ?? L10n.Camera.torchState(on: true)
            : torchLabelOff ?? L10n.Camera.torchState(on: false)
    }

    /// The screen came to the front: a new arming that ignores the last code for a moment.
    public func focusGained() {
        isFocused = true
        scanGuard.focused()
    }

    /// The screen left the front: the torch goes off.
    public func focusLost() {
        isFocused = false
        torchOn = false
    }

    /// The host's `active` changed; turning on again is a new arming.
    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active { scanGuard.reactivated() }
    }

    public func toggleTorch() {
        torchOn.toggle()
    }

    /// The camera could not start.
    public func cameraFailedToStart() {
        mountFailed = true
    }

    /// A payload the camera recognised. Accepted at most once per arming: the reticle locks, holds
    /// for 250 ms (0 under Reduce Motion), then ``onScan`` runs; the lock clears when it finishes.
    // RN: src/ui/components/QrScanner.tsx:113-137
    public func codeDetected(_ raw: String) async {
        guard scanGuard.accept(raw) else { return }
        isLocked = true
        let wait = Motion.motionMs(Motion.duration.reticleLock, reduced: reduceMotion)
        if wait > 0 {
            try? await clock.sleep(for: .milliseconds(wait))
        }
        await onScan?(raw)
        isLocked = false
    }
}
