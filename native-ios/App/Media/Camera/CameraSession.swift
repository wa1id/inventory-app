import AVFoundation
import CoreGraphics
import InventoryAppModels
import InventoryCore
import os
import Synchronization

/// What a camera session is set up for.
enum CameraUse: Sendable, Hashable {
    /// Stills for the capture screen: `AVCapturePhotoOutput` (05 §8.3).
    case photo
    /// QR labels for the Scan tab and the sticker-link cover: `AVCaptureMetadataOutput` with `.qr`
    /// only (06 §8.4, the AVFoundation alternative to DataScanner: every device, and the torch).
    case qrCodes
}

/// What the camera tells its screen. Hosts map these onto their model: `CaptureModel`
/// `sessionStarted()` / `sessionStopped()` / `cameraFailedToStart()`, or `QrScannerModel`
/// `cameraFailedToStart()`.
enum CameraFeedEvent: Sendable, Hashable {
    /// The session runs and delivers frames (also after an interruption ends).
    case running
    /// The session stopped or was interrupted (background, a call, another app, multitasking).
    case stopped
    /// The camera could not be configured or started, or there is none (the simulator). Not sent
    /// for a `mediaServicesWereReset` that the session recovers from (05 §8.3).
    case failedToStart
}

/// Why a still could not be taken.
enum CameraCaptureError: Error, Sendable, Equatable {
    /// The session is not running (yet), is interrupted, or has no photo output.
    case notRunning
    /// A still is already being taken.
    case busy
}

/// The camera's own log category; dynamic values stay private (09 §11).
enum MediaLog {
    static let camera = Logger(subsystem: InventoryLog.subsystem, category: "camera")
}

/// The AVFoundation objects that leave the camera actor, and why that is safe.
///
/// `AVCaptureSession` and `AVCaptureDevice` are not `Sendable`. Everything that configures,
/// starts, stops or locks them runs on ``CameraSession``'s serial queue. Exactly two main-actor
/// uses cross over, both of which AVFoundation supports from the main thread:
/// - `AVCaptureVideoPreviewLayer.session = session` (and the layer's own connection rotation),
///   as Apple's AVCam does;
/// - `AVCaptureDevice.RotationCoordinator(device:previewLayer:)`, which only observes the device
///   and delivers its KVO updates on the main queue (AVCaptureDevice.h).
struct CameraHardware: @unchecked Sendable {
    let session: AVCaptureSession
}

/// The device handed to the main actor for its rotation coordinator (see ``CameraHardware``).
struct CameraDeviceHandle: @unchecked Sendable {
    let device: AVCaptureDevice
}

/// A NotificationCenter observer token. Opaque: it is only ever handed back to
/// `NotificationCenter.removeObserver(_:)`, which is thread-safe, so it may be kept outside the
/// actor for `deinit`.
struct CameraObserverToken: @unchecked Sendable {
    let token: any NSObjectProtocol
}

/// Finds the back camera (05 §8.1): the first available of the virtual multi-camera devices, so a
/// close subject switches to the ultra-wide lens by itself, then the wide-angle camera, then the
/// system's preferred camera. Nil on the simulator, which has no camera.
enum CameraDiscovery {
    // RN: patches/expo-camera+57.0.3.patch:219-238
    static let preference: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera,
        .builtInDualWideCamera,
        .builtInDualCamera,
        .builtInWideAngleCamera,
    ]

    static func backCamera() -> CameraDeviceHandle? {
        for type in preference {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) {
                return CameraDeviceHandle(device: device)
            }
        }
        return AVCaptureDevice.systemPreferredCamera.map(CameraDeviceHandle.init)
    }
}

/// One `AVCaptureSession` on its own serial queue (Apple's AVCam pattern: an actor whose executor
/// is a `DispatchSerialQueue`), so `startRunning()` and device configuration never block the main
/// actor.
///
/// **Sendable boundary.** Only `Sendable` values cross in or out: `Bool`, `Double`, `CGPoint`,
/// `Data`, ``CameraFeedEvent`` and the code strings on ``signals``. The two documented exceptions
/// are ``CameraHardware`` and ``CameraDeviceHandle``.
///
/// What the main actor wants (running, torch) is kept in ``desire`` and applied by
/// ``reconcile()``, so a quick appear-then-disappear always ends in the last state asked for,
/// whatever order the hops arrive in.
actor CameraSession {
    /// A signal from the camera queue, in order.
    enum Signal: Sendable {
        case event(CameraFeedEvent)
        /// The device is configured; the main actor can build its rotation coordinator.
        case configured(CameraDeviceHandle)
        /// QR payloads read in one frame.
        case codes([String])
    }

    /// What the main actor last asked for.
    struct Desire: Sendable, Equatable {
        var running = false
        var torch = false
    }

    nonisolated let use: CameraUse
    nonisolated let hardware = CameraHardware(session: AVCaptureSession())
    nonisolated let signals: AsyncStream<Signal>
    nonisolated let desire = Mutex(Desire())

    private nonisolated let queue: DispatchSerialQueue
    private nonisolated let continuation: AsyncStream<Signal>.Continuation
    private nonisolated let discover: @Sendable () -> CameraDeviceHandle?
    /// NotificationCenter tokens, removed in `deinit` (which cannot reach isolated state).
    private nonisolated let observers = Mutex<[CameraObserverToken]>([])

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private enum Setup {
        case notYet
        case ready(AVCaptureDevice)
        case failed
    }

    private var setup = Setup.notYet
    private var photoOutput: AVCapturePhotoOutput?
    private var metadataReceiver: QrMetadataReceiver?
    private var inFlightCapture: PhotoCaptureReceiver?

    /// - Parameter discover: Finds the camera; ``CameraDiscovery/backCamera()`` by default, nil to
    ///   act like a phone without one (tests).
    init(use: CameraUse, discover: @escaping @Sendable () -> CameraDeviceHandle? = CameraDiscovery.backCamera) {
        self.use = use
        self.discover = discover
        queue = DispatchSerialQueue(label: "com.wystudio.inventory.camera", qos: .userInitiated)
        let stream = AsyncStream.makeStream(of: Signal.self, bufferingPolicy: .bufferingNewest(64))
        signals = stream.stream
        continuation = stream.continuation
    }

    deinit {
        observers.withLock { tokens in
            for observer in tokens { NotificationCenter.default.removeObserver(observer.token) }
            tokens.removeAll()
        }
        if hardware.session.isRunning { hardware.session.stopRunning() }
        continuation.finish()
    }

    // MARK: Running

    /// Applies ``desire``: configures on the first start, starts or stops the session, and sets
    /// the torch.
    func reconcile() {
        let wanted = desire.withLock { $0 }
        if wanted.running {
            start()
        } else {
            stop()
        }
        applyTorch(wanted.torch)
    }

    private var session: AVCaptureSession { hardware.session }

    private func start() {
        guard configuredDevice() != nil else {
            emit(.failedToStart)
            return
        }
        guard !session.isRunning else { return }
        session.startRunning()
        // A start that is interrupted at once (another app holds the camera) still runs; one
        // that failed outright did not.
        if !session.isRunning, !session.isInterrupted {
            MediaLog.camera.error("capture session did not start")
            emit(.failedToStart)
        }
    }

    private func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
    }

    private func emit(_ event: CameraFeedEvent) {
        continuation.yield(.event(event))
    }

    // MARK: Configuration

    /// The configured device, configuring the session on first use. Nil when there is no camera
    /// or the session cannot take it; a later start tries again.
    private func configuredDevice() -> AVCaptureDevice? {
        switch setup {
        case .ready(let device):
            return device
        case .notYet, .failed:
            break
        }
        guard let handle = discover() else {
            MediaLog.camera.debug("no camera on this device")
            setup = .failed
            return nil
        }
        do {
            try configure(handle.device)
            setup = .ready(handle.device)
            observe(handle.device)
            continuation.yield(.configured(handle))
            return handle.device
        } catch {
            MediaLog.camera.error("camera configuration failed: \(String(describing: type(of: error)), privacy: .public)")
            setup = .failed
            return nil
        }
    }

    private struct ConfigurationError: Error {}

    /// Builds the session in one configuration pass (05 §8.3): the device input, then the photo
    /// output with its quality ceiling raised before the session ever starts (C5), or the QR
    /// metadata output; the wide-angle zoom baseline; continuous autofocus and exposure.
    private func configure(_ device: AVCaptureDevice) throws {
        session.beginConfiguration()
        var added: (input: AVCaptureInput?, output: AVCaptureOutput?) = (nil, nil)
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw ConfigurationError() }
            session.addInput(input)
            added.input = input

            switch use {
            case .photo:
                if session.canSetSessionPreset(.photo) {
                    session.sessionPreset = .photo
                } else if session.canSetSessionPreset(.high) {
                    session.sessionPreset = .high
                }
                let output = AVCapturePhotoOutput()
                guard session.canAddOutput(output) else { throw ConfigurationError() }
                session.addOutput(output)
                added.output = output
                configurePhotoOutput(output)
                photoOutput = output
            case .qrCodes:
                if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
                let output = AVCaptureMetadataOutput()
                guard session.canAddOutput(output) else { throw ConfigurationError() }
                session.addOutput(output)
                added.output = output
                // The types become available once the output is on the session.
                guard output.availableMetadataObjectTypes.contains(.qr) else { throw ConfigurationError() }
                let receiver = QrMetadataReceiver(continuation: continuation)
                output.setMetadataObjectsDelegate(receiver, queue: queue)
                output.metadataObjectTypes = [.qr]
                metadataReceiver = receiver
            }
            try configureDevice(device)
        } catch {
            if let output = added.output { session.removeOutput(output) }
            if let input = added.input { session.removeInput(input) }
            photoOutput = nil
            metadataReceiver = nil
            session.commitConfiguration()
            throw error
        }
        session.commitConfiguration()
    }

    /// DECISIONS U7 and 05 §8.3: quality first, never zero shutter lag (it can fire before
    /// autofocus settles), no Live Photo, no deferred or responsive capture.
    private func configurePhotoOutput(_ output: AVCapturePhotoOutput) {
        // C5: a per-shot prioritization above this ceiling raises; raise it before running.
        output.maxPhotoQualityPrioritization = .quality
        if output.isLivePhotoCaptureSupported { output.isLivePhotoCaptureEnabled = false }
        if output.isZeroShutterLagSupported { output.isZeroShutterLagEnabled = false }
        if output.isResponsiveCaptureSupported { output.isResponsiveCaptureEnabled = false }
        if output.isFastCapturePrioritizationSupported { output.isFastCapturePrioritizationEnabled = false }
        if output.isAutoDeferredPhotoDeliverySupported { output.isAutoDeferredPhotoDeliveryEnabled = false }
    }

    private func configureDevice(_ device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.videoZoomFactor = CameraZoomBaseline.factor(
            switchOverFactors: device.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue),
            minAvailable: device.minAvailableVideoZoomFactor,
            maxAvailable: device.maxAvailableVideoZoomFactor
        )
        Self.apply(.continuous(Self.capabilities(of: device)), to: device)
    }

    // MARK: Notifications

    /// Interruptions (calls, another app using the camera, multitasking), runtime errors and
    /// subject-area changes. The blocks run on the posting thread and only pass Sendable values on.
    private func observe(_ device: AVCaptureDevice) {
        let center = NotificationCenter.default
        let continuation = continuation
        var tokens: [CameraObserverToken] = []
        tokens.append(CameraObserverToken(token: center.addObserver(forName: AVCaptureSession.didStartRunningNotification, object: session, queue: nil) { [weak self] _ in
            continuation.yield(.event(.running))
            Task { await self?.reapplyTorch() }
        }))
        tokens.append(CameraObserverToken(token: center.addObserver(forName: AVCaptureSession.didStopRunningNotification, object: session, queue: nil) { _ in
            continuation.yield(.event(.stopped))
        }))
        tokens.append(CameraObserverToken(token: center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { _ in
            continuation.yield(.event(.stopped))
        }))
        tokens.append(CameraObserverToken(token: center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            Task { await self?.interruptionEnded() }
        }))
        tokens.append(CameraObserverToken(token: center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
            let code = (notification.userInfo?[AVCaptureSessionErrorKey] as? AVError)?.code
            Task { await self?.runtimeError(code) }
        }))
        tokens.append(CameraObserverToken(token: center.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: device, queue: nil) { [weak self] _ in
            Task { await self?.subjectAreaChanged() }
        }))
        let added = tokens
        observers.withLock { $0.append(contentsOf: added) }
    }

    private func interruptionEnded() {
        // The session resumes by itself once the interruption ends.
        if session.isRunning, !session.isInterrupted { emit(.running) }
    }

    /// A runtime error stops the session. `mediaServicesWereReset` (and any other error) is
    /// answered with a restart when the screen still wants the camera; only a restart that fails
    /// says the camera did not start (05 §8.3; RN showed it even after a recovery).
    private func runtimeError(_ code: AVError.Code?) {
        MediaLog.camera.error("capture session runtime error \(code?.rawValue ?? 0, privacy: .public)")
        guard desire.withLock({ $0.running }) else { return }
        if !session.isRunning { session.startRunning() }
        if !session.isRunning, !session.isInterrupted { emit(.failedToStart) }
    }

    /// AVCam: once the scene changes after a tap, back to continuous focus and exposure.
    private func subjectAreaChanged() {
        guard case .ready(let device) = setup else { return }
        Self.apply(.subjectAreaChanged(Self.capabilities(of: device)), to: device)
    }

    // MARK: Focus

    /// A tap on the preview, already converted to a device point (0…1, sensor space): one-shot
    /// autofocus and exposure there, then subject-area monitoring (DECISIONS U7).
    func focus(at devicePoint: CGPoint) {
        guard case .ready(let device) = setup else { return }
        Self.apply(.tap(at: devicePoint, Self.capabilities(of: device)), to: device)
    }

    static func capabilities(of device: AVCaptureDevice) -> CameraFocusCapabilities {
        CameraFocusCapabilities(
            focusPointOfInterest: device.isFocusPointOfInterestSupported,
            autoFocus: device.isFocusModeSupported(.autoFocus),
            continuousAutoFocus: device.isFocusModeSupported(.continuousAutoFocus),
            exposurePointOfInterest: device.isExposurePointOfInterestSupported,
            autoExpose: device.isExposureModeSupported(.autoExpose),
            continuousAutoExposure: device.isExposureModeSupported(.continuousAutoExposure)
        )
    }

    /// One `lockForConfiguration` with the settings decided in InventoryAppModels. The point goes
    /// before the mode: setting a point does not start a focus pass, setting the mode does.
    static func apply(_ settings: CameraFocusSettings, to device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
        } catch {
            MediaLog.camera.error("focus lock failed")
            return
        }
        defer { device.unlockForConfiguration() }
        if let point = settings.focusPointOfInterest { device.focusPointOfInterest = point }
        if let mode = settings.focusMode {
            device.focusMode = switch mode {
            case .autoFocus: .autoFocus
            case .continuousAutoFocus: .continuousAutoFocus
            }
        }
        if let point = settings.exposurePointOfInterest { device.exposurePointOfInterest = point }
        if let mode = settings.exposureMode {
            device.exposureMode = switch mode {
            case .autoExpose: .autoExpose
            case .continuousAutoExposure: .continuousAutoExposure
            }
        }
        device.isSubjectAreaChangeMonitoringEnabled = settings.subjectAreaChangeMonitoring
        // Tuned for video; it slows focus pulls for stills (05 §8.4).
        if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = settings.smoothAutoFocus }
    }

    // MARK: Torch

    private func reapplyTorch() {
        applyTorch(desire.withLock { $0.torch })
    }

    /// The scanner's torch (06 §8.4). It only burns while the session runs; the system turns it off
    /// when the session stops, and a restart turns it back on if it is still wanted.
    private func applyTorch(_ on: Bool) {
        guard use == .qrCodes, case .ready(let device) = setup, device.hasTorch, session.isRunning else { return }
        let mode: AVCaptureDevice.TorchMode = on ? .on : .off
        guard device.torchMode != mode, device.isTorchModeSupported(mode) else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = mode
            device.unlockForConfiguration()
        } catch {
            MediaLog.camera.error("torch lock failed")
        }
    }

    // MARK: Capture

    /// Takes one still (05 §8.3): HEVC when available, the flash when asked and supported, quality
    /// prioritization never above the output's ceiling (C5), the output's largest dimensions, and
    /// the capture rotation the main actor's rotation coordinator gave. Returns the
    /// `fileDataRepresentation()` bytes for the image store (no JPEG intermediate), or nil when the
    /// camera gave none.
    func capture(flashOn: Bool, rotationAngle: Double?) async throws -> Data? {
        guard let output = photoOutput, session.isRunning, !session.isInterrupted else {
            throw CameraCaptureError.notRunning
        }
        guard inFlightCapture == nil else { throw CameraCaptureError.busy }

        let settings = output.availablePhotoCodecTypes.contains(.hevc)
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            : AVCapturePhotoSettings()
        let flash: AVCaptureDevice.FlashMode = flashOn ? .on : .off
        settings.flashMode = output.supportedFlashModes.contains(flash) ? flash : .off
        settings.photoQualityPrioritization = Self.prioritization(requested: .quality, ceiling: output.maxPhotoQualityPrioritization)
        settings.maxPhotoDimensions = output.maxPhotoDimensions
        if let rotationAngle, let connection = output.connection(with: .video),
           connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }

        defer { inFlightCapture = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let receiver = PhotoCaptureReceiver(continuation: continuation)
            inFlightCapture = receiver
            output.capturePhoto(with: settings, delegate: receiver)
        }
    }

    /// The per-shot prioritization: the one asked for, capped at the output's ceiling, because a
    /// higher one raises `NSInvalidArgumentException` (05 C5).
    static func prioritization(
        requested: AVCapturePhotoOutput.QualityPrioritization,
        ceiling: AVCapturePhotoOutput.QualityPrioritization
    ) -> AVCapturePhotoOutput.QualityPrioritization {
        requested.rawValue <= ceiling.rawValue ? requested : ceiling
    }
}

/// Receives one still and resumes its continuation exactly once: with the photo's bytes when it is
/// processed (which is when the shutter is free again), or with the error.
private final class PhotoCaptureReceiver: NSObject, AVCapturePhotoCaptureDelegate, Sendable {
    private let continuation: Mutex<CheckedContinuation<Data?, any Error>?>

    init(continuation: CheckedContinuation<Data?, any Error>) {
        self.continuation = Mutex(continuation)
    }

    private func finish(_ result: Result<Data?, any Error>) {
        continuation.withLock { pending in
            pending?.resume(with: result)
            pending = nil
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        if let error {
            finish(.failure(error))
        } else {
            finish(.success(photo.fileDataRepresentation()))
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: (any Error)?
    ) {
        // Normally the photo has already answered; this covers a capture that ended without one.
        finish(error.map { .failure($0) } ?? .success(nil))
    }
}

/// Passes the QR payloads of each frame on, as strings, from the camera queue.
private final class QrMetadataReceiver: NSObject, AVCaptureMetadataOutputObjectsDelegate, Sendable {
    private let continuation: AsyncStream<CameraSession.Signal>.Continuation

    init(continuation: AsyncStream<CameraSession.Signal>.Continuation) {
        self.continuation = continuation
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let codes = metadataObjects.compactMap { object -> String? in
            guard object.type == .qr, let code = object as? AVMetadataMachineReadableCodeObject else { return nil }
            return code.stringValue
        }
        guard !codes.isEmpty else { return }
        continuation.yield(.codes(codes))
    }
}
