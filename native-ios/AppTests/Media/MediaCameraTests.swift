import AVFoundation
import CoreGraphics
import InventoryAppModels
import Testing
@testable import Inventory

@Suite("Camera controller (05 §8)")
@MainActor
struct MediaCameraControllerTests {
    @Test("no camera: starting reports failedToStart, never a crash", arguments: [CameraUse.photo, .qrCodes])
    func noCamera(use: CameraUse) async {
        let camera = CameraController(use: use, discover: { nil })
        var events: [CameraFeedEvent] = []
        camera.onEvent = { events.append($0) }

        camera.setRunning(true)
        #expect(await mediaWait { events.contains(.failedToStart) })
        #expect(!camera.isRunning)

        // Everything else stays harmless without a camera.
        camera.focus(atLayerPoint: CGPoint(x: 10, y: 10))
        camera.setTorch(true)
        camera.setRunning(false)
        camera.attach(CameraPreviewUIView(frame: CGRect(x: 0, y: 0, width: 393, height: 852)))
    }

    @Test("a host wired after the session reported still hears its state")
    func lateWiringReplaysLastEvent() async {
        let camera = CameraController(use: .photo, discover: { nil })
        camera.setRunning(true)
        #expect(await mediaWait { camera.lastEvent == .failedToStart })

        var heard: [CameraFeedEvent] = []
        camera.deliverEvents { heard.append($0) }
        #expect(heard == [.failedToStart])

        var fresh: [CameraFeedEvent] = []
        CameraController(use: .photo, discover: { nil }).deliverEvents { fresh.append($0) }
        #expect(fresh.isEmpty, "nothing to replay before the session reported anything")
    }

    @Test("a rebuilt preview takes the session over; a dismantled one lets it go")
    func previewHandOver() {
        let camera = CameraController(use: .photo, discover: { nil })
        let first = CameraPreviewUIView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let second = CameraPreviewUIView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))

        camera.attach(first)
        let session = first.previewLayer?.session
        #expect(session != nil)
        #expect(first.previewLayer?.videoGravity == .resizeAspectFill)

        camera.attach(second)
        #expect(second.previewLayer?.session === session)

        // The old view goes after the new one arrived (a SwiftUI rebuild): the new one keeps it.
        // (AVFoundation already moved the session off the old layer when the new one took it.)
        camera.detach(first)
        #expect(first.previewLayer?.session == nil)
        #expect(second.previewLayer?.session === session)

        camera.detach(second)
        #expect(second.previewLayer?.session == nil)

        // And a view that comes back gets the same session again.
        camera.attach(first)
        #expect(first.previewLayer?.session === session)
    }

    @Test("no camera: the shutter throws notRunning, which CaptureModel shows as noPhoto")
    func captureWithoutCamera() async throws {
        let camera = CameraController(use: .photo, discover: { nil })
        camera.setRunning(true)
        await #expect(throws: CameraCaptureError.notRunning) {
            _ = try await camera.capturePhoto(flashOn: false)
        }
    }

    @Test("a QR feed has no stills to take")
    func qrHasNoStills() async {
        let camera = CameraController(use: .qrCodes, discover: { nil })
        await #expect(throws: CameraCaptureError.notRunning) {
            _ = try await camera.capturePhoto(flashOn: true)
        }
    }

    @Test(
        "the still keeps what the preview showed: swapped when the photo turns a quarter from the preview",
        arguments: [
            (90.0, 90.0, CGSize(width: 393, height: 852)),
            (90.0, 0.0, CGSize(width: 852, height: 393)),
            (90.0, 180.0, CGSize(width: 852, height: 393)),
            (0.0, 0.0, CGSize(width: 393, height: 852)),
            (90.0, 270.0, CGSize(width: 393, height: 852)),
        ]
    )
    func cropAspect(previewAngle: Double, captureAngle: Double, expected: CGSize) {
        let aspect = CameraController.cropAspect(
            previewSize: CGSize(width: 393, height: 852),
            previewAngle: previewAngle,
            captureAngle: captureAngle
        )
        #expect(aspect == expected)
    }

    @Test("no crop without a measured preview or a rotation")
    func noCrop() {
        #expect(CameraController.cropAspect(previewSize: .zero, previewAngle: 90, captureAngle: 90) == nil)
        #expect(CameraController.cropAspect(previewSize: CGSize(width: 393, height: 852), previewAngle: nil, captureAngle: 90) == nil)
        #expect(CameraController.cropAspect(previewSize: CGSize(width: 393, height: 852), previewAngle: 90, captureAngle: nil) == nil)
    }

    @Test("the per-shot quality never exceeds the output's ceiling (05 C5)")
    func prioritizationCap() {
        #expect(CameraSession.prioritization(requested: .quality, ceiling: .quality) == .quality)
        #expect(CameraSession.prioritization(requested: .quality, ceiling: .balanced) == .balanced)
        #expect(CameraSession.prioritization(requested: .quality, ceiling: .speed) == .speed)
        #expect(CameraSession.prioritization(requested: .balanced, ceiling: .quality) == .balanced)
    }

    @Test("the device preference is RN's: virtual multi-cameras first, then the wide-angle camera")
    func devicePreference() {
        #expect(CameraDiscovery.preference == [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera])
    }
}

@Suite("Camera permission wiring (05 §16.1, 06 §8.5)")
@MainActor
struct MediaCameraPermissionTests {
    @Test(
        "AVAuthorizationStatus maps as expo-camera did",
        arguments: [
            (AVAuthorizationStatus.notDetermined, CameraAuthorization.notDetermined, CameraPermissionScreen.rationale),
            (.restricted, .restricted, .blocked),
            (.denied, .denied, .blocked),
            (.authorized, .authorized, .granted),
        ]
    )
    func mapping(status: AVAuthorizationStatus, authorization: CameraAuthorization, screen: CameraPermissionScreen) {
        #expect(CameraAuthorizationAccess.authorization(status) == authorization)
        #expect(CameraPermissionScreen(CameraAuthorizationAccess.authorization(status)) == screen)
    }

    @Test("the device model reads AVFoundation's status")
    func deviceModel() {
        let model = CameraPermissionModel.device(purpose: .scan)
        #expect(model.purpose == .scan)
        #expect(model.authorization == CameraAuthorizationAccess.authorization(AVCaptureDevice.authorizationStatus(for: .video)))
    }

    @Test("capture, can ask: Allow camera, Choose a photo instead, then the quiet Type it instead")
    func captureRationale() {
        let copy = CameraPermissionCopy.make(purpose: .capture, blocked: false, isPaired: false, offersLibrary: true, offersManual: true)
        let layout = CameraPermissionLayout(copy: copy, purpose: .capture)
        #expect(layout.buttons.map(\.id) == ["camera-allow", "camera-library", "camera-manual"])
        #expect(layout.buttons.map(\.style) == [.primary, .secondary, .quiet])
        #expect(layout.buttons.map(\.action) == [.allow, .choosePhoto, .manual])
        #expect(layout.title == copy.title && layout.body == copy.body)
    }

    @Test("capture, blocked, request mode: Open Settings and the library only")
    func captureBlocked() {
        let copy = CameraPermissionCopy.make(purpose: .capture, blocked: true, isPaired: true, offersLibrary: true, offersManual: false)
        let layout = CameraPermissionLayout(copy: copy, purpose: .capture)
        #expect(layout.buttons.map(\.id) == ["camera-open-settings", "camera-library"])
        #expect(layout.buttons.first?.action == .openSettings)
    }

    @Test("scan: Allow camera and the secondary Type a code instead; nothing else without a callback")
    func scan() {
        let offered = CameraPermissionLayout(
            copy: CameraPermissionCopy.make(purpose: .scan, blocked: false, isPaired: false, offersLibrary: false, offersManual: true),
            purpose: .scan
        )
        #expect(offered.buttons.map(\.id) == ["camera-allow", "camera-manual"])
        #expect(offered.buttons.map(\.style) == [.primary, .secondary])
        #expect(offered.buttons.last?.systemImage == "keyboard")

        let bare = CameraPermissionLayout(
            copy: CameraPermissionCopy.make(purpose: .scan, blocked: true, isPaired: false, offersLibrary: false, offersManual: false),
            purpose: .scan
        )
        #expect(bare.buttons.map(\.id) == ["camera-open-settings"])
    }
}

@Suite("Photo library import (05 §4.8)")
struct MediaLibraryPickTests {
    @Test("every presentation is answered once")
    func gate() {
        var gate = CaptureLibraryPickGate()
        let early = gate.close()
        #expect(!early, "nothing to answer before the picker opened")
        gate.opened()
        #expect(gate.isOpen)
        let first = gate.close()
        let second = gate.close()
        #expect(first)
        #expect(!second, "a second close (dismissal after the answer) answers nothing")
        gate.opened()
        let reopened = gate.close()
        #expect(reopened)
    }

    @Test("the picked file is copied to a private temporary file, keeping its extension")
    func copies() throws {
        let directory = try mediaTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "IMG_0001.HEIC")
        try Data([1, 2, 3]).write(to: source)

        let copy = try CaptureLibraryFile.copyToTemporary(source, in: directory)
        #expect(copy != source)
        #expect(copy.pathExtension == "HEIC")
        #expect(copy.lastPathComponent.hasPrefix("library-pick-"))
        #expect(try Data(contentsOf: copy) == Data([1, 2, 3]))

        let bare = directory.appending(path: "photo")
        try Data([4]).write(to: bare)
        #expect(try CaptureLibraryFile.copyToTemporary(bare, in: directory).pathExtension == "image")
    }
}
