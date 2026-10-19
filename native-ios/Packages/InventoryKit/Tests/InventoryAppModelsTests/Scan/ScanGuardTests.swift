import InventoryCore
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

@Suite("ScanGuard (06 §8.4, §21)")
@MainActor
struct ScanGuardTests {
    @Test("one scan per arming: the 2nd and 3rd frames of the same label are ignored")
    func oneScanPerArming() {
        let scanGuard = ScanGuard(clock: ManualClock())
        scanGuard.focused()
        #expect(scanGuard.isArmed)
        #expect(scanGuard.accept("inventory://c/\(ScanTestData.token)"))
        #expect(!scanGuard.isArmed)
        #expect(!scanGuard.accept("inventory://c/\(ScanTestData.token)"))
        #expect(!scanGuard.accept("another code"))
        #expect(scanGuard.handed == "inventory://c/\(ScanTestData.token)")
    }

    @Test("re-activation (Scan again) arms again and accepts the same label")
    func reactivationAcceptsSameCode() {
        let scanGuard = ScanGuard(clock: ManualClock())
        scanGuard.focused()
        #expect(scanGuard.accept("code"))
        scanGuard.reactivated()
        #expect(scanGuard.ignoredCode == nil)
        #expect(scanGuard.accept("code"))
    }

    @Test("after refocusing, the label handed over last is ignored while it stays in view")
    func sameCodeIgnoredAfterRefocus() async {
        let clock = ManualClock()
        let scanGuard = ScanGuard(clock: clock)
        scanGuard.focused()
        #expect(scanGuard.accept("code"))

        // Back from the container it opened: the label is still under the camera.
        scanGuard.focused()
        #expect(scanGuard.ignoredCode == "code")
        await clock.advance(by: .milliseconds(1000))
        #expect(!scanGuard.accept("code"))
        // Each sighting refreshes the time, so it is ignored for as long as it is seen.
        await clock.advance(by: .milliseconds(1400))
        #expect(!scanGuard.accept("code"))
        await clock.advance(by: .milliseconds(1499))
        #expect(!scanGuard.accept("code"))

        // Out of view for 1500 ms: the same label opens again.
        await clock.advance(by: .milliseconds(1500))
        #expect(scanGuard.accept("code"))
        #expect(scanGuard.ignoredCode == nil)
    }

    @Test("a different label ends the ignore at once")
    func differentCodeEndsIgnore() {
        let scanGuard = ScanGuard(clock: ManualClock())
        scanGuard.focused()
        #expect(scanGuard.accept("first"))
        scanGuard.focused()
        #expect(scanGuard.accept("second"))
        #expect(scanGuard.ignoredCode == nil)
        #expect(scanGuard.handed == "second")
    }

    @Test("the first focus ignores nothing")
    func firstFocus() {
        let scanGuard = ScanGuard(clock: ManualClock())
        scanGuard.focused()
        #expect(scanGuard.ignoredCode == nil)
        #expect(ScanGuard.sameCodeGap == .milliseconds(1500))
    }

    @Test("a disarmed scanner takes no codes, not even a different one")
    func disarmed() async {
        let clock = ManualClock()
        let scanGuard = ScanGuard(clock: clock)
        scanGuard.focused()
        #expect(scanGuard.accept("code"))
        #expect(!scanGuard.accept("other"))
        #expect(scanGuard.handed == "code")
    }

    @Test("reset starts over like a newly mounted scanner: armed, nothing handed over or ignored")
    func reset() {
        let scanGuard = ScanGuard(clock: ManualClock())
        scanGuard.focused()
        #expect(scanGuard.accept("code"))
        scanGuard.focused()
        #expect(scanGuard.ignoredCode == "code")

        scanGuard.reset()
        #expect(scanGuard.isArmed)
        #expect(scanGuard.handed == nil)
        #expect(scanGuard.ignoredCode == nil)
        // A later focus has nothing to ignore, so the same label is taken at once.
        scanGuard.focused()
        #expect(scanGuard.accept("code"))
    }
}

@Suite("QrScannerModel (QrScanner.tsx)", .timeLimit(.minutes(1)))
@MainActor
struct QrScannerModelTests {
    @Test("runs the camera only while in front, active and granted")
    func cameraRuns() {
        let scanner = QrScannerModel(title: "Scan a label", permission: ScanTestData.permission(), clock: ManualClock())
        #expect(!scanner.cameraRuns)
        scanner.focusGained()
        #expect(scanner.cameraRuns)
        scanner.setActive(false)
        #expect(!scanner.cameraRuns)
        scanner.setActive(true)
        #expect(scanner.cameraRuns)
        scanner.focusLost()
        #expect(!scanner.cameraRuns)

        let denied = QrScannerModel(title: "Scan a label", permission: ScanTestData.permission(.denied), clock: ManualClock())
        denied.focusGained()
        #expect(!denied.cameraRuns)
    }

    @Test("locks the reticle for 250 ms, then hands the code over once; the lock clears when it is done")
    func lockThenHandOver() async throws {
        let clock = ManualClock()
        let scanner = QrScannerModel(title: "Scan a label", permission: ScanTestData.permission(), clock: clock)
        var handed: [String] = []
        scanner.onScan = { handed.append($0) }
        scanner.focusGained()

        let read = Task { await scanner.codeDetected("code") }
        try await clock.waitForSleepers()
        #expect(scanner.isLocked)
        #expect(handed.isEmpty)
        await scanner.codeDetected("code")
        await clock.advance(by: .milliseconds(250))
        await read.value
        #expect(handed == ["code"])
        #expect(!scanner.isLocked)
    }

    @Test("a code that arrives while the camera should be off is ignored and does not use up the arming")
    func ignoredWhileOff() async {
        let scanner = QrScannerModel(title: "Scan a label", permission: ScanTestData.permission(), clock: ManualClock())
        scanner.reduceMotion = true
        var handed: [String] = []
        scanner.onScan = { handed.append($0) }

        // Not focused yet, then focused but inactive, then out of focus again.
        await scanner.codeDetected("early")
        scanner.focusGained()
        scanner.setActive(false)
        await scanner.codeDetected("inactive")
        scanner.setActive(true)
        scanner.focusLost()
        await scanner.codeDetected("late")
        #expect(handed.isEmpty)
        #expect(scanner.scanGuard.isArmed)
        #expect(scanner.scanGuard.handed == nil)

        scanner.focusGained()
        await scanner.codeDetected("late")
        #expect(handed == ["late"])

        let denied = QrScannerModel(title: "Scan a label", permission: ScanTestData.permission(.denied), clock: ManualClock())
        denied.reduceMotion = true
        var deniedHanded: [String] = []
        denied.onScan = { deniedHanded.append($0) }
        denied.focusGained()
        await denied.codeDetected("code")
        #expect(deniedHanded.isEmpty)
    }

    @Test("reset is a freshly mounted scanner: torch off, the camera tried again, a new arming")
    func scannerReset() async {
        let scanner = QrScannerModel(title: "Scan a label", permission: ScanTestData.permission(), clock: ManualClock())
        scanner.reduceMotion = true
        var handed: [String] = []
        scanner.onScan = { handed.append($0) }
        scanner.focusGained()
        await scanner.codeDetected("code")
        scanner.toggleTorch()
        scanner.cameraFailedToStart()

        scanner.reset()
        #expect(!scanner.torchOn)
        #expect(!scanner.mountFailed)
        #expect(!scanner.isLocked)
        #expect(scanner.scanGuard.isArmed)
        await scanner.codeDetected("code")
        #expect(handed == ["code", "code"])
    }

    @Test("under Reduce Motion the code goes over without the wait")
    func reduceMotion() async {
        let scanner = QrScannerModel(title: "Scan a label", permission: ScanTestData.permission(), clock: ManualClock())
        scanner.reduceMotion = true
        var handed: [String] = []
        scanner.onScan = { handed.append($0) }
        scanner.focusGained()
        await scanner.codeDetected("code")
        #expect(handed == ["code"])
    }

    @Test("the torch goes off when the screen leaves; a camera that failed hides the torch and the footer")
    func torchAndFailure() {
        let scanner = QrScannerModel(title: "Scan a label", permission: ScanTestData.permission(), clock: ManualClock())
        scanner.focusGained()
        #expect(scanner.torchLabel == "Torch, off")
        scanner.toggleTorch()
        #expect(scanner.torchOn)
        #expect(scanner.torchLabel == "Torch, on")
        scanner.focusLost()
        #expect(!scanner.torchOn)
        #expect(scanner.showsTorch && scanner.showsFooter)
        scanner.cameraFailedToStart()
        #expect(!scanner.showsTorch && !scanner.showsFooter)
    }

    @Test("a host can name the torch states")
    func torchLabels() {
        let scanner = QrScannerModel(
            title: "Scan the sticker for Tool chest",
            permission: ScanTestData.permission(),
            torchLabelOn: "Light on",
            torchLabelOff: "Light off",
            clock: ManualClock()
        )
        #expect(scanner.torchLabel == "Light off")
        scanner.toggleTorch()
        #expect(scanner.torchLabel == "Light on")
    }
}
