import InventoryAppModels
import InventoryCore
import SwiftUI
import UIKit

/// What the capture screen needs from a camera: the live ``CameraController``, or in Debug
/// builds the stand-in the simulator, previews and hosted tests use (the simulator has no
/// camera, 05 §8.3).
@MainActor
protocol CaptureCameraFeed: AnyObject {
    /// Tells `model` when the session runs, stops or fails to start, starting with what it
    /// already reported (`CameraController.reportEvents(to:)`).
    func reportEvents(to model: CaptureModel)
    /// Takes a still for `CaptureModel.shutterPressed(capture:)`.
    func capturePhoto(flashOn: Bool) async throws -> CapturedPhoto?
    /// The picture: it runs while shown, `runs` holds and the app is not in the background; a
    /// tap focuses there and draws the square from `focus`.
    func preview(runs: Bool, focus: TapToFocusModel) -> AnyView
}

extension CameraController: CaptureCameraFeed {
    func preview(runs: Bool, focus: TapToFocusModel) -> AnyView {
        AnyView(CameraPreview(camera: self, runs: runs, focus: focus))
    }
}

/// Where a new capture screen gets its camera and its permission.
@MainActor
enum CaptureCameraSource {
    /// One camera per screen, kept for the screen's life.
    static func makeFeed() -> any CaptureCameraFeed {
        #if DEBUG
        CaptureDemo.installDefaultStandIn()
        if let standIn = CaptureStandIn.current {
            let feed = CaptureStandInFeed(script: standIn.script)
            CaptureStandIn.lastFeed = feed
            return feed
        }
        #endif
        return CameraController(use: .photo)
    }

    /// The screen's permission gate (purpose `capture`).
    static func makePermission(app: AppContainer) -> CameraPermissionModel {
        #if DEBUG
        CaptureDemo.installDefaultStandIn()
        if let standIn = CaptureStandIn.current, let permission = standIn.permission {
            return permission.model(telemetry: app.telemetry)
        }
        #endif
        return app.makeCameraPermission(purpose: .capture)
    }
}

#if DEBUG
/// Debug builds only: what stands in for the camera hardware, when anything does.
///
/// Set by `CaptureDemo` for `-demo YES` on the simulator (which has no camera) and by the hosted
/// tests; nil (the default) keeps the real camera and the real permission.
@MainActor
enum CaptureStandIn {
    struct Configuration {
        /// A permission of its own (the demo's gate states); nil reads the app's.
        var permission: CaptureStandInPermission?
        /// What the stand-in camera does by itself once it runs.
        var script = CaptureStandInFeed.Script()
    }

    static var current: Configuration?
    /// The stand-in the newest capture screen got (hosted tests watch it run and stop).
    static weak var lastFeed: CaptureStandInFeed?
}

/// A camera permission the demo sets: Allow grants it, so the gate gives way to the stand-in.
@MainActor
final class CaptureStandInPermission {
    var status: CameraAuthorization

    init(_ status: CameraAuthorization) {
        self.status = status
    }

    func model(telemetry: TelemetryReporter) -> CameraPermissionModel {
        CameraPermissionModel(
            purpose: .capture,
            readAuthorization: { [self] in status },
            requestAccess: { [self] in await grant() },
            telemetry: telemetry
        )
    }

    private func grant() -> Bool {
        guard status == .notDetermined else { return false }
        status = .authorized
        return true
    }
}

/// A camera with no hardware behind it: it runs as soon as it is shown, draws a stand-in scene,
/// and hands back a drawn photo for each shot, so the capture flow works on the simulator.
///
/// A ``Script`` can make it fail to start, turn the flash on, and press the shutter by itself
/// (good shots, a still that cannot be stored, a capture that throws), so each camera state can
/// be screenshotted without a tap.
@MainActor
final class CaptureStandInFeed: CaptureCameraFeed {
    enum Shot: Sendable {
        /// A drawn photo.
        case photo
        /// Bytes no image decoder reads: the photo store fails, so a fast pipeline drops it.
        case unreadable
        /// The capture throws (`strings.capture.noPhoto`).
        case fails
    }

    struct Script {
        var failsToStart = false
        var flashOn = false
        /// Shutter presses, in order, once the camera runs.
        var shots: [Shot] = []
        /// Presses Done after the last shot (hosted tests).
        var finishes = false
        /// Before the first step and between steps.
        var pause: Duration = .milliseconds(800)
    }

    let script: Script
    private weak var model: CaptureModel?
    private var event: CameraFeedEvent?
    private var scriptStarted = false
    private var queued: [Shot] = []
    private(set) var shotsTaken = 0

    init(script: Script = Script()) {
        self.script = script
    }

    func reportEvents(to model: CaptureModel) {
        self.model = model
        if let event { deliver(event) }
    }

    func setRunning(_ running: Bool) {
        let next: CameraFeedEvent = running ? (script.failsToStart ? .failedToStart : .running) : .stopped
        guard next != event else { return }
        event = next
        deliver(next)
        if next == .running { startScript() }
    }

    func capturePhoto(flashOn: Bool) async throws -> CapturedPhoto? {
        guard event == .running else { throw CameraCaptureError.notRunning }
        let shot = queued.isEmpty ? Shot.photo : queued.removeFirst()
        // About as long as a real still takes to come back.
        try await Task.sleep(for: .milliseconds(150))
        shotsTaken += 1
        switch shot {
        case .photo:
            return CapturedPhoto(data: Self.photoData(index: shotsTaken), cropAspect: nil)
        case .unreadable:
            return CapturedPhoto(data: Data("not a photo".utf8), cropAspect: nil)
        case .fails:
            throw CameraCaptureError.busy
        }
    }

    func preview(runs: Bool, focus: TapToFocusModel) -> AnyView {
        AnyView(CaptureStandInPreview(feed: self, runs: runs, focus: focus))
    }

    private func deliver(_ event: CameraFeedEvent) {
        switch event {
        case .running: model?.sessionStarted()
        case .stopped: model?.sessionStopped()
        case .failedToStart: model?.cameraFailedToStart()
        }
    }

    /// Whether the stand-in runs now (the screen is in front and shown).
    var isRunning: Bool { event == .running }

    private func startScript() {
        guard !scriptStarted, script.flashOn || script.finishes || !script.shots.isEmpty else { return }
        scriptStarted = true
        let script = script
        Task { [weak self] in
            try? await Task.sleep(for: script.pause)
            guard let self, let model = self.model else { return }
            if script.flashOn { model.toggleFlash() }
            for shot in script.shots {
                self.queued.append(shot)
                await model.shutterPressed { [weak self, weak model] in
                    guard let self, let model else { return nil }
                    return try await self.capturePhoto(flashOn: model.flashOn)
                }
                try? await Task.sleep(for: script.pause)
            }
            if script.finishes { model.finishFast() }
        }
    }

    /// A 900 × 1200 JPEG: a soft background with a round "thing" in the middle, a different hue
    /// per shot.
    static func photoData(index: Int) -> Data {
        let hues: [CGFloat] = [0.08, 0.58, 0.33, 0.92, 0.16]
        let hue = hues[index % hues.count]
        let size = CGSize(width: 900, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.85) { context in
            UIColor(hue: hue, saturation: 0.2, brightness: 0.88, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(hue: hue, saturation: 0.6, brightness: 0.55, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 180, y: 330, width: 540, height: 540))
        }
    }
}

/// The stand-in's picture: a dim shelf scene that runs the stand-in camera like
/// ``CameraPreview`` runs a real one, with the same tap-to-focus layer.
private struct CaptureStandInPreview: View {
    let feed: CaptureStandInFeed
    let runs: Bool
    let focus: TapToFocusModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var isShown = false

    var body: some View {
        CaptureStandInScene()
            .overlay {
                CameraTapToFocusLayer(focus: focus) { _ in }
            }
            .onAppear { isShown = true }
            .onDisappear { isShown = false }
            .onChange(of: isShown && runs && scenePhase != .background, initial: true) { _, run in
                feed.setRunning(run)
            }
    }
}

/// A made-up scene: a wall, a shelf and a few boxes, darker at the bottom like a room.
private struct CaptureStandInScene: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [Color(white: 0.62), Color(white: 0.42), Color(white: 0.16)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                Rectangle()
                    .fill(Color(red: 0.45, green: 0.33, blue: 0.22))
                    .frame(width: size.width, height: 18)
                    .offset(y: size.height * 0.62)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.72, green: 0.56, blue: 0.36))
                    .frame(width: size.width * 0.34, height: size.height * 0.2)
                    .offset(x: size.width * 0.12, y: size.height * 0.42)
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(red: 0.35, green: 0.48, blue: 0.62))
                    .frame(width: size.width * 0.3, height: size.height * 0.14)
                    .offset(x: size.width * 0.54, y: size.height * 0.48)
            }
        }
        .accessibilityHidden(true)
    }
}
#endif
