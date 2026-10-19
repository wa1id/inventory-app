import InventoryCore
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// Everything a Scan tab model under test talks to.
@MainActor
final class ScanModelHarness {
    let qr: ScanTestQr
    let haptics = SharedSeamsHapticRecorder()
    let telemetry = RecordingTelemetry()
    let navigation = ScanTestNavigation<ScanNavigation>()
    let clock = ManualClock()

    init(holdResolves: Bool = false) {
        qr = ScanTestQr(holdResolves: holdResolves)
    }

    func model() -> ScanModel {
        let qr = qr
        let model = ScanModel(
            permission: ScanTestData.permission(),
            qr: { qr },
            haptics: haptics.player,
            telemetry: TelemetryReporter(sink: telemetry),
            clock: clock,
            navigate: navigation.navigate
        )
        model.scanner.reduceMotion = true
        model.focusGained()
        return model
    }
}

private extension ScanResult {
    var name: String {
        switch self {
        case .idle: "idle"
        case .opening: "opening"
        case .notOurs: "notOurs"
        case .failed: "failed"
        }
    }
}

@Suite("ScanModel (app/(tabs)/scan.tsx, 06 §8)")
@MainActor
struct ScanModelTests {
    @Test("a linked label opens its container, with the success haptic and qr_scan bound")
    func bound() async {
        let harness = ScanModelHarness()
        let raw = "inventory://c/\(ScanTestData.token)"
        harness.qr.answer(raw, with: .success(.bound(container: ScanTestData.container("c9"), token: ScanTestData.token)))
        let model = harness.model()

        await model.scanner.codeDetected(raw)

        #expect(harness.qr.resolved == [raw])
        #expect(harness.navigation.destinations == [.openContainer(id: "c9")])
        #expect(harness.haptics.played == [.success])
        #expect(harness.telemetry.entries == [RecordingTelemetry.Entry(level: "event", name: "qr_scan", payload: ["outcome": .string("bound")])])
        #expect(model.result.name == "idle")
    }

    @Test("an unlinked label of ours goes to the label screen, without a haptic")
    func unknown() async {
        let harness = ScanModelHarness()
        let model = harness.model()
        await model.open(ScanTestData.token.uppercased())
        #expect(harness.navigation.destinations == [.openLabel(token: ScanTestData.token)])
        #expect(harness.haptics.played.isEmpty)
        #expect(harness.telemetry.events.map(\.payload) == [["outcome": .string("unknown")]])
    }

    @Test("someone else's code says plainly it is not ours, and stops the scanner until Scan again")
    func notOurs() async {
        let harness = ScanModelHarness()
        let model = harness.model()
        await model.open("https://example.com")
        #expect(model.result.name == "notOurs")
        #expect(harness.haptics.played == [.error])
        #expect(harness.telemetry.events.map(\.payload) == [["outcome": .string("invalid")]])
        #expect(!model.scannerActive)
        #expect(!model.scanner.isActive)
        #expect(model.panel == ScanPanel(tone: .error, title: "Not one of our labels", message: "That code was not made by this app.", actions: [.scanAgain, .typeCode]))
        #expect(model.panel.announcement == "Not one of our labels. That code was not made by this app.")
        #expect(model.panel.actions.map(\.label) == ["Scan again", "Type a code instead"])
        #expect(harness.navigation.destinations.isEmpty)

        let armingBefore = model.scanner.scanGuard.arming
        model.scanAgain()
        #expect(model.result.name == "idle")
        #expect(model.scanner.isActive)
        // Re-armed: the same label is taken again.
        #expect(model.scanner.scanGuard.arming == armingBefore + 1)
        #expect(model.scanner.scanGuard.isArmed)
    }

    @Test("a failed lookup says what went wrong, logs qr_scan_failed with the kind, and offers Try again")
    func failed() async {
        let harness = ScanModelHarness()
        harness.qr.answer("x", with: .failure(HouseholdHttpError(status: 0, code: "offline")))
        let model = harness.model()
        await model.open("x")
        #expect(model.result.name == "failed")
        #expect(harness.haptics.played == [.error])
        #expect(harness.telemetry.entries == [RecordingTelemetry.Entry(level: "error", name: "qr_scan_failed", payload: ["errorClass": .string("offline")])])
        let described = describeError(HouseholdHttpError(status: 0, code: "offline"))
        #expect(model.panel == ScanPanel(tone: .error, title: described.title, message: described.body, actions: [.tryAgain, .typeCode]))
        #expect(model.panel.actions.first?.label == "Try again")
        model.scanAgain()
        #expect(model.result.name == "idle")
        // Try again does not run the old lookup again.
        #expect(harness.qr.resolved == ["x"])
    }

    @Test("the hint stands until a lookup has run 180 ms, then says it is opening")
    func openingDelay() async throws {
        let harness = ScanModelHarness(holdResolves: true)
        let model = harness.model()
        #expect(model.panel == ScanPanel(tone: .hint, title: nil, message: "Point the camera at the label on a box.", actions: [.typeCode]))
        #expect(model.panel.announcement == nil)

        let lookup = Task { await model.open(ScanTestData.token) }
        await harness.qr.resolveLatch?.waitForArrivals(1)
        #expect(model.result.name == "opening")
        #expect(model.scannerActive)
        #expect(model.panel.tone == .hint)
        try await harness.clock.waitForSleepers()
        await harness.clock.advance(by: .milliseconds(179))
        #expect(!model.showsOpening)
        await harness.clock.advance(by: .milliseconds(1))
        #expect(model.showsOpening)
        #expect(model.panel == ScanPanel(tone: .busy, title: nil, message: "Opening that label…", actions: []))
        #expect(model.panel.announcement == "Opening that label…")

        await harness.qr.resolveLatch?.release()
        await lookup.value
        #expect(!model.showsOpening)
    }

    @Test("a lookup that finishes after the tab was left changes nothing")
    func staleAfterFocusLost() async {
        let harness = ScanModelHarness(holdResolves: true)
        harness.qr.answer("raw", with: .success(.bound(container: ScanTestData.container(), token: ScanTestData.token)))
        let model = harness.model()
        let lookup = Task { await model.open("raw") }
        await harness.qr.resolveLatch?.waitForArrivals(1)
        model.focusLost()
        await harness.qr.resolveLatch?.release()
        await lookup.value
        #expect(harness.navigation.destinations.isEmpty)
        #expect(harness.telemetry.entries.isEmpty)
        #expect(harness.haptics.played.isEmpty)
    }

    @Test("a lookup still running when the code list opens does not open over it")
    func staleAfterTypeCode() async {
        let harness = ScanModelHarness(holdResolves: true)
        harness.qr.answer("raw", with: .failure(ScanTestError()))
        let model = harness.model()
        let lookup = Task { await model.open("raw") }
        await harness.qr.resolveLatch?.waitForArrivals(1)
        model.typeCode()
        #expect(model.phase == .code)
        #expect(model.result.name == "idle")
        await harness.qr.resolveLatch?.release()
        await lookup.value
        #expect(model.result.name == "idle")
        #expect(harness.telemetry.entries.isEmpty)
    }

    @Test("codes read while the code list is up, or after the tab was left, start no lookup")
    func ignoredCodes() async {
        let harness = ScanModelHarness()
        let model = harness.model()
        model.typeCode()
        await model.open(ScanTestData.token)
        model.backToCamera()
        model.focusLost()
        await model.open(ScanTestData.token)
        #expect(harness.qr.resolved.isEmpty)
    }

    @Test("every visit starts at the camera with nothing in the way")
    func focusResets() async {
        let harness = ScanModelHarness()
        let model = harness.model()
        await model.open("not ours")
        model.typeCode()
        model.focusLost()
        model.focusGained()
        #expect(model.phase == .camera)
        #expect(model.result.name == "idle")
        #expect(model.scanner.isFocused)
    }

    @Test("re-tapping Scan goes back to the camera and past a notice, but lets a lookup finish")
    func tabReselected() async {
        let harness = ScanModelHarness(holdResolves: true)
        let model = harness.model()
        model.typeCode()
        model.tabReselected()
        #expect(model.phase == .camera)

        let lookup = Task { await model.open(ScanTestData.token) }
        await harness.qr.resolveLatch?.waitForArrivals(1)
        model.tabReselected()
        #expect(model.result.name == "opening")
        await harness.qr.resolveLatch?.release()
        await lookup.value
        #expect(harness.navigation.destinations == [.openLabel(token: ScanTestData.token)])

        // Not in front: nothing happens.
        let other = ScanModelHarness()
        let background = other.model()
        await background.open("not ours")
        background.focusLost()
        background.tabReselected()
        #expect(background.result.name == "notOurs")
    }

    @Test("the scanner is off under the removed-phone layer")
    func revoked() {
        let harness = ScanModelHarness()
        let model = harness.model()
        model.setRevoked(true)
        #expect(!model.scannerActive)
        #expect(!model.scanner.cameraRuns)
        model.setRevoked(false)
        #expect(model.scanner.cameraRuns)
    }

    @Test("a container picked from the code list opens once")
    func openTyped() {
        let harness = ScanModelHarness()
        let model = harness.model()
        model.typeCode()
        model.openTyped(containerId: "c1")
        model.openTyped(containerId: "c1")
        #expect(harness.navigation.destinations == [.openContainer(id: "c1")])
        model.focusGained()
        model.openTyped(containerId: DropZone.containerId)
        #expect(harness.navigation.destinations == [.openContainer(id: "c1"), .openContainer(id: DropZone.containerId)])
    }

    @Test("one label held in view opens one container")
    func oneLabelOneContainer() async {
        let harness = ScanModelHarness()
        harness.qr.answer("raw", with: .success(.bound(container: ScanTestData.container(), token: ScanTestData.token)))
        let model = harness.model()
        await model.scanner.codeDetected("raw")
        await model.scanner.codeDetected("raw")
        await model.scanner.codeDetected("raw")
        #expect(harness.qr.resolved == ["raw"])
        #expect(harness.navigation.destinations.count == 1)

        // Back from the container: the same label, still in view, is ignored.
        model.focusLost()
        model.focusGained()
        await model.scanner.codeDetected("raw")
        #expect(harness.qr.resolved == ["raw"])
    }
}
