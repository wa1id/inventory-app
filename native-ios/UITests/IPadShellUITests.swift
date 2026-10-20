import XCTest

/// The shell on an iPad (DECISIONS U4, U5): Add in the top tab bar and in the sidebar (a tap opens
/// the Add sheet and keeps the tab, a long press opens Quick Snap), the badge's label, the Home
/// Screen quick action, and every main screen in portrait and landscape. Runs only on an iPad
/// simulator (`DEVICE=ipad scripts/mac.sh uitest`); deep links on an iPad are
/// `ShellDeepLinkUITests` run there.
@MainActor
final class IPadShellUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ arguments: [String] = []) {
        app.launchArguments = ["-demo", "YES"] + arguments
        app.launch()
    }

    private func screen(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The top bar's button that shows or hides the sidebar.
    private var sidebarToggle: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier ==[c] 'ToggleSidebar'")).firstMatch
    }

    /// A sidebar row by RN's testID.
    private func sidebarRow(_ identifier: String) -> XCUIElement {
        app.cells.matching(identifier: identifier).firstMatch
    }

    private func showSidebar() {
        XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 5))
        sidebarToggle.tap()
        XCTAssertTrue(sidebarRow("tab-add").waitForExistence(timeout: 5))
        // The rows settle, and the badge gets its tape (within a second of a rebuild).
        sleep(2)
    }

    // MARK: The top tab bar

    func testTappingAddInTheTopBarOpensTheAddSheetAndKeepsTheTab() throws {
        launch()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 15))
        XCTAssertEqual(app.tabBars.count, 0, "an iPad shows the top tab bar, not the bottom one")
        app.shellTab("tab-spaces").tap()
        XCTAssertTrue(screen("screen-spaces").waitForExistence(timeout: 5))

        app.shellTab("tab-add").tap()

        XCTAssertTrue(screen("screen-add").waitForExistence(timeout: 5))
        XCTAssertFalse(screen("screen-capture").exists)
        attachScreenshot("ipad-add-from-top-bar")
        app.buttons["add-cancel"].tap()
        XCTAssertTrue(shellWaitForAbsence(screen("screen-add")))
        XCTAssertTrue(screen("screen-spaces").exists)
        XCTAssertTrue(app.shellTab("tab-spaces").isSelected)
        XCTAssertFalse(app.shellTab("tab-add").isSelected)
    }

    func testLongPressOnAddInTheTopBarOpensQuickSnapOnly() throws {
        launch()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 15))

        app.shellTab("tab-add").press(forDuration: 1.2)

        XCTAssertTrue(screen("screen-capture").waitForExistence(timeout: 5))
        XCTAssertFalse(screen("screen-add").exists)
        app.buttons["capture-close"].tap()
        XCTAssertTrue(shellWaitForAbsence(screen("screen-capture")))
        XCTAssertTrue(app.shellTab("tab-home").isSelected)
    }

    func testTheTopBarReadsTheBadgeCountOnce() throws {
        launch()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 15))
        XCTAssertEqual(app.shellTab("tab-add").label, "Add an item")
        XCTAssertEqual(app.shellTab("tab-drop-zone").label, "Drop zone, 4 waiting")
        XCTAssertEqual(app.shellTab("tab-home").identifier, "tab-home")
    }

    // MARK: The sidebar

    func testTheSidebarsAddRowOpensTheAddSheetAndAHoldOpensQuickSnap() throws {
        launch()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 15))
        showSidebar()
        XCTAssertEqual(sidebarRow("tab-drop-zone").label, "Drop zone, 4 waiting")
        attachScreenshot("ipad-sidebar")

        sidebarRow("tab-add").tap()
        XCTAssertTrue(screen("screen-add").waitForExistence(timeout: 5))
        XCTAssertFalse(screen("screen-capture").exists)
        app.buttons["add-cancel"].tap()
        XCTAssertTrue(shellWaitForAbsence(screen("screen-add")))
        XCTAssertTrue(screen("screen-home").exists)

        // The sidebar may have closed over Home; the long press works on its row the same way.
        if !sidebarRow("tab-add").isHittable { showSidebar() }
        sidebarRow("tab-add").press(forDuration: 1.2)
        XCTAssertTrue(screen("screen-capture").waitForExistence(timeout: 5))
        XCTAssertFalse(screen("screen-add").exists)
        app.buttons["capture-close"].tap()
        XCTAssertTrue(shellWaitForAbsence(screen("screen-capture")))
        XCTAssertTrue(screen("screen-home").exists)
    }

    func testTheSidebarInLandscapeSwitchesTabsAndAddStillPresents() throws {
        launch()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 15))
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        // Landscape shows the sidebar by default.
        if !sidebarRow("tab-spaces").exists { showSidebar() }
        sidebarRow("tab-spaces").tap()
        XCTAssertTrue(screen("screen-spaces").waitForExistence(timeout: 5))
        sidebarRow("tab-add").tap()
        XCTAssertTrue(screen("screen-add").waitForExistence(timeout: 5))
        attachScreenshot("ipad-landscape-add")
        app.buttons["add-cancel"].tap()
        XCTAssertTrue(shellWaitForAbsence(screen("screen-add")))
        XCTAssertTrue(screen("screen-spaces").exists)
        XCTAssertTrue(sidebarRow("tab-spaces").isSelected)
    }

    // MARK: Quick action

    func testTheHomeScreenQuickActionOpensQuickSnap() throws {
        launch()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 15))
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = springboard.icons["Inventory"]
        guard icon.waitForExistence(timeout: 5) else {
            throw XCTSkip("SpringBoard shows no Inventory icon on this simulator")
        }
        sleep(2)
        // The icon on a page that shows, or the Dock's recent app (an iPad keeps the app just
        // left there); a newly installed app may also sit on a later page, or only in Spotlight.
        let matches = springboard.icons.matching(NSPredicate(format: "label == 'Inventory' OR identifier == 'Inventory'"))
        func hittableIcon() -> XCUIElement? { matches.allElementsBoundByIndex.first { $0.isHittable } }
        var pages = 0
        while hittableIcon() == nil, pages < 5 {
            springboard.swipeLeft()
            sleep(1)
            pages += 1
        }
        var target = hittableIcon() ?? icon
        if !target.isHittable {
            springboard.swipeDown()
            let search = springboard.searchFields.firstMatch
            if search.waitForExistence(timeout: 3) {
                search.typeText("Inventory")
                let hit = springboard.icons.matching(NSPredicate(format: "label == 'Inventory'")).allElementsBoundByIndex.first { $0.isHittable }
                if let hit { target = hit }
            }
        }
        guard target.isHittable else {
            throw XCTSkip("The Inventory icon is on no Home Screen page or Spotlight result this test can reach")
        }
        target.press(forDuration: 1.5)
        let action = springboard.buttons["Quick Snap"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()
        XCTAssertTrue(screen("screen-capture").waitForExistence(timeout: 10))
        attachScreenshot("ipad-quick-action")
    }

    // MARK: Every screen, both orientations

    /// Every main screen, in portrait then turned to landscape (and back); the toast and the
    /// connection banner too.
    func testEveryScreenInBothOrientations() throws {
        let states: [(name: String, arguments: [String], screen: String)] = [
            ("home", [], "screen-home"),
            ("spaces", ["-demoTab", "spaces"], "screen-spaces"),
            ("scan", ["-demoTab", "scan"], "screen-scan"),
            ("drop-zone", ["-demoTab", "dropZone"], "screen-drop-zone"),
            ("settings", ["-demoRoute", "settings"], "screen-settings"),
            ("space", ["-demoTab", "spaces", "-demoRoute", "space:Garage"], "screen-space"),
            ("container", ["-demoRoute", "container:Tool_chest"], "screen-container"),
            ("item", ["-demoRoute", "item:Cordless_drill"], "screen-item"),
            ("add", ["-demoRoute", "add"], "screen-add"),
            ("move", ["-demoRoute", "move:Cordless_drill"], "screen-move"),
            ("item-edit", ["-demoRoute", "item:Cordless_drill>itemEdit:Cordless_drill"], "screen-item-edit"),
            ("space-new", ["-demoRoute", "spaceNew"], "screen-space-new"),
            ("capture", ["-demoRoute", "quickSnap"], "screen-capture"),
            ("photo", ["-demoRoute", "item:Cordless_drill>photo:Cordless_drill"], "screen-photo"),
            ("toast", ["-demoToast", "action"], "toast"),
            ("offline", ["-demoHousehold", "offline"], "text:Reconnecting to the home server"),
        ]
        for state in states {
            launch(state.arguments)
            // "text:…": the element whose label starts so (the banner has no identifier of its own).
            let element = state.screen.hasPrefix("text:")
                ? app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", String(state.screen.dropFirst(5)))).firstMatch
                : screen(state.screen)
            XCTAssertTrue(element.waitForExistence(timeout: 20), "\(state.name) did not show")
            sleep(2)
            attachScreenshot("ipad-\(state.name)-portrait")
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(2)
            XCTAssertTrue(element.exists, "\(state.name) went away on rotating")
            attachScreenshot("ipad-\(state.name)-landscape")
            XCUIDevice.shared.orientation = .portrait
            sleep(1)
            XCTAssertTrue(element.exists, "\(state.name) went away on rotating back")
            app.terminate()
        }
    }
}
