import CoreGraphics
import InventoryCore
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

@Suite("TapToFocus (TapToFocusLayer.test.tsx)")
struct TapToFocusTests {
    @Test("centres the square on the tap rather than hanging it from the corner")
    func centres() {
        #expect(TapToFocus.focusSpotOffset(x: 100, y: 40) == CGPoint(x: 100 - TapToFocus.spotSize / 2, y: 40 - TapToFocus.spotSize / 2))
        #expect(TapToFocus.focusSpotOffset(x: 100, y: 40) == CGPoint(x: 64, y: 4))
        #expect(TapToFocus.spotSize == 72)
        #expect(TapToFocus.spotDuration == .milliseconds(700))
    }

    @Test("shows the square for 700 ms, and a new tap replaces it and restarts the wait")
    @MainActor
    func spotLife() async throws {
        let clock = ManualClock()
        let model = TapToFocusModel(clock: clock)
        #expect(model.spot == nil && model.spotOrigin == nil)

        model.tap(at: CGPoint(x: 100, y: 40))
        #expect(model.spot == CGPoint(x: 100, y: 40))
        #expect(model.spotOrigin == CGPoint(x: 64, y: 4))
        try await clock.waitForSleepers()
        await clock.advance(by: .milliseconds(500))
        #expect(model.spot != nil)

        model.tap(at: CGPoint(x: 10, y: 10))
        try await clock.waitForSleepers()
        await clock.advance(by: .milliseconds(500))
        #expect(model.spot == CGPoint(x: 10, y: 10))
        await clock.advance(by: .milliseconds(200))
        #expect(model.spot == nil)
    }

    @Test("reset takes the square away at once")
    @MainActor
    func reset() {
        let model = TapToFocusModel(clock: ManualClock())
        model.tap(at: .zero)
        model.reset()
        #expect(model.spot == nil)
    }
}

@Suite("CameraFocusSettings (AVCam-style focus, DECISIONS U7)")
struct CameraFocusSettingsTests {
    @Test("a tap focuses and meters once at the point, and watches for the scene to change")
    func tap() {
        let point = CGPoint(x: 0.3, y: 0.7)
        let settings = CameraFocusSettings.tap(at: point, .all)
        #expect(settings == CameraFocusSettings(
            focusPointOfInterest: point,
            focusMode: .autoFocus,
            exposurePointOfInterest: point,
            exposureMode: .autoExpose,
            subjectAreaChangeMonitoring: true
        ))
        #expect(settings.smoothAutoFocus == false)
    }

    @Test("a subject-area change goes back to continuous focus and exposure at the centre, monitoring off")
    func subjectAreaChanged() {
        #expect(CameraFocusSettings.subjectAreaChanged(.all) == CameraFocusSettings(
            focusPointOfInterest: CGPoint(x: 0.5, y: 0.5),
            focusMode: .continuousAutoFocus,
            exposurePointOfInterest: CGPoint(x: 0.5, y: 0.5),
            exposureMode: .continuousAutoExposure,
            subjectAreaChangeMonitoring: false
        ))
        #expect(CameraFocusSettings.continuous(.all) == CameraFocusSettings.subjectAreaChanged(.all))
    }

    @Test("sets a point only where the device supports both the point and the mode")
    func unsupported() {
        let noFocusPoint = CameraFocusCapabilities(
            focusPointOfInterest: false,
            autoFocus: true,
            continuousAutoFocus: true,
            exposurePointOfInterest: true,
            autoExpose: false,
            continuousAutoExposure: true
        )
        let settings = CameraFocusSettings.tap(at: CGPoint(x: 0.1, y: 0.2), noFocusPoint)
        #expect(settings.focusPointOfInterest == nil && settings.focusMode == nil)
        #expect(settings.exposurePointOfInterest == nil && settings.exposureMode == nil)
        #expect(settings.subjectAreaChangeMonitoring)

        let reset = CameraFocusSettings.subjectAreaChanged(noFocusPoint)
        #expect(reset.focusMode == nil)
        #expect(reset.exposureMode == .continuousAutoExposure)
    }
}

@Suite("Camera permission (CameraPermission.tsx, 05 §16.1, 06 §8.5)")
struct CameraPermissionTests {
    @Test(
        "maps AVFoundation's status as expo-camera did: denied and restricted cannot ask again",
        arguments: [
            (CameraAuthorization.notDetermined, CameraPermissionScreen.rationale),
            (.denied, .blocked),
            (.restricted, .blocked),
            (.authorized, .granted),
        ]
    )
    func mapping(status: CameraAuthorization, screen: CameraPermissionScreen) {
        #expect(CameraPermissionScreen(status) == screen)
    }

    @Test("capture: the rationale says where photos go, and offers a library photo and typing")
    func captureRationale() {
        let local = CameraPermissionCopy.make(purpose: .capture, blocked: false, isPaired: false, offersLibrary: true, offersManual: true)
        #expect(local.title == "Use the camera")
        #expect(local.body == "Photos of items stay in this app, not in your photo library.")
        #expect(local.primaryAction == .allow)
        #expect(local.primaryLabel == "Allow camera")
        #expect(local.alternatives == [.choosePhoto, .typeItem])
        #expect(local.alternatives.map(\.label) == ["Choose a photo instead", "Type it instead"])

        let paired = CameraPermissionCopy.make(purpose: .capture, blocked: false, isPaired: true, offersLibrary: true, offersManual: false)
        #expect(paired.body == "Photos of items are shared with your household, not saved to your photo library.")
        // Request mode never offers typing.
        #expect(paired.alternatives == [.choosePhoto])
    }

    @Test("capture: blocked points to Settings")
    func captureBlocked() {
        let copy = CameraPermissionCopy.make(purpose: .capture, blocked: true, isPaired: true, offersLibrary: true, offersManual: true)
        #expect(copy.title == "Camera access is off")
        #expect(copy.body == "Turn it on in Settings, or type it instead.")
        #expect(copy.primaryAction == .openSettings)
        #expect(copy.primaryLabel == "Open Settings")
    }

    @Test("scan: the rationale and the blocked screen offer typing a code")
    func scan() {
        let rationale = CameraPermissionCopy.make(purpose: .scan, blocked: false, isPaired: true, offersLibrary: true, offersManual: true)
        #expect(rationale.body == "Point it at the label on a box and the box opens straight away.")
        #expect(rationale.alternatives == [.typeCode])
        #expect(rationale.alternatives.map(\.label) == ["Type a code instead"])
        let blocked = CameraPermissionCopy.make(purpose: .scan, blocked: true, isPaired: false, offersLibrary: false, offersManual: true)
        #expect(blocked.body == "Turn it on in Settings, or type the code instead.")
        #expect(blocked.primaryAction == .openSettings)
        let noManual = CameraPermissionCopy.make(purpose: .scan, blocked: true, isPaired: false, offersLibrary: false, offersManual: false)
        #expect(noManual.alternatives.isEmpty)
    }

    @Test("Allow asks once, logs permission_result and swaps to the camera on a grant")
    @MainActor
    func allowGranted() async {
        let authorization = CaptureTestAuthorization(.notDetermined, answer: true)
        let telemetry = RecordingTelemetry()
        let model = authorization.model(.capture, telemetry: telemetry)
        #expect(model.screen == .rationale)
        #expect(!model.isGranted)

        await model.allow()

        #expect(authorization.requests == 1)
        #expect(model.isGranted)
        #expect(model.screen == .granted)
        #expect(telemetry.entries == [RecordingTelemetry.Entry(level: "event", name: "permission_result", payload: [
            "permission": .string("camera"), "outcome": .string("granted"),
        ])])
    }

    @Test("a refusal logs denied and shows the blocked screen")
    @MainActor
    func allowDenied() async {
        let authorization = CaptureTestAuthorization(.notDetermined, answer: false)
        let telemetry = RecordingTelemetry()
        let model = authorization.model(.scan, telemetry: telemetry)
        await model.allow()
        #expect(model.screen == .blocked)
        #expect(telemetry.events.map(\.payload) == [["permission": .string("camera"), "outcome": .string("denied")]])
        #expect(model.copy(isPaired: false, offersLibrary: false, offersManual: true).primaryAction == .openSettings)
    }

    @Test("refresh reads a change made in Settings")
    @MainActor
    func refresh() {
        let authorization = CaptureTestAuthorization(.denied)
        let model = authorization.model(.capture)
        authorization.status = .authorized
        #expect(model.screen == .blocked)
        model.refresh()
        #expect(model.screen == .granted)
    }
}
