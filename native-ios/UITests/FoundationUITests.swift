import XCTest

/// The screen foundation driven like a person: `-demoRoute` specs opening routes in order,
/// `-demoSeed empty`, and `PlacePickerHost` in its gallery (pick, filter, no match). The app
/// runs in its DEBUG demo mode (sample inventory in memory, nothing on the device touched).
@MainActor
final class FoundationUITests: XCTestCase {
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
        app.launchArguments = arguments
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

    func testDemoRouteOpensSpecsInOrder() throws {
        launch(["-demo", "YES", "-demoRoute", "container:Tool chest>containerEdit:Tool_chest"])
        XCTAssertTrue(screen("screen-container").waitForExistence(timeout: 15))
        XCTAssertTrue(screen("screen-container-edit").waitForExistence(timeout: 5))
        attachScreenshot("container-then-edit")
        app.buttons["sheet-close"].tap()
        XCTAssertTrue(screen("screen-container").waitForExistence(timeout: 5))
    }

    func testDemoOpenStillWorksThroughRoutes() throws {
        launch(["-demo", "YES", "-demoOpen", "move"])
        XCTAssertTrue(screen("screen-move").waitForExistence(timeout: 15))
    }

    func testUnknownSpecOpensNothingAndTheRestStillOpen() throws {
        launch(["-demo", "YES", "-demoTab", "spaces", "-demoRoute", "space:Nowhere>file:Spare_keys"])
        XCTAssertTrue(screen("screen-move").waitForExistence(timeout: 15))
        XCTAssertFalse(screen("screen-space").exists)
    }

    func testPlacePickerHostPicksAndFilters() throws {
        launch(["-gallery", "foundation", "-galleryPage", "0"])
        // Move mode: grouped by space, no drop zone; the item's own container is Here now.
        let firstOption = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'move-to-'")).firstMatch
        XCTAssertTrue(firstOption.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["place-drop-zone"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'place-recent-'")).firstMatch.exists)

        // The filter is the stock search field (it takes no identifier; see PlacePicker).
        let filter = app.searchFields.firstMatch
        XCTAssertTrue(filter.exists)
        filter.tap()
        filter.typeText("bin4f")
        let redBin = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'move-to-'")).firstMatch
        XCTAssertTrue(redBin.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'place-new-container-'")).firstMatch.exists)
        redBin.tap()
        let pickedRedBin = app.staticTexts["foundation-picked"]
        XCTAssertTrue(pickedRedBin.waitForExistence(timeout: 5))
        XCTAssertEqual(pickedRedBin.label, "Picked Red bin")
        attachScreenshot("picked")
    }

    func testPlacePickerHostChooseOffersTheDropZone() throws {
        launch(["-gallery", "foundation", "-galleryPage", "2"])
        let dropZone = app.buttons["place-drop-zone"]
        XCTAssertTrue(dropZone.waitForExistence(timeout: 15))
        dropZone.tap()
        let pickedDropZone = app.staticTexts["foundation-picked"]
        XCTAssertTrue(pickedDropZone.waitForExistence(timeout: 5))
        XCTAssertEqual(pickedDropZone.label, "Picked Drop zone")
    }

    func testPlacePickerHostWithNothingAtAllOffersANewSpace() throws {
        launch(["-gallery", "foundation", "-galleryPage", "6"])
        XCTAssertTrue(app.buttons["move-no-containers"].waitForExistence(timeout: 15))
    }
}
