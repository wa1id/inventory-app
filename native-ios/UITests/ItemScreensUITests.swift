import XCTest

/// The item area driven like a person, on the DEBUG demo's sample inventory (nothing on the
/// device is touched): the item screen, naming an unnamed shot in place, Edit details, Move and
/// a filing run, Delete, and the photo viewer.
@MainActor
final class ItemScreensUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
    }

    private func launch(_ route: String, _ extra: [String] = []) {
        app.launchArguments = ["-demo", "YES", "-demoRoute", route] + extra
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

    /// The first enabled place in the picker whose label holds `name`.
    private func place(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'move-to-' AND label CONTAINS %@", name)).firstMatch
    }

    func testItemScreenShowsWhereItIsAndEditsDetails() throws {
        launch("item:Cordless_drill")
        XCTAssertTrue(element("screen-item").waitForExistence(timeout: 15))
        XCTAssertTrue(element("where-card").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["item-move"].exists)
        attachScreenshot("item")

        app.buttons["item-edit"].tap()
        XCTAssertTrue(element("screen-item-edit").waitForExistence(timeout: 5))
        let notes = element("item-notes")
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        notes.tap()
        notes.typeText(" Spare battery too.")
        app.buttons["item-save-changes"].tap()
        XCTAssertTrue(element("screen-item-edit").waitForNonExistence(timeout: 5))
        XCTAssertTrue(element("screen-item").exists)
        let saved = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Spare battery too.")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
    }

    func testEditDetailsCancelClosesAnUntouchedForm() throws {
        launch("item:Cordless_drill>itemEdit:Cordless_drill")
        XCTAssertTrue(element("screen-item-edit").waitForExistence(timeout: 15))
        app.buttons["sheet-close"].tap()
        XCTAssertTrue(element("screen-item-edit").waitForNonExistence(timeout: 5))
        XCTAssertTrue(element("screen-item").exists)
    }

    func testMoveFromTheItemScreenStaysOnTheItem() throws {
        launch("item:Cordless_drill")
        XCTAssertTrue(app.buttons["item-move"].waitForExistence(timeout: 15))
        app.buttons["item-move"].tap()
        XCTAssertTrue(element("screen-move").waitForExistence(timeout: 5))
        let redBin = place("Red bin")
        XCTAssertTrue(redBin.waitForExistence(timeout: 5))
        attachScreenshot("move")
        redBin.tap()
        XCTAssertTrue(element("screen-move").waitForNonExistence(timeout: 5))
        XCTAssertTrue(element("screen-item").exists)
        let undo = app.buttons["toast-action"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertEqual(undo.label, "Undo moving Cordless drill")
        XCTAssertTrue(element("where-container").waitForExistence(timeout: 5))
        XCTAssertEqual(element("where-container").label, "Red bin")
    }

    func testMoveNoticeStaysInSightWhileThePickerScrolls() throws {
        // The item is deleted elsewhere, then a pick finds it gone: the notice with Close.
        launch("move:Cordless_drill", ["-demoArea", "item", "-demoState", "moveGone"])
        let notice = element("move-notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        // Pinned above the picker (RN move.tsx), not a row of it: scrolling the list to its end
        // leaves the notice and its Close where they were.
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.exists)
        list.swipeUp()
        list.swipeUp()
        XCTAssertTrue(notice.isHittable)
        let close = app.buttons["move-notice-close"]
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(element("screen-move").waitForNonExistence(timeout: 5))
    }

    func testFilingRunGoesOnToTheNextWaitingItem() throws {
        launch("itemFiling:HDMI_cable")
        XCTAssertTrue(app.buttons["item-file"].waitForExistence(timeout: 15))
        app.buttons["item-file"].tap()
        XCTAssertTrue(element("screen-move").waitForExistence(timeout: 5))
        let toolChest = place("Tool chest")
        XCTAssertTrue(toolChest.waitForExistence(timeout: 5))
        toolChest.tap()
        XCTAssertTrue(element("screen-move").waitForNonExistence(timeout: 5))
        // The screen replaces itself with the next waiting item: the count goes down to three,
        // and that item waits in the drop zone too.
        XCTAssertTrue(app.staticTexts["3 waiting"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("screen-item").exists)
        XCTAssertTrue(app.buttons["item-file"].waitForExistence(timeout: 5))
        attachScreenshot("next-in-run")
    }

    func testAnUnnamedItemIsNamedInPlace() throws {
        launch("item:")
        let field = element("item-name")
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("Bike lock")
        app.buttons["item-name-it"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        let title = element("item-title")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Bike lock")
    }

    func testDeleteAsksFirstThenGoesBack() throws {
        launch("item:Spare_keys")
        XCTAssertTrue(app.buttons["item-delete"].waitForExistence(timeout: 15))
        app.buttons["item-delete"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertEqual(alert.label, "Delete “Spare keys”?")
        alert.buttons["Delete"].tap()
        XCTAssertTrue(element("screen-item").waitForNonExistence(timeout: 5))
    }

    func testPhotoViewerOpensAndCloses() throws {
        launch("item:Cordless_drill")
        let photo = app.buttons["item-photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 15))
        photo.tap()
        XCTAssertTrue(element("screen-photo").waitForExistence(timeout: 5))
        XCTAssertTrue(element("photo-image").waitForExistence(timeout: 5))
        XCTAssertEqual(element("photo-image").label, "Photo of Cordless drill")
        attachScreenshot("photo")
        app.buttons["photo-close"].tap()
        XCTAssertTrue(element("screen-photo").waitForNonExistence(timeout: 5))
        XCTAssertTrue(element("screen-item").exists)
    }
}
