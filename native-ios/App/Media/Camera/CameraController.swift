import AVFoundation
import CoreGraphics
import InventoryAppModels
import InventoryServices
import UIKit

/// The camera as the capture screen and the QR scanner use it: one ``CameraSession`` on its own
/// queue, its preview, the rotation coordinator, and events delivered on the main actor.
///
/// Create one per screen and keep it for the screen's life (it is cheap until it first runs).
/// ``CameraPreview`` attaches the preview and starts and stops the session with the screen and
/// the scene. Wire the capture screen's events with `reportEvents(to:)`; `QrScannerView` wires
/// the scanner's through ``QrScannerBridge``.
///
/// Capture: `await model.shutterPressed { try await camera.capturePhoto(flashOn: model.flashOn) }`.
@MainActor
final class CameraController {
    let use: CameraUse

    /// Every session event, on the main actor.
    var onEvent: (@MainActor (CameraFeedEvent) -> Void)?
    /// QR payloads read in one frame (``CameraUse/qrCodes`` only).
    var onCodes: (@MainActor ([String]) -> Void)?

    /// The last event the session reported.
    private(set) var lastEvent: CameraFeedEvent?

    private let discover: @Sendable () -> CameraDeviceHandle?
    private var sessionStorage: CameraSession?
    private var signalsTask: Task<Void, Never>?
    private weak var preview: CameraPreviewUIView?
    private var device: CameraDeviceHandle?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    /// - Parameters:
    ///   - use: Stills or QR codes.
    ///   - discover: Finds the camera (``CameraDiscovery/backCamera()``); pass `{ nil }` to act
    ///     like a device without one.
    init(use: CameraUse, discover: @escaping @Sendable () -> CameraDeviceHandle? = CameraDiscovery.backCamera) {
        self.use = use
        self.discover = discover
    }

    /// The session, made on first use.
    private var session: CameraSession {
        if let sessionStorage { return sessionStorage }
        let created = CameraSession(use: use, discover: discover)
        sessionStorage = created
        listen(to: created)
        return created
    }

    /// Whether the session is running now, as last reported.
    var isRunning: Bool { lastEvent == .running }

    // MARK: Running

    /// Runs or stops the session. The last call wins, however the hops to the camera queue are
    /// ordered.
    func setRunning(_ running: Bool) {
        let session = session
        let changed = session.desire.withLock { desire in
            defer { desire.running = running }
            return desire.running != running
        }
        guard changed || running else { return }
        Task { await session.reconcile() }
    }

    /// The scanner's torch; applied while the session runs and again after a restart.
    func setTorch(_ on: Bool) {
        let session = session
        session.desire.withLock { $0.torch = on }
        Task { await session.reconcile() }
    }

    // MARK: Preview

    /// Shows the session in `view` (``CameraPreviewLayerView`` calls this).
    ///
    /// A new view (SwiftUI rebuilt the preview while this controller lived on) gets its own
    /// rotation coordinator: the coordinator follows one preview layer, and a coordinator left on
    /// the old, detached layer would stop turning the picture on iPad and give the crop a stale
    /// preview angle.
    func attach(_ view: CameraPreviewUIView) {
        guard preview !== view else { return }
        dropRotationCoordinator()
        preview = view
        view.previewLayer?.session = session.hardware.session
        view.previewLayer?.videoGravity = .resizeAspectFill
        makeRotationCoordinator()
    }

    /// The view is gone (``CameraPreviewLayerView`` dismantled it): it lets go of the session,
    /// and of the rotation coordinator if it was the one showing it.
    func detach(_ view: CameraPreviewUIView) {
        view.previewLayer?.session = nil
        guard preview === view else { return }
        dropRotationCoordinator()
        preview = nil
    }

    /// A tap on the preview at `point` (the preview's own coordinates): converted to the device
    /// point on the main actor, then applied on the camera queue (05 §8.2-8.4).
    func focus(atLayerPoint point: CGPoint) {
        guard let layer = preview?.previewLayer, layer.session != nil, isRunning else { return }
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: point)
        guard devicePoint.x.isFinite, devicePoint.y.isFinite else { return }
        let session = session
        Task { await session.focus(at: devicePoint) }
    }

    // MARK: Capture

    /// Takes a still for `CaptureModel.shutterPressed(capture:)`: the bytes, and the crop that keeps
    /// what the preview showed (``ImageStore/previewCropAspect(previewSize:previewRotationAngle:captureRotationAngle:)``,
    /// DECISIONS U7). Throws ``CameraCaptureError`` when the camera is not ready or busy, or the
    /// capture's own error.
    func capturePhoto(flashOn: Bool) async throws -> CapturedPhoto? {
        let previewAngle = rotationCoordinator.map { Double($0.videoRotationAngleForHorizonLevelPreview) }
        let captureAngle = rotationCoordinator.map { Double($0.videoRotationAngleForHorizonLevelCapture) }
        let previewSize = preview?.bounds.size ?? .zero
        guard let data = try await session.capture(flashOn: flashOn, rotationAngle: captureAngle) else { return nil }
        return CapturedPhoto(
            data: data,
            cropAspect: Self.cropAspect(previewSize: previewSize, previewAngle: previewAngle, captureAngle: captureAngle)
        )
    }

    /// The crop for a still: nil (keep everything) without a measured preview or rotation.
    static func cropAspect(previewSize: CGSize, previewAngle: Double?, captureAngle: Double?) -> CGSize? {
        guard previewSize.width > 0, previewSize.height > 0, let previewAngle, let captureAngle else { return nil }
        return ImageStore.previewCropAspect(
            previewSize: previewSize,
            previewRotationAngle: previewAngle,
            captureRotationAngle: captureAngle
        )
    }

    // MARK: Signals

    private func listen(to session: CameraSession) {
        let signals = session.signals
        signalsTask = Task { [weak self] in
            for await signal in signals {
                guard let self else { return }
                self.handle(signal)
            }
        }
    }

    private func handle(_ signal: CameraSession.Signal) {
        switch signal {
        case .event(let event):
            lastEvent = event
            onEvent?(event)
        case .configured(let handle):
            device = handle
            makeRotationCoordinator()
        case .codes(let codes):
            onCodes?(codes)
        }
    }

    // MARK: Rotation

    /// Keeps the preview horizon-level as the interface turns (any orientation on iPad, DECISIONS
    /// U4), and supplies the capture rotation for each still. The coordinator needs both the
    /// configured device and the attached preview.
    private func makeRotationCoordinator() {
        guard rotationCoordinator == nil, let device, let layer = preview?.previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device.device, previewLayer: layer)
        rotationCoordinator = coordinator
        // The coordinator delivers its KVO updates on the main queue (AVCaptureDevice.h).
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            MainActor.assumeIsolated {
                self?.applyPreviewRotation(angle)
            }
        }
    }

    private func dropRotationCoordinator() {
        rotationObservation?.invalidate()
        rotationObservation = nil
        rotationCoordinator = nil
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = preview?.previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }
}

extension CameraController {
    /// Sends every session event to `handler`, starting with the last one already reported, so a
    /// host that wires itself up after the session started (or failed) still learns its state.
    func deliverEvents(to handler: @escaping @MainActor (CameraFeedEvent) -> Void) {
        onEvent = handler
        if let lastEvent { handler(lastEvent) }
    }

    /// Reports the session to the capture screen's model: running, stopped (the shutter waits) and
    /// failed to start (`strings.capture.didNotStart`). A model wired late still hears the current
    /// state; otherwise `CaptureModel` would think the camera is not running and ignore the shutter.
    func reportEvents(to model: CaptureModel) {
        deliverEvents { [weak model] event in
            switch event {
            case .running: model?.sessionStarted()
            case .stopped: model?.sessionStopped()
            case .failedToStart: model?.cameraFailedToStart()
            }
        }
    }
}

/// The view `AVCaptureVideoPreviewLayer` draws into, full-bleed and aspect-filled (05 §8.3).
final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        nil
    }
}
