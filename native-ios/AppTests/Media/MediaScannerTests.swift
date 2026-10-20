import InventoryAppModels
import InventoryCore
import InventoryStrings
import Testing
@testable import Inventory

@MainActor
private final class MediaScanRecorder {
    var scans: [String] = []
}

@MainActor
private func mediaScanner(
    authorization: CameraAuthorization = .authorized,
    active: Bool = true
) -> (QrScannerModel, StandInQrScannerFeed, QrScannerBridge, MediaScanRecorder) {
    let model = QrScannerModel(
        title: L10n.Scan.title,
        permission: CameraPermissionModel(purpose: .scan, readAuthorization: { authorization }, requestAccess: { true }),
        active: active
    )
    model.reduceMotion = true
    let recorder = MediaScanRecorder()
    model.onScan = { raw in recorder.scans.append(raw) }
    let feed = StandInQrScannerFeed()
    let bridge = QrScannerBridge(model: model, feed: feed)
    return (model, feed, bridge, recorder)
}

@Suite("QR scanner bridge (06 §8.4)")
@MainActor
struct MediaScannerTests {
    static let payload = formatQrPayload("0123456789abcdef0123456789abcdef")

    @Test("frames go to QrScannerModel.codeDetected: one label held in view opens once")
    func forwardsOnce() async {
        let (model, feed, bridge, recorder) = mediaScanner()
        model.focusGained()
        bridge.update(isShown: true, sceneIsBackground: false)
        #expect(feed.isRunning)

        feed.deliver([Self.payload])
        feed.deliver([Self.payload, Self.payload])
        #expect(await mediaWait { !recorder.scans.isEmpty && !model.isLocked })
        // Later frames of the same label are not handed over again in this arming.
        feed.deliver([Self.payload])
        for _ in 0..<5 { await Task.yield() }
        #expect(recorder.scans == [Self.payload])
    }

    @Test("the camera runs only while focused, active, permitted, on screen and not backgrounded")
    func runsOnlyWhenWanted() {
        let (model, feed, bridge, _) = mediaScanner()
        bridge.update(isShown: true, sceneIsBackground: false)
        #expect(!feed.isRunning, "not focused yet")

        model.focusGained()
        bridge.update(isShown: true, sceneIsBackground: false)
        #expect(feed.isRunning)

        bridge.update(isShown: true, sceneIsBackground: true)
        #expect(!feed.isRunning, "background")

        bridge.update(isShown: false, sceneIsBackground: false)
        #expect(!feed.isRunning, "off screen")

        model.setActive(false)
        bridge.update(isShown: true, sceneIsBackground: false)
        #expect(!feed.isRunning, "a notice waits for an answer")

        model.setActive(true)
        bridge.update(isShown: true, sceneIsBackground: false)
        #expect(feed.isRunning)

        model.focusLost()
        bridge.update(isShown: true, sceneIsBackground: false)
        #expect(!feed.isRunning, "another tab")
    }

    @Test("without the permission the camera never runs")
    func needsPermission() {
        let (model, feed, bridge, _) = mediaScanner(authorization: .denied)
        model.focusGained()
        bridge.update(isShown: true, sceneIsBackground: false)
        #expect(!feed.isRunning)
    }

    @Test("codes that arrive while the camera should be off are ignored")
    func ignoresWhenStopped() async {
        let (model, feed, _, recorder) = mediaScanner()
        model.focusGained()
        model.focusLost()
        feed.deliver([Self.payload])
        for _ in 0..<10 { await Task.yield() }
        #expect(recorder.scans.isEmpty)
    }

    @Test("a camera that does not start hides the torch and the footer")
    func mountFailure() {
        let (model, feed, bridge, _) = mediaScanner()
        feed.failsToStart = true
        model.focusGained()
        bridge.update(isShown: true, sceneIsBackground: false)
        #expect(model.mountFailed)
        #expect(!model.showsTorch)
        #expect(!model.showsFooter)
    }

    @Test("the torch follows the model, and leaving turns it off")
    func torch() {
        let (model, feed, bridge, _) = mediaScanner()
        model.focusGained()
        model.toggleTorch()
        bridge.syncTorch()
        #expect(feed.torchRequests == [true])
        #expect(model.torchLabel == L10n.Camera.torchState(on: true))
        model.focusLost()
        bridge.syncTorch()
        #expect(feed.torchRequests == [true, false])
    }

    @Test("the camera feed reports a missing camera to the scanner model")
    func realCameraWithoutDevice() async {
        let model = QrScannerModel(
            title: L10n.Scan.title,
            permission: CameraPermissionModel(purpose: .scan, readAuthorization: { .authorized }, requestAccess: { true })
        )
        let camera = CameraController(use: .qrCodes, discover: { nil })
        let bridge = QrScannerBridge(model: model, feed: camera)
        model.focusGained()
        bridge.update(isShown: true, sceneIsBackground: false)
        #expect(await mediaWait { model.mountFailed })
        bridge.update(isShown: false, sceneIsBackground: false)
    }
}

@Suite("Camera panel (06 §8.2)")
@MainActor
struct MediaCameraPanelTests {
    @Test("the Scan tab's panel keeps RN's buttons, glyphs and identifiers")
    func scanPanelMapping() {
        var performed: [ScanPanelAction] = []
        let panel = CameraPanel(
            ScanPanel(tone: .error, title: L10n.Scan.invalidTitle, message: L10n.Scan.invalidBody, actions: [.scanAgain, .tryAgain, .typeCode])
        ) { performed.append($0) }
        #expect(panel.tone == .error)
        #expect(panel.actions.map(\.id) == ["scan-again", "scan-try-again", "scan-type-code"])
        #expect(panel.actions.map(\.systemImage) == [nil, "arrow.clockwise", "keyboard"])
        #expect(panel.actions.map(\.label) == [L10n.Scan.scanAgain, L10n.Common.tryAgain, L10n.Scan.typeCode])
        for action in panel.actions { action.perform() }
        #expect(performed == [.scanAgain, .tryAgain, .typeCode])
    }

    @Test("errors and busy notices are announced as \"title. message\"; the hint is not")
    func announcements() {
        #expect(CameraPanel(tone: .error, title: "T", message: "M").announcement == "T. M")
        #expect(CameraPanel(tone: .busy, message: "M").announcement == "M")
        #expect(CameraPanel(tone: .hint, message: "M").announcement == nil)
    }
}
