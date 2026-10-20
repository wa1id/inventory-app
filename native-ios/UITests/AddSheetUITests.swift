import XCTest

/// The Add sheet driven like a person (06 §10, 07 §3.1): open it from the Add tab and from a
/// container, type a name, choose where it goes, save with Undo, Save and add another, the
/// place step with Back, Cancel's question, the draft a swipe-down keeps, and the photo options
/// over a demo suggestion. The app runs in its DEBUG demo mode (sample inventory in memory,
/// nothing on the device touched; `-demoArea add` states from `AddDemo`).
@MainActor
final class AddSheetUITests: XCTestCase {
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

    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func openFromTheTab() {
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 15))
        app.tabBars.buttons["tab-add"].tap()
        XCTAssertTrue(screen("screen-add").waitForExistence(timeout: 5))
    }

    private var nameField: XCUIElement { app.textFields["item-name"] }

    /// Drags the sheet down by its navigation bar, the whole way, as a person closing it would.
    private func dragSheetDown(from bar: XCUIElement) {
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    /// Types into the name field once it has the keyboard (it takes focus on arrival).
    private func typeName(_ text: String) {
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        let focused = expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: nameField)
        if XCTWaiter().wait(for: [focused], timeout: 3) != .completed { nameField.tap() }
        nameField.typeText(text)
    }

    private func toastMessage() -> String? {
        let toast = screen("toast")
        guard toast.waitForExistence(timeout: 5) else { return nil }
        return toast.staticTexts.firstMatch.label
    }

    func testAddTabSavesAnItemInTheDropZoneWithUndo() throws {
        launch()
        openFromTheTab()
        XCTAssertTrue(app.buttons["item-where-drop-zone"].isSelected)
        typeName("Torch")
        attachScreenshot("typed")

        app.buttons["item-save"].tap()

        XCTAssertTrue(waitForAbsence(screen("screen-add")))
        XCTAssertEqual(toastMessage(), "Saved in the drop zone.")
        app.buttons["toast-action"].tap()
        let removed = expectation(for: NSPredicate(format: "label == %@", "Removed again."), evaluatedWith: screen("toast").staticTexts.firstMatch)
        XCTAssertEqual(XCTWaiter().wait(for: [removed], timeout: 5), .completed)
    }

    func testABlankNameAsksForOneAndSavesNothing() throws {
        launch()
        openFromTheTab()
        app.buttons["item-save"].tap()
        XCTAssertTrue(app.staticTexts["Give the item a name."].waitForExistence(timeout: 5))
        XCTAssertTrue(screen("screen-add").exists)
    }

    func testOpenedForAContainerSavesThereAndSaveAndAddAnotherStaysForTheNext() throws {
        launch(["-demoRoute", "add:Tool_chest"])
        XCTAssertTrue(screen("screen-add").waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars["Add to Tool chest"].waitForExistence(timeout: 5))
        let chest = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'item-where-' AND NOT (identifier IN {'item-where-drop-zone', 'item-where-more'})")).firstMatch
        XCTAssertTrue(chest.waitForExistence(timeout: 5))
        XCTAssertTrue(chest.isSelected)
        XCTAssertEqual(app.buttons["item-save"].label, "Save in Tool chest, Garage")

        typeName("Drill bits")
        app.buttons["item-save-and-add"].tap()

        XCTAssertTrue(screen("add-saved-next").waitForExistence(timeout: 5))
        XCTAssertEqual(nameField.value as? String ?? "", nameField.placeholderValue ?? "")
        XCTAssertTrue(chest.isSelected, "the place stays for the next one")
        attachScreenshot("saved-next")

        typeName("Hole saw")
        XCTAssertTrue(waitForAbsence(screen("add-saved-next")))
        app.buttons["item-save"].tap()
        XCTAssertTrue(waitForAbsence(screen("screen-add")))
        XCTAssertEqual(toastMessage(), "Saved in Tool chest (Garage).")
    }

    func testSomewhereElsePicksAPlaceAndBackKeepsTheChoice() throws {
        launch()
        openFromTheTab()
        app.buttons["item-where-more"].tap()

        XCTAssertTrue(app.navigationBars["Where does it go?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["place-drop-zone"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["place-drop-zone"].isSelected)
        attachScreenshot("place-step")
        // A swipe down in the place step never closes the whole sheet.
        dragSheetDown(from: app.navigationBars["Where does it go?"])
        XCTAssertTrue(screen("screen-add").exists)

        // The picker's own field: Home's search field ("Find anything") is under the sheet.
        let filter = app.searchFields.matching(NSPredicate(format: "placeholderValue == %@", "Container, space or code")).firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.tap()
        filter.typeText("bin4f")
        let redBin = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'move-to-'")).firstMatch
        XCTAssertTrue(redBin.waitForExistence(timeout: 5))
        redBin.tap()

        XCTAssertTrue(app.navigationBars["Add an item"].waitForExistence(timeout: 5))
        let picked = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'item-where-' AND label BEGINSWITH 'Red bin'")).firstMatch
        XCTAssertTrue(picked.waitForExistence(timeout: 5))
        XCTAssertTrue(picked.isSelected)
        XCTAssertEqual(app.buttons["item-save"].label, "Save in Red bin, Garage")

        // Back returns to the form without changing the place.
        app.buttons["item-where-more"].tap()
        XCTAssertTrue(app.buttons["add-back"].waitForExistence(timeout: 5))
        app.buttons["add-back"].tap()
        XCTAssertTrue(app.navigationBars["Add an item"].waitForExistence(timeout: 5))
        XCTAssertTrue(picked.isSelected)
    }

    func testCancelAsksBeforeDiscardingAndASwipeKeepsTheDraft() throws {
        launch()
        openFromTheTab()
        typeName("Torch")

        app.buttons["add-cancel"].tap()
        let alert = app.alerts["Discard this item?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Keep editing"].tap()
        XCTAssertTrue(waitForAbsence(alert))
        XCTAssertTrue(screen("screen-add").exists)

        // A swipe down keeps what was typed for the next plain open.
        dragSheetDown(from: app.navigationBars["Add an item"])
        XCTAssertTrue(waitForAbsence(screen("screen-add")))
        app.tabBars.buttons["tab-add"].tap()
        XCTAssertTrue(screen("add-draft").waitForExistence(timeout: 5))
        XCTAssertEqual(nameField.value as? String, "Torch")
        attachScreenshot("draft-restored")

        app.buttons["add-cancel"].tap()
        XCTAssertTrue(app.alerts["Discard this item?"].waitForExistence(timeout: 5))
        app.alerts["Discard this item?"].buttons["Discard"].tap()
        XCTAssertTrue(waitForAbsence(screen("screen-add")))
        app.tabBars.buttons["tab-add"].tap()
        XCTAssertTrue(screen("screen-add").waitForExistence(timeout: 5))
        XCTAssertFalse(screen("add-draft").exists)
    }

    func testClearingARestoredDraftStartsOver() throws {
        launch(["-demoArea", "add", "-demoState", "draft"])
        XCTAssertTrue(screen("add-draft").waitForExistence(timeout: 15))
        XCTAssertEqual(nameField.value as? String, "Wood screws")
        app.buttons["add-draft-clear"].tap()
        XCTAssertTrue(waitForAbsence(screen("add-draft")))
        XCTAssertTrue(app.buttons["item-where-drop-zone"].isSelected)
        XCTAssertNotEqual(nameField.value as? String, "Wood screws")
    }

    func testAPhotoSuggestionAndItsOptions() throws {
        launch(["-demoArea", "add", "-demoState", "offered"])
        XCTAssertTrue(screen("screen-add").waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Suggested from your photo"].waitForExistence(timeout: 10))
        XCTAssertEqual(nameField.value as? String, "Cordless drill")
        attachScreenshot("suggestion-offered")

        app.buttons["item-photo-options"].tap()
        let remove = app.buttons["Remove photo"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Retake"].exists)
        remove.tap()
        XCTAssertTrue(app.buttons["item-photo-take"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Suggested from your photo"].exists)
    }

    /// Photo options › Retake (RN app/item/new.tsx:407-416): the photo goes, then the camera opens
    /// over the sheet once the action sheet has gone; closed without a shot, no photo is left and
    /// the suggested name stays.
    func testRetakeDropsThePhotoAndOpensTheCamera() throws {
        launch(["-demoArea", "add", "-demoState", "offered"])
        XCTAssertTrue(app.staticTexts["Suggested from your photo"].waitForExistence(timeout: 15))

        app.buttons["item-photo-options"].tap()
        let retake = app.buttons["Retake"]
        XCTAssertTrue(retake.waitForExistence(timeout: 5))
        retake.tap()
        XCTAssertTrue(screen("screen-capture").waitForExistence(timeout: 5))
        attachScreenshot("retake-camera")

        app.buttons["capture-close"].tap()
        XCTAssertTrue(waitForAbsence(screen("screen-capture")))
        XCTAssertTrue(app.buttons["item-photo-take"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["item-photo-options"].exists)
        XCTAssertFalse(app.staticTexts["Suggested from your photo"].exists)
        XCTAssertEqual(nameField.value as? String, "Cordless drill")
    }

    func testAFailedSaveSaysSoAndKeepsTheTyping() throws {
        launch(["-demoArea", "add", "-demoState", "saveProblem"])
        XCTAssertTrue(screen("add-save-problem").waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["It was not saved. Try again."].exists)
        XCTAssertEqual(nameField.value as? String, "Paint brushes")
        XCTAssertTrue(app.buttons["item-save"].isEnabled)
        attachScreenshot("save-problem")
    }

    func testAStaleSuggestionOffersToUpdateTheOtherDetails() throws {
        launch(["-demoArea", "add", "-demoState", "stale"])
        let update = app.buttons["Update the other details"]
        XCTAssertTrue(update.waitForExistence(timeout: 15))
        update.tap()
        XCTAssertTrue(app.staticTexts["Details updated for “Angle grinder”"].waitForExistence(timeout: 10))
    }

    /// RN focused the name once, on arrival (app/item/new.tsx:290-310). Coming back from the
    /// camera must not bring the keyboard up again over the form (and the suggestion banner).
    func testTheNameTakesFocusOnArrivalOnlyOnce() throws {
        launch()
        openFromTheTab()
        let focused = expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: nameField)
        XCTAssertEqual(XCTWaiter().wait(for: [focused], timeout: 5), .completed, "focused on arrival")

        app.buttons["item-photo-take"].tap()
        XCTAssertTrue(screen("screen-capture").waitForExistence(timeout: 5))
        app.buttons["capture-close"].tap()
        XCTAssertTrue(waitForAbsence(screen("screen-capture")))
        XCTAssertTrue(screen("screen-add").exists)

        // Longer than the arrival delay: the keyboard stays down.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(nameField.value(forKey: "hasKeyboardFocus") as? Bool, false, "the name took focus again after the camera")
        XCTAssertEqual(app.keyboards.count, 0)
    }

    /// "More details" opens Category, Tags and Notes, and closes over them again (RN
    /// `toggleDetails`, app/item/new.tsx:364-371); a category saves with the item.
    func testMoreDetailsOpensAndClosesTheDetails() throws {
        launch()
        openFromTheTab()
        typeName("Wood screws")
        // The disclosure row's button carries RN's testID (its label text repeats it).
        let toggle = app.buttons["item-more-details"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["item-category"].exists)

        toggle.tap()
        let category = app.textFields["item-category"]
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        category.tap()
        category.typeText("Hardware")
        attachScreenshot("details-open")

        toggle.tap()
        XCTAssertTrue(waitForAbsence(category), "closed over what is typed")
        app.buttons["item-save"].tap()
        XCTAssertTrue(waitForAbsence(screen("screen-add")))
        XCTAssertEqual(toastMessage(), "Saved in the drop zone.")
    }

    func testSnapSeveralKeepsTheTypingForTheNextOpen() throws {
        launch()
        openFromTheTab()
        typeName("Torch")
        app.buttons["item-snap-several"].tap()
        XCTAssertTrue(screen("screen-capture").waitForExistence(timeout: 5))
        app.buttons["capture-close"].tap()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 5))
        app.tabBars.buttons["tab-add"].tap()
        XCTAssertTrue(screen("add-draft").waitForExistence(timeout: 5))
        XCTAssertEqual(nameField.value as? String, "Torch")
    }
}
