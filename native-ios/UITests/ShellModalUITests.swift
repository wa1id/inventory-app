import XCTest

/// The modal stack and the overlay window on a real tab bar and real sheets (06 §3, D-8): a
/// sheet replaced by a cover and back, a cover's root replaced in place, re-taps, a toast that
/// lets touches through outside its card, and the removed-phone layer over an open sheet. The
/// app runs in its DEBUG demo mode (sample inventory in memory, nothing on the device touched).
@MainActor
final class ShellModalUITests: XCTestCase {
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

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Waits until `element` is gone.
    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    func testSnapSeveralReplacesTheAddSheetWithTheCamera() throws {
        launch()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 15))
        app.tabBars.buttons["tab-add"].tap()
        XCTAssertTrue(screen("screen-add").waitForExistence(timeout: 5))

        app.buttons["item-snap-several"].tap()

        XCTAssertTrue(screen("screen-capture").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForAbsence(screen("screen-add")))
        attachScreenshot("snap-several-camera")
        app.buttons["capture-close"].tap()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["tab-home"].isHittable)
    }

    func testTypeItInsteadReplacesTheCameraWithTheAddSheet() throws {
        launch()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 15))
        app.buttons["Quick Snap"].firstMatch.tap()
        XCTAssertTrue(screen("screen-capture").waitForExistence(timeout: 5))
        // Quick Snap opens in fast mode; Type it instead is the single camera's keyboard button.
        app.segmentedControls.buttons["One item"].tap()

        app.buttons["capture-manual"].tap()

        XCTAssertTrue(screen("screen-add").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForAbsence(screen("screen-capture")))
        app.buttons["add-cancel"].tap()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["tab-home"].isHittable)
    }

    func testKeepShootingReplacesTheReviewWithANewCameraInTheSameCover() throws {
        launch()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 15))
        app.buttons["Quick Snap"].firstMatch.tap()
        XCTAssertTrue(screen("screen-capture").waitForExistence(timeout: 5))
        // Done with no shot just closes the camera; one shot (the demo's stand-in camera) makes
        // a set that ends on the review.
        app.buttons["capture-shutter"].tap()
        let shot = expectation(for: NSPredicate(format: "label == 'Done, 1 photo taken'"), evaluatedWith: app.buttons["capture-done"])
        XCTAssertEqual(XCTWaiter().wait(for: [shot], timeout: 10), .completed)
        app.buttons["capture-done"].tap()
        XCTAssertTrue(screen("screen-review").waitForExistence(timeout: 5))

        app.buttons["fast-review-more"].tap()

        XCTAssertTrue(screen("screen-capture").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForAbsence(screen("screen-review")))
        app.buttons["capture-close"].tap()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 5))
    }

    func testReTappingHomeOnAPushedScreenOnlyPopsIt() throws {
        launch()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 15))
        let reselections = screen("debug-home-reselections")
        XCTAssertEqual(reselections.label, "0")

        app.buttons["home-settings"].tap()
        XCTAssertTrue(screen("screen-settings").waitForExistence(timeout: 5))
        app.tabBars.buttons["tab-home"].tap()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForAbsence(screen("screen-settings")))
        // The pop is the whole answer: no "scroll to top / focus search" on top of it.
        XCTAssertEqual(screen("debug-home-reselections").label, "0")

        app.tabBars.buttons["tab-home"].tap()
        let one = expectation(for: NSPredicate(format: "label == '1'"), evaluatedWith: screen("debug-home-reselections"))
        XCTAssertEqual(XCTWaiter().wait(for: [one], timeout: 5), .completed)
    }

    func testAToastLetsTouchesThroughOutsideItsCard() throws {
        launch(["-demoToast", "action"])
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 15))
        XCTAssertTrue(screen("toast").waitForExistence(timeout: 5))
        attachScreenshot("toast-over-tabs")

        // The tab bar sits under the overlay window: the touch reaches it.
        app.tabBars.buttons["tab-spaces"].tap()
        XCTAssertTrue(screen("screen-spaces").waitForExistence(timeout: 5))
        XCTAssertTrue(screen("toast").exists)

        // The card's own buttons are the overlay's.
        app.buttons["toast-action"].tap()
        XCTAssertTrue(waitForAbsence(screen("toast")))
    }

    func testTheRemovedPhoneLayerCoversAnOpenSheetAndLeavesWithTheLocalButton() throws {
        launch(["-demoHousehold", "revoked", "-demoOpen", "add"])
        XCTAssertTrue(screen("revoked").waitForExistence(timeout: 15))
        XCTAssertTrue(waitForAbsence(screen("screen-add")))
        attachScreenshot("revoked-layer")

        app.buttons["revoked-local"].tap()

        XCTAssertTrue(waitForAbsence(screen("revoked")))
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["tab-home"].isHittable)
    }
}
