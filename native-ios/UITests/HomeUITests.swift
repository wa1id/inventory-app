import XCTest

/// Home, Spaces and the Drop zone driven like a person (06 §5-§7): the overview, searching in
/// place, the quantity chip, the drop-zone card, a re-tap, the search buttons elsewhere, the
/// Spaces list and filing from the Drop zone. The app runs in its DEBUG demo mode (sample
/// inventory in memory, nothing on the device touched).
@MainActor
final class HomeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
    }

    /// Launches the demo and waits for `screenIdentifier`, the tab it opens on.
    private func launch(_ arguments: [String] = [], showing screenIdentifier: String = "screen-home") {
        app.launchArguments = ["-demo", "YES"] + arguments
        app.launch()
        XCTAssertTrue(screen(screenIdentifier).waitForExistence(timeout: 15))
    }

    private func screen(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func element(beginningWith prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    private func button(labelled prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
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

    private var keyboardIsUp: Bool {
        app.keyboards.firstMatch.waitForExistence(timeout: 3)
    }

    // MARK: Home

    func testTheOverviewShowsTheNoticeTheCardAndRecentlyAdded() throws {
        launch()
        XCTAssertTrue(screen("unpaired-join").waitForExistence(timeout: 5))
        XCTAssertTrue(screen("drop-zone-card").exists)
        XCTAssertTrue(app.staticTexts["Recently added"].exists)
        attachScreenshot("home-overview")

        // Not now puts the notice away.
        app.buttons["Not now"].tap()
        XCTAssertTrue(waitForAbsence(screen("unpaired-join")))

        // The gear opens Settings.
        app.buttons["home-settings"].tap()
        XCTAssertTrue(screen("screen-settings").waitForExistence(timeout: 5))
    }

    func testSearchingShowsResultsInPlaceAndOpensAnItem() throws {
        launch()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("drill")

        let drill = button(labelled: "Cordless drill")
        XCTAssertTrue(drill.waitForExistence(timeout: 5))
        XCTAssertFalse(screen("drop-zone-card").exists)
        attachScreenshot("home-search")
        drill.tap()
        XCTAssertTrue(screen("screen-item").waitForExistence(timeout: 5))
    }

    func testNothingFoundOffersToAddIt() throws {
        launch(["-demoArea", "home", "-demoState", "noResults"])
        let add = app.buttons["search-add-missing"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(screen("screen-add").waitForExistence(timeout: 5))
        app.buttons["item-cancel"].tap()
        XCTAssertTrue(waitForAbsence(screen("screen-add")))
    }

    func testTheChipOpensTheStepperUnderTheRowAndDoneClosesIt() throws {
        launch()
        let chip = element(beginningWith: "qty-chip-")
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap()
        let increase = element(beginningWith: "quantity-increase-")
        XCTAssertTrue(increase.waitForExistence(timeout: 5))
        attachScreenshot("home-chip-open")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(waitForAbsence(increase))
    }

    func testAChipOpeningNearTheBottomScrollsItsStepperIntoView() throws {
        launch()
        let chips = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'qty-chip-'"))
        XCTAssertTrue(chips.firstMatch.waitForExistence(timeout: 5))
        // The lowest chip above the tab bar: its stepper opens below the fold.
        let barTop = app.tabBars.firstMatch.frame.minY
        let lowest = chips.allElementsBoundByIndex
            .filter { $0.isHittable && $0.frame.maxY < barTop - 8 }
            .max { $0.frame.maxY < $1.frame.maxY }
        let chip = try XCTUnwrap(lowest)
        let itemId = String(chip.identifier.dropFirst("qty-chip-".count))
        chip.tap()

        let increase = app.descendants(matching: .any)["quantity-increase-\(itemId)"]
        XCTAssertTrue(increase.waitForExistence(timeout: 5))
        let revealed = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: increase)
        XCTAssertEqual(XCTWaiter().wait(for: [revealed], timeout: 5), .completed)
        attachScreenshot("home-chip-revealed")
    }

    func testTheCardSortsTheDropZoneAndQuickSnapOpensTheCamera() throws {
        launch()
        app.buttons["drop-zone-open"].tap()
        XCTAssertTrue(screen("screen-drop-zone").waitForExistence(timeout: 5))

        app.tabBars.buttons["tab-home"].tap()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 5))
        app.buttons["quick-snap"].tap()
        XCTAssertTrue(screen("screen-capture").waitForExistence(timeout: 5))
    }

    func testReTappingHomeScrollsToTheTopThenFocusesTheSearch() throws {
        launch(["-demoArea", "home", "-demoState", "noticeDismissed"])
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let card = screen("drop-zone-card")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        list.swipeUp()
        list.swipeUp()
        XCTAssertFalse(card.isHittable)

        app.tabBars.buttons["tab-home"].tap()
        let back = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: card)
        XCTAssertEqual(XCTWaiter().wait(for: [back], timeout: 5), .completed)
        XCTAssertFalse(app.keyboards.firstMatch.exists)

        // From the top, a re-tap goes into the field.
        app.tabBars.buttons["tab-home"].tap()
        XCTAssertTrue(keyboardIsUp)
    }

    func testTheSearchButtonOnASpacePushedOnHomeComesBackWithTheKeyboardUp() throws {
        launch(["-demoArea", "home", "-demoState", "searchPlaces"])
        let garage = element(beginningWith: "space-row-")
        XCTAssertTrue(garage.waitForExistence(timeout: 5))
        garage.tap()
        XCTAssertTrue(screen("screen-space").waitForExistence(timeout: 5))

        app.buttons["search-button"].firstMatch.tap()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForAbsence(screen("screen-space")))
        XCTAssertTrue(keyboardIsUp)
    }

    // MARK: Spaces

    func testSpacesListsTheSpacesOpensOneAndOffersANewSpace() throws {
        launch()
        app.tabBars.buttons["tab-spaces"].tap()
        XCTAssertTrue(screen("screen-spaces").waitForExistence(timeout: 5))
        let garage = button(labelled: "Garage")
        XCTAssertTrue(garage.waitForExistence(timeout: 5))
        attachScreenshot("spaces")
        garage.tap()
        XCTAssertTrue(screen("screen-space").waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(screen("screen-spaces").waitForExistence(timeout: 5))

        app.buttons["spaces-create-row"].tap()
        XCTAssertTrue(screen("screen-space-new").waitForExistence(timeout: 5))
        app.buttons["sheet-close"].tap()
        XCTAssertTrue(waitForAbsence(screen("screen-space-new")))

        app.buttons["spaces-create"].tap()
        XCTAssertTrue(screen("screen-space-new").waitForExistence(timeout: 5))
    }

    func testSpacesSearchButtonGoesHomeWithTheKeyboardUp() throws {
        launch()
        app.tabBars.buttons["tab-spaces"].tap()
        XCTAssertTrue(screen("screen-spaces").waitForExistence(timeout: 5))
        app.buttons["spaces-search"].tap()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 5))
        XCTAssertTrue(keyboardIsUp)
    }

    func testNoSpacesYetOffersTheFirstOne() throws {
        launch(["-demoSeed", "empty", "-demoTab", "spaces"], showing: "screen-spaces")
        let start = app.buttons["spaces-empty"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(screen("screen-space-new").waitForExistence(timeout: 5))
    }

    // MARK: Drop zone

    func testTheDropZoneFilesARowThroughTheMoveSheetAndOpensARowAsAFilingRun() throws {
        launch(["-demoTab", "dropZone"], showing: "screen-drop-zone")
        let file = element(beginningWith: "drop-zone-file-")
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        attachScreenshot("drop-zone")
        file.tap()
        XCTAssertTrue(screen("screen-move").waitForExistence(timeout: 5))
        // Closed without moving: the row stays.
        app.buttons["sheet-close"].tap()
        XCTAssertTrue(waitForAbsence(screen("screen-move")))
        XCTAssertTrue(file.exists)

        button(labelled: "Bike pump").tap()
        XCTAssertTrue(screen("screen-item").waitForExistence(timeout: 5))
    }

    func testReTappingTheDropZoneScrollsALongBacklogToTheTop() throws {
        launch(["-demoArea", "home", "-demoState", "backlog", "-demoTab", "dropZone"], showing: "screen-drop-zone")
        let quickSnap = app.buttons["drop-zone-capture"]
        XCTAssertTrue(quickSnap.waitForExistence(timeout: 10))
        let list = app.collectionViews.firstMatch
        list.swipeUp()
        list.swipeUp()
        XCTAssertFalse(quickSnap.isHittable)

        app.tabBars.buttons["tab-drop-zone"].tap()
        let back = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: quickSnap)
        XCTAssertEqual(XCTWaiter().wait(for: [back], timeout: 5), .completed)
    }

    func testEverythingFiledOffersQuickSnap() throws {
        launch(["-demoArea", "home", "-demoState", "filed", "-demoTab", "dropZone"], showing: "screen-drop-zone")
        let empty = screen("drop-zone-empty")
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        app.buttons["Quick Snap"].firstMatch.tap()
        XCTAssertTrue(screen("screen-capture").waitForExistence(timeout: 5))
    }
}
