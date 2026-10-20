import XCTest

/// The labels screens driven like a person (06 §8-§9, 07 §3.9-§3.10): the Scan tab's camera and
/// typed code, a label linked from the bind picker, the QR label's make, replace and remove, and
/// the sticker camera. The app runs in its DEBUG demo mode (sample inventory in memory, nothing on
/// the device touched); `-demoArea labels` states put a stand-in camera behind the scanner that
/// reads a scripted code, since the simulator has no camera.
@MainActor
final class LabelsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
    }

    private func launch(_ arguments: [String]) {
        app.launchArguments = ["-demo", "YES"] + arguments
        app.launch()
    }

    private func screen(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func button(_ identifier: String) -> XCUIElement {
        app.buttons[identifier].firstMatch
    }

    /// The place picker row for the container named `name`.
    private func placeRow(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'move-to-' AND label BEGINSWITH %@", name)).firstMatch
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// Any element whose label holds `words`: a toast in the overlay, a panel, the camera's title.
    private func text(_ words: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }

    /// Scrolls the list up so its last section clears the floating tab bar and the toast.
    private func scrollToProblems() {
        app.swipeUp()
    }

    // MARK: Scan tab

    func testScanTabTypedCodeOpensTheContainerAndComesBackToTheCamera() throws {
        launch(["-demoArea", "labels", "-demoState", "camera"])
        XCTAssertTrue(screen("screen-scan").waitForExistence(timeout: 15))
        XCTAssertTrue(button("scan-torch").waitForExistence(timeout: 5))
        let typeCode = button("scan-type-code")
        XCTAssertTrue(typeCode.waitForExistence(timeout: 5))
        attachScreenshot("scan-camera")

        typeCode.tap()
        let filter = app.searchFields.firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        XCTAssertTrue(button("scan-back-to-camera").exists)
        filter.typeText("CABJ92R")
        let toolChest = placeRow("Tool chest")
        XCTAssertTrue(toolChest.waitForExistence(timeout: 5))
        attachScreenshot("scan-code-list")
        toolChest.tap()
        XCTAssertTrue(screen("screen-container").waitForExistence(timeout: 5))

        // Back on the tab, every visit starts at the camera.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(button("scan-type-code").waitForExistence(timeout: 5))
        XCTAssertFalse(app.searchFields.firstMatch.exists)
    }

    func testBackToTheCameraLeavesTheCodeList() throws {
        launch(["-demoArea", "labels", "-demoState", "codeList"])
        let back = button("scan-back-to-camera")
        XCTAssertTrue(back.waitForExistence(timeout: 15))
        back.tap()
        XCTAssertTrue(button("scan-type-code").waitForExistence(timeout: 5))
    }

    func testBackToTheCameraStaysWhenTheListsFail() throws {
        launch(["-demoArea", "labels", "-demoState", "codeListFailed"])
        XCTAssertTrue(button("error-retry").waitForExistence(timeout: 15))
        let back = button("scan-back-to-camera")
        XCTAssertTrue(back.exists)
        attachScreenshot("scan-code-list-failed")
        back.tap()
        XCTAssertTrue(button("scan-type-code").waitForExistence(timeout: 5))
    }

    func testScanningALinkedLabelOpensItsContainer() throws {
        launch(["-demoArea", "labels", "-demoState", "scanBound"])
        XCTAssertTrue(screen("screen-container").waitForExistence(timeout: 15))
        XCTAssertTrue(app.tabBars.buttons["tab-scan"].isSelected)
    }

    func testScanningAnUnlinkedLabelOpensTheBindPicker() throws {
        launch(["-demoArea", "labels", "-demoState", "scanUnknown"])
        XCTAssertTrue(screen("screen-label").waitForExistence(timeout: 15))
        XCTAssertTrue(placeRow("Red bin").waitForExistence(timeout: 5))
    }

    func testSomeoneElsesCodeSaysSoAndScanAgainRearms() throws {
        launch(["-demoArea", "labels", "-demoState", "scanNotOurs"])
        let scanAgain = button("scan-again")
        XCTAssertTrue(scanAgain.waitForExistence(timeout: 15))
        XCTAssertTrue(text("Not one of our labels").exists)
        attachScreenshot("scan-not-ours")
        scanAgain.tap()
        XCTAssertTrue(waitForAbsence(scanAgain))
        XCTAssertTrue(button("scan-type-code").exists)
    }

    func testThePermissionScreenOffersTypingACode() throws {
        launch(["-demoArea", "labels", "-demoState", "permission"])
        XCTAssertTrue(button("camera-allow").waitForExistence(timeout: 15))
        button("camera-manual").tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        button("scan-back-to-camera").tap()
        // Allow camera grants it in the demo: the camera comes up.
        XCTAssertTrue(button("camera-allow").waitForExistence(timeout: 5))
        button("camera-allow").tap()
        XCTAssertTrue(button("scan-type-code").waitForExistence(timeout: 5))
    }

    // MARK: Label screen

    func testAnUnlinkedLabelIsLinkedToThePickedContainer() throws {
        launch(["-demoRoute", "label"])
        XCTAssertTrue(screen("screen-label").waitForExistence(timeout: 15))
        XCTAssertTrue(text("New label").waitForExistence(timeout: 5))
        let redBin = placeRow("Red bin")
        XCTAssertTrue(redBin.waitForExistence(timeout: 5))
        attachScreenshot("label-bind")
        redBin.tap()
        XCTAssertTrue(screen("screen-container").waitForExistence(timeout: 5))
        XCTAssertTrue(text("Label linked to Red bin.").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForAbsence(screen("screen-label")))
    }

    func testReplacingAContainersLabelAsksFirst() throws {
        launch(["-demoRoute", "label"])
        let toolChest = placeRow("Tool chest")
        XCTAssertTrue(toolChest.waitForExistence(timeout: 15))
        toolChest.tap()
        let alert = app.alerts["Replace the label on Tool chest?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(screen("screen-label").exists)
        XCTAssertTrue(toolChest.waitForExistence(timeout: 5))
        toolChest.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Replace"].tap()
        XCTAssertTrue(screen("screen-container").waitForExistence(timeout: 5))
    }

    func testSomethingNotOursGoesHome() throws {
        launch(["-demoTab", "spaces", "-demoRoute", "label:hello"])
        XCTAssertTrue(screen("screen-label").waitForExistence(timeout: 15))
        XCTAssertTrue(text("Not one of our labels").waitForExistence(timeout: 5))
        app.buttons["Go to Home"].tap()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 5))
        // The label screen went with it: Spaces is back at its root.
        app.tabBars.buttons["tab-spaces"].tap()
        XCTAssertTrue(screen("screen-spaces").waitForExistence(timeout: 5))
        XCTAssertFalse(screen("screen-label").exists)
    }

    // MARK: QR label and the sticker camera

    func testQrLabelRemoveMakeAndReplace() throws {
        launch(["-demoRoute", "qrLabel:Tool_chest"])
        XCTAssertTrue(screen("qr-card").waitForExistence(timeout: 15))
        XCTAssertTrue(button("qr-share").exists)
        attachScreenshot("qr-label")

        scrollToProblems()
        button("qr-remove").tap()
        let remove = app.alerts["Remove this label?"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.buttons["Remove"].tap()
        let make = button("qr-generate")
        XCTAssertTrue(make.waitForExistence(timeout: 5))
        XCTAssertTrue(text("Label removed.").waitForExistence(timeout: 5))
        XCTAssertTrue(button("qr-link-sticker").exists)

        make.tap()
        XCTAssertTrue(screen("qr-card").waitForExistence(timeout: 5))

        scrollToProblems()
        button("qr-replace").tap()
        let replace = app.alerts["Replace this label?"]
        XCTAssertTrue(replace.waitForExistence(timeout: 5))
        replace.buttons["Replace"].tap()
        XCTAssertTrue(text("New label made.").waitForExistence(timeout: 5))
        XCTAssertTrue(screen("qr-card").exists)
    }

    func testTheStickerCameraOpensFromTheQrLabelAndCloses() throws {
        launch(["-demoArea", "labels", "-demoState", "camera", "-demoRoute", "qrLabel:Red_bin"])
        let link = button("qr-link-sticker")
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        link.tap()
        XCTAssertTrue(screen("screen-link-sticker").waitForExistence(timeout: 5))
        XCTAssertTrue(text("Scan the sticker for Red bin").waitForExistence(timeout: 5))
        attachScreenshot("sticker-camera")
        button("link-close").tap()
        XCTAssertTrue(waitForAbsence(screen("screen-link-sticker")))
        XCTAssertTrue(screen("screen-qr-label").exists)
    }

    func testAStickerReadByTheCameraIsLinked() throws {
        launch(["-demoArea", "labels", "-demoState", "stickerLinked"])
        XCTAssertTrue(text("Sticker linked to Red bin.").waitForExistence(timeout: 20))
        XCTAssertTrue(screen("qr-card").waitForExistence(timeout: 5))
        XCTAssertFalse(screen("screen-link-sticker").exists)
    }
}
