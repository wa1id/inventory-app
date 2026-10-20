import XCTest

/// The tab bar's Add slot, driven like a person (06 §4.3, DECISIONS U5): a tap presents the Add
/// sheet without switching tabs; a long press opens Quick Snap. The app runs in its DEBUG demo
/// mode (sample inventory in memory, nothing on the device touched).
@MainActor
final class ShellTabBarUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demo", "YES"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["screen-home"].waitForExistence(timeout: 15))
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
    }

    /// A tab item by RN's testID, or by its label when the identifier did not reach the button.
    private func tab(_ identifier: String, label: String) -> XCUIElement {
        let byIdentifier = app.tabBars.buttons[identifier]
        if byIdentifier.waitForExistence(timeout: 3) { return byIdentifier }
        return app.tabBars.buttons[label]
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

    func testTappingAddPresentsTheAddSheetWithoutSwitchingTabs() throws {
        let spaces = tab("tab-spaces", label: "Spaces")
        spaces.tap()
        XCTAssertTrue(screen("screen-spaces").waitForExistence(timeout: 5))

        tab("tab-add", label: "Add an item").tap()

        XCTAssertTrue(screen("screen-add").waitForExistence(timeout: 5))
        XCTAssertFalse(screen("screen-capture").exists)

        // Closing the sheet lands back on Spaces: Add never became the selected tab.
        app.buttons["item-cancel"].tap()
        XCTAssertTrue(screen("screen-spaces").waitForExistence(timeout: 5))
        XCTAssertFalse(screen("screen-add").exists)
        XCTAssertTrue(tab("tab-spaces", label: "Spaces").isSelected)
    }

    func testLongPressOnAddOpensQuickSnap() throws {
        let add = tab("tab-add", label: "Add an item")
        add.press(forDuration: 1.0)

        XCTAssertTrue(screen("screen-capture").waitForExistence(timeout: 5))
        // Only the camera: the tab's own selection on release must not open the Add sheet too.
        XCTAssertFalse(screen("screen-add").exists)

        app.buttons["capture-close"].tap()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 5))
        XCTAssertTrue(tab("tab-home", label: "Home").isSelected)
    }

    func testAHeldLongPressStillOpensOnlyQuickSnap() throws {
        tab("tab-add", label: "Add an item").press(forDuration: 2.5)
        XCTAssertTrue(screen("screen-capture").waitForExistence(timeout: 5))
        XCTAssertFalse(screen("screen-add").exists)
    }

    func testAddSheetOverTheTabsAndQuickSnapCoverLookRight() throws {
        tab("tab-add", label: "Add an item").tap()
        XCTAssertTrue(screen("screen-add").waitForExistence(timeout: 5))
        attachScreenshot("add-sheet")
        app.buttons["item-cancel"].tap()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 5))

        tab("tab-add", label: "Add an item").press(forDuration: 1.0)
        XCTAssertTrue(screen("screen-capture").waitForExistence(timeout: 5))
        attachScreenshot("quick-snap-cover")
    }

    func testTabItemsCarryRNsIdentifiersAndTheDropZoneBadgeLabel() throws {
        for identifier in ["tab-home", "tab-spaces", "tab-add", "tab-scan", "tab-drop-zone"] {
            XCTAssertTrue(app.tabBars.buttons[identifier].waitForExistence(timeout: 5), "missing \(identifier)")
        }
        print("tab labels: \(app.tabBars.buttons.allElementsBoundByIndex.map { "\($0.identifier)=\($0.label)|value=\(String(describing: $0.value))" })")
        XCTAssertEqual(app.tabBars.buttons["tab-add"].label, "Add an item")
        XCTAssertTrue(app.tabBars.buttons["tab-drop-zone"].label.hasPrefix("Drop zone, 4 waiting"))
    }
}
