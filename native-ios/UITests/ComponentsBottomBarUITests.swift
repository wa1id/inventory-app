import XCTest

/// The shell's bottom bar with the keyboard up (RN `BottomBar`, 09 §7.8): the field being typed
/// in stays above the bar, which rises with the keyboard, at the default size and the largest.
/// Household's join form is the screen where the bar covered the name field.
@MainActor
final class ComponentsBottomBarUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
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

    private func checkNameFieldClearsTheBar(contentSize: String?) throws {
        var arguments = ["-demo", "YES", "-demoArea", "account", "-demoState", "unpaired", "-demoRoute", "household"]
        if let contentSize { arguments += ["-UIPreferredContentSizeCategoryName", contentSize] }
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(element("join-submit").waitForExistence(timeout: 15))
        // At the largest sizes the field is further down the form than the screen shows (and a
        // list builds rows only as they come into view).
        let name = element("join-name")
        for _ in 0..<8 where !(name.exists && name.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(name.isHittable)
        name.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // The keyboard and the scroll that brings the field into view settle.
        sleep(2)
        let join = element("join-submit")
        XCTAssertTrue(join.exists)
        let keyboard = app.keyboards.firstMatch.frame
        attachScreenshot("join-name-focused-\(contentSize ?? "default")")
        print("[bar] \(contentSize ?? "default"): field \(name.frame), join \(join.frame), keyboard \(keyboard)")
        XCTAssertLessThanOrEqual(join.frame.maxY, keyboard.minY + 1, "the bar sits above the keyboard")
        XCTAssertLessThanOrEqual(name.frame.maxY, join.frame.minY + 1, "the focused field is not under the bar: field \(name.frame), bar button \(join.frame)")
        XCTAssertGreaterThan(name.frame.maxY, 0)
    }

    func testFocusedFieldStaysAboveTheBarAtTheDefaultSize() throws {
        try checkNameFieldClearsTheBar(contentSize: nil)
    }

    func testFocusedFieldStaysAboveTheBarAtTheLargestSize() throws {
        try checkNameFieldClearsTheBar(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }
}
