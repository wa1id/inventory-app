import XCTest

/// Journeys that cross areas, now that every screen is real: an item added into a container,
/// found from Home, opened and moved into a container made from the picker; the Add sheet's
/// place step making a container (and a space first when there are none); a drop-zone item
/// filed. The app runs in its DEBUG demo mode (sample inventory in memory, nothing on the device
/// touched).
@MainActor
final class IntegrationJourneyUITests: XCTestCase {
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

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func button(beginningWith prefix: String, labelContaining text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", prefix, text)).firstMatch
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func toastMessage() -> String? {
        let toast = element("toast")
        guard toast.waitForExistence(timeout: 5) else { return nil }
        return toast.staticTexts.firstMatch.label
    }

    /// Types into a field once it has the keyboard (some take focus on arrival).
    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let focused = expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: field)
        if XCTWaiter().wait(for: [focused], timeout: 2) != .completed { field.tap() }
        field.typeText(text)
    }

    /// Filters the place picker by typing into its own search field (Home's, "Find anything",
    /// may be under the sheet).
    private func filterPicker(_ text: String) {
        let filter = app.searchFields.matching(NSPredicate(format: "placeholderValue == %@", "Container, space or code")).firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.tap()
        filter.typeText(text)
    }

    /// The container form opened from a picker: names it and creates it.
    private func createContainer(named name: String) {
        XCTAssertTrue(element("screen-container-new").waitForExistence(timeout: 5))
        type(name, into: app.textFields["container-name"])
        attachScreenshot("container-form")
        app.buttons["container-create"].tap()
        XCTAssertTrue(element("screen-container-new").waitForNonExistence(timeout: 10))
    }

    func testAnItemAddedToAContainerIsFoundFromHomeOpenedAndMovedIntoANewContainer() throws {
        launch(["-demoRoute", "container:Red_bin"])
        XCTAssertTrue(element("screen-container").waitForExistence(timeout: 15))

        // Add here.
        app.buttons["items-add"].tap()
        XCTAssertTrue(element("screen-add").waitForExistence(timeout: 5))
        type("Head torch", into: app.textFields["item-name"])
        app.buttons["item-save"].tap()
        XCTAssertTrue(element("screen-add").waitForNonExistence(timeout: 5))
        XCTAssertEqual(toastMessage(), "Saved in Red bin (Garage).")
        let row = button(beginningWith: "item-row-", labelContaining: "Head torch")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the container lists the new item")

        // Found from Home.
        app.tabBars.buttons["tab-home"].tap()
        XCTAssertTrue(element("screen-home").waitForExistence(timeout: 5))
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("head torch")
        let hit = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Head torch")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5))
        attachScreenshot("found")
        hit.tap()

        // Opened, then moved into a container made from the picker.
        XCTAssertTrue(element("screen-item").waitForExistence(timeout: 5))
        XCTAssertEqual(element("where-container").label, "Red bin")
        app.buttons["item-move"].tap()
        XCTAssertTrue(element("screen-move").waitForExistence(timeout: 5))
        let newInGarage = button(beginningWith: "place-new-container-", labelContaining: "Garage")
        XCTAssertTrue(newInGarage.waitForExistence(timeout: 5))
        newInGarage.tap()
        createContainer(named: "Lamp shelf")

        XCTAssertTrue(element("screen-move").waitForNonExistence(timeout: 10), "the made container is the pick")
        XCTAssertTrue(element("screen-item").exists)
        let moved = expectation(for: NSPredicate(format: "label == %@", "Lamp shelf"), evaluatedWith: element("where-container"))
        XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 5), .completed)
        attachScreenshot("moved")
    }

    func testTheAddSheetsPlaceStepMakesANewContainerAndPicksIt() throws {
        launch()
        XCTAssertTrue(element("screen-home").waitForExistence(timeout: 15))
        app.tabBars.buttons["tab-add"].tap()
        XCTAssertTrue(element("screen-add").waitForExistence(timeout: 5))
        type("Rolling pin", into: app.textFields["item-name"])
        app.buttons["item-where-more"].tap()

        // Kitchen's rows are below the fold of a lazy list: narrow it to them first.
        filterPicker("kitchen")
        let newInKitchen = button(beginningWith: "place-new-container-", labelContaining: "Kitchen")
        XCTAssertTrue(newInKitchen.waitForExistence(timeout: 5))
        newInKitchen.tap()
        createContainer(named: "Baking tub")

        // Back on the form with the new container chosen.
        let save = app.buttons["item-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        let chosen = expectation(for: NSPredicate(format: "label == %@", "Save in Baking tub, Kitchen"), evaluatedWith: save)
        XCTAssertEqual(XCTWaiter().wait(for: [chosen], timeout: 5), .completed)
        attachScreenshot("picked")
        save.tap()
        XCTAssertTrue(element("screen-add").waitForNonExistence(timeout: 5))
        XCTAssertEqual(toastMessage(), "Saved in Baking tub (Kitchen).")
    }

    func testWithNoContainersTheAddSheetMakesASpaceThenAContainer() throws {
        launch(["-demoSeed", "empty"])
        XCTAssertTrue(element("screen-home").waitForExistence(timeout: 15))
        app.tabBars.buttons["tab-add"].tap()
        XCTAssertTrue(element("screen-add").waitForExistence(timeout: 5))
        type("Hammer", into: app.textFields["item-name"])
        app.buttons["item-where-more"].tap()

        let start = app.buttons["move-no-containers"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(element("screen-space-new").waitForExistence(timeout: 5))
        let garage = app.buttons["space-preset-garage"]
        XCTAssertTrue(garage.waitForExistence(timeout: 5))
        garage.tap()
        createContainer(named: "Tool box")

        let save = app.buttons["item-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        let chosen = expectation(for: NSPredicate(format: "label == %@", "Save in Tool box, Garage"), evaluatedWith: save)
        XCTAssertEqual(XCTWaiter().wait(for: [chosen], timeout: 5), .completed)
        save.tap()
        XCTAssertTrue(element("screen-add").waitForNonExistence(timeout: 5))
        XCTAssertEqual(toastMessage(), "Saved in Tool box (Garage).")
    }

    func testADropZoneItemFiledIntoAContainerLeavesTheDropZone() throws {
        launch(["-demoTab", "dropZone"])
        XCTAssertTrue(element("screen-drop-zone").waitForExistence(timeout: 15))
        let keys = button(beginningWith: "drop-zone-file-", labelContaining: "Spare keys")
        XCTAssertTrue(keys.waitForExistence(timeout: 5))
        keys.tap()
        XCTAssertTrue(element("screen-move").waitForExistence(timeout: 5))
        let chest = button(beginningWith: "move-to-", labelContaining: "Tool chest")
        XCTAssertTrue(chest.waitForExistence(timeout: 5))
        chest.tap()
        XCTAssertTrue(element("screen-move").waitForNonExistence(timeout: 5))
        XCTAssertTrue(keys.waitForNonExistence(timeout: 5), "the filed item leaves the drop zone")
        attachScreenshot("filed")

        // And it is in the chest now.
        app.tabBars.buttons["tab-home"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("spare keys")
        let hit = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Spare keys")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5))
        XCTAssertTrue(hit.label.contains("Tool chest"), "found in the chest: \(hit.label)")
    }
}
