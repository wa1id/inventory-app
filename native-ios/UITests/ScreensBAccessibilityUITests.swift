import XCTest

/// VoiceOver semantics and largest-size layout of the place, item, Add and capture screens,
/// read from the accessibility hierarchy (labels, identifiers, element types and frames), on
/// the DEBUG demo's sample inventory. Run them on the iPhone 17 Pro and with `DEVICE=se` (a
/// 667 pt phone). Text sizes come from the `-UIPreferredContentSizeCategoryName` launch
/// argument (see `ScreensAuditUITests`).
@MainActor
final class ScreensBAccessibilityUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
    }

    private func launch(_ arguments: [String], size: ScreensAuditUITests.Size = .standard) {
        app.launchArguments = ["-demo", "YES"] + arguments + ["-UIPreferredContentSizeCategoryName", size.rawValue]
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
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

    private func settle(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }

    // MARK: Places

    /// The crumb is a link that says where it goes, the code is spelled, the QR entry says
    /// whether a label is linked, and the camera icon has its words (RN container/[id]).
    func testContainerHeadReadsAsRNDid() throws {
        launch(["-demoRoute", "container:Tool_chest"])
        XCTAssertTrue(element("screen-container").waitForExistence(timeout: 20))
        let crumb = app.links["container-space"]
        XCTAssertTrue(crumb.waitForExistence(timeout: 5), "the crumb is a link, not a button")
        XCTAssertEqual(crumb.label, "In Garage. Opens the space.")
        XCTAssertTrue(element("Label code C A B, J 9 2 R").exists, "the code is spelled")
        XCTAssertEqual(app.buttons["container-qr"].label, "QR label, linked. Opens the label.")
        XCTAssertEqual(app.buttons["items-capture"].label, "Take a photo of a new item")
        XCTAssertEqual(app.buttons["container-edit"].label, "Edit Tool chest")
    }

    /// At AX5 the head leaves room for the contents on the first screen, and Add here keeps to
    /// one line beside the camera (the known wave-5 issue).
    func testContainerAtTheLargestSizeShowsItsContents() throws {
        launch(["-demoRoute", "container:Tool_chest"], size: .largest)
        XCTAssertTrue(element("screen-container").waitForExistence(timeout: 20))
        let add = app.buttons["items-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        let firstRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'item-row-'")).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        attachScreenshot("container-ax5")
        XCTAssertLessThan(firstRow.frame.minY, add.frame.minY - 40, "a row starts above the bar")
        XCTAssertLessThan(add.frame.height, 80, "Add here keeps to one line")
        XCTAssertEqual(app.buttons["items-capture"].frame.midY, add.frame.midY, accuracy: 2)
    }

    // MARK: Add

    /// The place step's Back is labelled as RN's was, the form's keyboard does not stay up over
    /// the picker, and Back returns to the form.
    func testAddPlaceStepBackIsLabelledAndGoesBack() throws {
        launch(["-demoArea", "add", "-demoState", "place"])
        let back = app.buttons["add-back"]
        XCTAssertTrue(back.waitForExistence(timeout: 20))
        XCTAssertEqual(back.label, "Back")
        XCTAssertTrue(app.navigationBars["Where does it go?"].exists)
        settle(1)
        XCTAssertEqual(app.keyboards.count, 0, "the form's keyboard went with the form")
        back.tap()
        XCTAssertTrue(app.navigationBars["Add an item"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["item-name"].exists)
    }

    /// Offline, after a failed save, at AX5, typing again: the name field sits in full between
    /// the pinned chrome and the keyboard, and both Save buttons stay in reach (the known wave-5
    /// issue). The failed save put the keyboard away, so the notice was seen in full first.
    func testAddNameStaysInSightWhileTypingOfflineAtTheLargestSize() throws {
        launch(["-demoHousehold", "offline", "-demoArea", "add", "-demoState", "saveProblem"], size: .largest)
        let notice = element("add-save-problem")
        XCTAssertTrue(notice.waitForExistence(timeout: 25))
        let words = notice.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "It was not saved")).firstMatch
        XCTAssertTrue(words.exists, "the notice reads its words")
        XCTAssertTrue(waitForAbsence(app.keyboards.firstMatch, timeout: 5), "the failed save put the keyboard away")
        attachScreenshot("add-offline-problem-ax5")

        let name = app.textFields["item-name"]
        name.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        settle(1.5)
        attachScreenshot("add-offline-typing-ax5")
        let save = app.buttons["item-save"]
        let another = app.buttons["item-save-and-add"]
        XCTAssertTrue(save.isHittable)
        XCTAssertTrue(another.isHittable)
        let keyboardTop = app.keyboards.firstMatch.frame.minY
        let barTop = min(save.frame.minY, another.frame.minY)
        XCTAssertLessThanOrEqual(name.frame.maxY, min(barTop, keyboardTop) + 1, "the field ends above the bar")
        XCTAssertGreaterThanOrEqual(name.frame.minY, app.navigationBars.firstMatch.frame.maxY - 1, "the field starts below the bar at the top")
        // Side by side, the longer label on two lines: their frames overlap from top to bottom.
        XCTAssertTrue(save.frame.minY < another.frame.maxY && another.frame.minY < save.frame.maxY, "the two buttons share a row while typing")
        XCTAssertNotEqual(save.frame.midX, another.frame.midX, accuracy: 20)
    }

    // MARK: Capture

    /// A single photo being saved: the shutter is busy and says nothing new, the hint says why,
    /// and the library waits.
    func testSinglePhotoBeingSavedShowsTheBusyShutter() throws {
        launch(["-demoArea", "capture", "-demoState", "singleProcessing"])
        let shutter = app.buttons["capture-shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 20))
        let busy = expectation(for: NSPredicate(format: "isEnabled == false"), evaluatedWith: shutter)
        XCTAssertEqual(XCTWaiter().wait(for: [busy], timeout: 10), .completed)
        XCTAssertEqual(element("capture-hint").label, "Saving your photo…")
        XCTAssertFalse(app.buttons["capture-library"].isEnabled)
        attachScreenshot("single-processing")
    }

    /// The review's emptied state is titled like the other empty states (a heading with its
    /// glyph); RN had no icon there, but its heading was bold like every empty state's.
    func testReviewEmptiedStateHasItsHeading() throws {
        launch(["-demoArea", "capture", "-demoState", "reviewEmptied"])
        XCTAssertTrue(element("screen-review").waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Nothing left in this set"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["fast-review-done"].isHittable)
        attachScreenshot("review-emptied")
    }
}
