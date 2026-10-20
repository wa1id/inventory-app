import XCTest

/// What VoiceOver gets on the screens-a screens beyond the audit (06 §17, 08 §9): RN's testIDs
/// kept as identifiers, rows and controls that read as one element, and the sticker notice at
/// AX5 (the join form above the keyboard is `ComponentsBottomBarUITests`). The app runs in its
/// DEBUG demo mode.
@MainActor
final class ScreensAAccessibilityUITests: XCTestCase {
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
        app.launchArguments = ["-demo", "YES"] + arguments + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    // MARK: - RN testIDs

    func testHomesListAndTheScanCameraKeepTheirRNIdentifiers() throws {
        launch([])
        XCTAssertTrue(element("screen-home").waitForExistence(timeout: 15))
        XCTAssertTrue(app.collectionViews["home-list"].waitForExistence(timeout: 5))
        // The list's own controls keep theirs inside it.
        XCTAssertTrue(element("drop-zone-card").exists)

        app.terminate()
        launch(["-demoArea", "labels", "-demoState", "camera"])
        XCTAssertTrue(element("screen-scan").waitForExistence(timeout: 15))
        XCTAssertTrue(element("scan-camera").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["scan-torch"].exists)
        XCTAssertTrue(app.buttons["scan-type-code"].exists)
    }

    // MARK: - Settings

    func testTechnicalDetailsIsOneLabelledButtonThatOpensOneFactPerStop() throws {
        launch(["-demoRoute", "settings"])
        XCTAssertTrue(element("settings-household").waitForExistence(timeout: 15))
        let row = element("settings-technical")
        for _ in 0..<4 where !row.exists || !row.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(row.exists)
        // The group's own button reads the label (RN: one button). The stock group still draws
        // its chevron as an unlabelled child of that button in the hierarchy.
        XCTAssertEqual(row.elementType, .button)
        XCTAssertEqual(row.label, "Technical details")
        let named = NSPredicate(format: "label == 'Technical details'")
        XCTAssertEqual(app.buttons.matching(named).count, 1, app.debugDescription)

        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["Database schema, v7"].waitForExistence(timeout: 5))
    }

    // MARK: - Backup and Household

    func testTheRecoveryCodeIsSpeltAndAPhoneReadsAsOneStop() throws {
        launch(["-demoArea", "account", "-demoState", "backupReveal", "-demoRoute", "backup"])
        let code = element("backup-code")
        XCTAssertTrue(code.waitForExistence(timeout: 20))
        // RN spellCode: letter by letter, a pause between groups ("8 9 1 4 4, G J 2 8 9, …").
        XCTAssertTrue(code.label.hasPrefix("8 9 1 4 4, G J 2 8 9"), code.label)

        app.terminate()
        launch(["-demoArea", "account", "-demoState", "paired", "-demoRoute", "household"])
        let phone = element("device-demo-anna")
        XCTAssertTrue(phone.waitForExistence(timeout: 20))
        // RN phoneA11y: the name and when it was last used, one element; Remove… its own stop.
        XCTAssertTrue(phone.label.hasPrefix("Anna’s iPhone"), phone.label)
        XCTAssertTrue(phone.label.contains("3 days ago"), phone.label)
        XCTAssertEqual(app.buttons["device-remove-demo-anna"].label, "Remove Anna’s iPhone")
    }

    // MARK: - The sticker camera at the largest text size

    func testTheStickerNoticeStaysUnderTheTitleAtTheLargestSize() throws {
        app.launchArguments = ["-demo", "YES", "-demoArea", "labels", "-demoState", "stickerLocked",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let title = element("camera-pill")
        let heading = app.staticTexts["The drop zone cannot be changed"]
        XCTAssertTrue(heading.waitForExistence(timeout: 20))
        XCTAssertTrue(title.exists)
        // The title takes two lines at AX5; the notice starts below it, never over it.
        XCTAssertGreaterThanOrEqual(heading.frame.minY, title.frame.maxY)
    }
}
