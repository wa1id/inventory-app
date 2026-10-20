import XCTest

/// The camera and the Quick Snap review on the simulator (05 §4, §6), launched with `-demo YES`:
/// there the camera is the stand-in from `CaptureDemo` (the simulator has none), so the shutter
/// works and every shot becomes a real row in the in-memory inventory.
@MainActor
final class CaptureUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
    }

    private func launch(_ arguments: [String] = []) {
        app.launchArguments = ["-demo", "YES"] + arguments
        app.launch()
    }

    private func screen(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func button(_ identifier: String) -> XCUIElement {
        app.buttons[identifier].firstMatch
    }

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 10) -> Bool {
        let match = expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: element)
        return XCTWaiter().wait(for: [match], timeout: timeout) == .completed
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Quick Snap from Home's drop-zone card, with `shots` taken.
    private func quickSnap(shots: Int) {
        launch()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 15))
        app.buttons["Quick Snap"].firstMatch.tap()
        XCTAssertTrue(button("capture-shutter").waitForExistence(timeout: 5))
        for count in 1...shots {
            button("capture-shutter").tap()
            let done = count == 1 ? "Done, 1 photo taken" : "Done, \(count) photos taken"
            XCTAssertTrue(waitForLabel(button("capture-done"), done), "shot \(count) did not land")
        }
    }

    // MARK: Single and request

    func testASinglePhotoOpensTheAddSheet() throws {
        launch(["-demoRoute", "capture:Tool_chest"])
        XCTAssertTrue(screen("screen-capture").waitForExistence(timeout: 15))
        XCTAssertTrue(screen("capture-into").waitForExistence(timeout: 5))
        XCTAssertEqual(screen("capture-into").label, "Photos go into Tool chest, in Garage, label C A B, J 9 2 R")
        attachScreenshot("single-camera")

        button("capture-shutter").tap()

        XCTAssertTrue(screen("screen-add").waitForExistence(timeout: 10))
        XCTAssertTrue(waitForAbsence(screen("screen-capture")))
    }

    func testTypeItInsteadReplacesTheSingleCameraWithTheAddSheet() throws {
        launch(["-demoRoute", "capture:Tool_chest"])
        XCTAssertTrue(button("capture-manual").waitForExistence(timeout: 15))

        button("capture-manual").tap()

        XCTAssertTrue(screen("screen-add").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForAbsence(screen("screen-capture")))
    }

    func testFlashTogglesAndSaysSo() throws {
        launch(["-demoRoute", "capture"])
        let flash = button("capture-flash")
        XCTAssertTrue(flash.waitForExistence(timeout: 15))
        XCTAssertEqual(flash.label, "Flash, off")
        flash.tap()
        XCTAssertTrue(waitForLabel(flash, "Flash, on"))
        XCTAssertTrue(flash.isSelected)
    }

    // MARK: Quick Snap

    func testAQuickSnapSetEndsOnTheReviewAndDoneSaysWhereTheItemsAre() throws {
        quickSnap(shots: 2)
        XCTAssertTrue(screen("capture-status").waitForExistence(timeout: 10))
        attachScreenshot("quick-snap-two-shots")

        button("capture-done").tap()

        XCTAssertTrue(screen("screen-review").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(screen("fast-review-title"), "2 saved to the drop zone"))
        let deletes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'review-delete-'"))
        XCTAssertEqual(deletes.count, 2)
        attachScreenshot("review")

        button("fast-review-done").tap()

        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForAbsence(screen("screen-review")))
        let toast = screen("toast")
        XCTAssertTrue(toast.waitForExistence(timeout: 5))
        XCTAssertTrue(button("toast-action").exists, "the drop zone's toast offers View")
    }

    func testCloseOnASetWithShotsAlsoEndsOnTheReview() throws {
        quickSnap(shots: 1)

        button("capture-close").tap()

        XCTAssertTrue(screen("screen-review").waitForExistence(timeout: 5))
    }

    func testKeepShootingContinuesTheSetInANewCamera() throws {
        quickSnap(shots: 1)
        button("capture-done").tap()
        XCTAssertTrue(screen("screen-review").waitForExistence(timeout: 5))

        button("fast-review-more").tap()

        XCTAssertTrue(button("capture-shutter").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForAbsence(screen("screen-review")))
        // A fresh camera: nothing taken yet in this part of the set.
        XCTAssertEqual(button("capture-done").label, "Done")
        button("capture-close").tap()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 5))
    }

    func testSwipingBackFromTheReviewLandsWhereTheSetStarted() throws {
        quickSnap(shots: 1)
        button("capture-done").tap()
        XCTAssertTrue(screen("screen-review").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(screen("fast-review-title"), "1 saved to the drop zone"))

        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))

        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForAbsence(screen("screen-review")))
        XCTAssertTrue(waitForAbsence(screen("screen-capture")))
        // Swiping is not Done: no toast (05 Q13).
        XCTAssertFalse(screen("toast").exists)
    }

    func testTheModeLocksOnceASetHasAShot() throws {
        quickSnap(shots: 1)
        let single = app.segmentedControls.buttons["One item"]
        XCTAssertTrue(single.exists)
        XCTAssertFalse(single.isEnabled)
    }

    // MARK: Permission

    func testThePermissionGateGivesWayToTheCameraOnAllow() throws {
        launch(["-demoArea", "capture", "-demoState", "permission"])
        XCTAssertTrue(button("camera-allow").waitForExistence(timeout: 15))
        XCTAssertTrue(button("camera-library").exists)
        XCTAssertTrue(button("camera-manual").exists)

        button("camera-allow").tap()

        XCTAssertTrue(button("capture-shutter").waitForExistence(timeout: 5))
    }

    func testABlockedCameraStillOffersTypingTheItem() throws {
        launch(["-demoArea", "capture", "-demoState", "blocked"])
        XCTAssertTrue(button("camera-open-settings").waitForExistence(timeout: 15))

        button("camera-manual").tap()

        XCTAssertTrue(screen("screen-add").waitForExistence(timeout: 5))
    }

    func testTheGateForTheAddSheetsPhotoHasNoTypeItInstead() throws {
        launch(["-demoArea", "capture", "-demoState", "permissionRequest"])
        XCTAssertTrue(button("camera-allow").waitForExistence(timeout: 15))
        XCTAssertFalse(button("camera-manual").exists)
        button("capture-close").tap()
        XCTAssertTrue(waitForAbsence(screen("screen-capture")))
    }

    // MARK: Review

    func testDeletingAReviewRowAsksFirst() throws {
        launch(["-demoArea", "capture", "-demoState", "reviewNamed"])
        XCTAssertTrue(waitForLabel(screen("fast-review-title"), "3 saved to the drop zone", timeout: 20))
        let deletes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'review-delete-'"))
        XCTAssertEqual(deletes.count, 3)

        deletes.element(boundBy: 0).tap()
        let alert = app.alerts["Delete this item?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete"].tap()

        XCTAssertTrue(waitForLabel(screen("fast-review-title"), "2 saved to the drop zone"))
        XCTAssertEqual(deletes.count, 2)
    }

    func testNothingSavedOffersTryAgain() throws {
        launch(["-demoArea", "capture", "-demoState", "reviewNothing"])
        XCTAssertTrue(button("fast-review-try-again").waitForExistence(timeout: 15))

        button("fast-review-try-again").tap()

        XCTAssertTrue(button("capture-shutter").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForAbsence(screen("screen-review")))
    }
}
