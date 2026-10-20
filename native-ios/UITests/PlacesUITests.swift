import XCTest

/// The space and container screens driven like a person, on the DEBUG demo's sample inventory
/// (in memory; nothing on the device is touched): open each screen, its main action, its close.
@MainActor
final class PlacesUITests: XCTestCase {
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

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Closes the Add sheet with its own Cancel (RN `add-cancel`), or by swiping it down.
    private func closeAddSheet() {
        if app.buttons["add-cancel"].exists {
            app.buttons["add-cancel"].tap()
            return
        }
        app.swipeDown(velocity: .fast)
    }

    /// Waits until `element` is gone, not merely still there while a sheet slides away.
    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) {
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    /// Replaces what a field holds, wherever the cursor lands.
    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        field.typeText(text)
    }

    func testSpaceDetailListsItsContainersAndMakesANewOneThatOpens() throws {
        launch(["-demoTab", "spaces", "-demoRoute", "space:Garage"])
        XCTAssertTrue(element("screen-space").waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'container-row-'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["space-edit"].exists)

        app.buttons["containers-create"].tap()
        XCTAssertTrue(element("screen-container-new").waitForExistence(timeout: 5))
        app.buttons["tile-shelf"].tap()
        let name = app.textFields["container-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Paint shelf")
        app.buttons["container-create"].tap()

        // The new container replaces the sheet.
        XCTAssertTrue(element("screen-container").waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Paint shelf"].waitForExistence(timeout: 5))
        attachScreenshot("new-container-opened")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element("screen-space").waitForExistence(timeout: 5))
    }

    func testContainerDetailOffersAddHereTheLabelAndEdit() throws {
        launch(["-demoRoute", "container:Tool_chest"])
        XCTAssertTrue(element("screen-container").waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars["Tool chest"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("container-space").exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'item-row-'")).firstMatch.exists)

        app.buttons["items-add"].tap()
        XCTAssertTrue(element("screen-add").waitForExistence(timeout: 5))
        closeAddSheet()
        XCTAssertTrue(app.buttons["container-qr"].waitForExistence(timeout: 5))

        app.buttons["container-qr"].tap()
        XCTAssertTrue(element("screen-qr-label").waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(app.buttons["container-edit"].waitForExistence(timeout: 5))
        app.buttons["container-edit"].tap()
        XCTAssertTrue(element("screen-container-edit").waitForExistence(timeout: 5))
        let name = app.textFields["container-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        replaceText(in: name, with: "Tool chest (red)")
        app.buttons["container-save"].tap()
        XCTAssertTrue(app.navigationBars["Tool chest (red)"].waitForExistence(timeout: 10))
        waitForAbsence(element("screen-container-edit"))
    }

    func testCrumbOpensTheSpace() throws {
        launch(["-demoRoute", "container:Red_bin"])
        XCTAssertTrue(element("container-space").waitForExistence(timeout: 15))
        element("container-space").tap()
        XCTAssertTrue(element("screen-space").waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Garage"].exists)
    }

    func testNewSpacePresetCreatesAndOpensTheSpace() throws {
        launch(["-demoTab", "spaces", "-demoRoute", "spaceNew"])
        XCTAssertTrue(element("screen-space-new").waitForExistence(timeout: 15))
        // The seeded Garage is already added, once the space list is in.
        let garage = app.buttons["space-preset-garage"]
        XCTAssertTrue(garage.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "isEnabled == false"), evaluatedWith: garage)
        waitForExpectations(timeout: 5)
        app.buttons["space-preset-loft"].tap()
        XCTAssertTrue(element("screen-space").waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Loft"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["containers-empty"].exists)
    }

    func testNewSpaceAsksForANameBeforeCreating() throws {
        launch(["-demoRoute", "spaceNew"])
        XCTAssertTrue(element("screen-space-new").waitForExistence(timeout: 15))
        app.buttons["space-create-custom"].tap()
        XCTAssertTrue(app.staticTexts["Give the space a name."].waitForExistence(timeout: 5))
        let name = app.textFields["space-name"]
        name.tap()
        name.typeText("Hallway")
        XCTAssertFalse(app.staticTexts["Give the space a name."].exists)
        app.buttons["space-create-custom"].tap()
        XCTAssertTrue(app.navigationBars["Hallway"].waitForExistence(timeout: 10))
    }

    func testEditSpaceDeleteAsksFirstThenGoesToSpaces() throws {
        launch(["-demoTab", "spaces", "-demoRoute", "space:Attic>spaceEdit:Attic"])
        XCTAssertTrue(element("screen-space-edit").waitForExistence(timeout: 15))
        // Delete is the form's last row: scroll down to it.
        XCTAssertTrue(app.textFields["space-name"].waitForExistence(timeout: 5))
        let delete = app.buttons["space-delete"]
        // To the very end: just in view, it would still sit under the bottom bar's glass.
        for _ in 0..<4 {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        // Let the scroll settle, so the tap presses Delete rather than stopping the list.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "scroll settles")], timeout: 1.5)
        delete.tap()
        let alert = app.alerts["Delete Attic?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        attachScreenshot("delete-confirm")
        alert.buttons["Delete"].tap()
        XCTAssertTrue(element("screen-spaces").waitForExistence(timeout: 10))
        waitForAbsence(element("screen-space-edit"))
        waitForAbsence(element("screen-space"))
    }

    func testDirtyFormAsksBeforeDiscarding() throws {
        launch(["-demoRoute", "containerNew:Garage"])
        XCTAssertTrue(element("screen-container-new").waitForExistence(timeout: 15))
        let name = app.textFields["container-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Paint")
        app.buttons["sheet-close"].tap()
        let alert = app.alerts["Discard your changes?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Keep editing"].tap()
        XCTAssertTrue(element("screen-container-new").exists)
        app.buttons["sheet-close"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Discard"].tap()
        waitForAbsence(element("screen-container-new"))
    }

    func testUnreadContentsAreNeverShownAsEmpty() throws {
        // The container reads, its items do not: Try again, never "This cabinet is empty".
        launch(["-demoArea", "places", "-demoState", "contentsProblem", "-demoRoute", "container:Tool_chest"])
        XCTAssertTrue(element("screen-container").waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["error-retry"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["items-empty"].exists)
        XCTAssertFalse(app.buttons["items-add"].exists)
        attachScreenshot("contents-not-read")
    }

    func testDropZoneFormsAreLocked() throws {
        launch(["-demoRoute", "containerEdit:Drop_zone"])
        let action = app.buttons["Go to the drop zone"]
        XCTAssertTrue(action.waitForExistence(timeout: 15))
        action.tap()
        XCTAssertTrue(element("screen-drop-zone").waitForExistence(timeout: 5))
    }
}
