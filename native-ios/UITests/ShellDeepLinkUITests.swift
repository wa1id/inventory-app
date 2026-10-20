import XCTest

/// `inventory://c/<token>` from outside the app (06 §3.6, DECISIONS U5): on the current tab when
/// warm, on Home with Home underneath from a cold start, and held back until onboarding is done.
@MainActor
final class ShellDeepLinkUITests: XCTestCase {
    private var app: XCUIApplication!
    private let link = URL(string: "inventory://c/0123456789abcdef0123456789abcdef")

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
    }

    private func screen(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Opens the link like the system Camera would, confirming iOS's "Open in Inventory?" prompt
    /// when it asks. `relaunch` goes through `XCUIApplication.open`, which starts the app afresh
    /// (a cold start); otherwise the system opens it in the running app.
    private func openLink(relaunch: Bool = false) throws {
        let link = try XCTUnwrap(link)
        if relaunch {
            app.open(link)
        } else {
            XCUIDevice.shared.system.open(link)
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 3) { open.tap() }
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAWarmLinkOpensTheLabelOnTheCurrentTab() throws {
        app.launchArguments = ["-demo", "YES"]
        app.launch()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 15))
        app.tabBars.buttons["tab-spaces"].tap()
        XCTAssertTrue(screen("screen-spaces").waitForExistence(timeout: 5))

        try openLink()

        XCTAssertTrue(screen("screen-label").waitForExistence(timeout: 10))
        attachScreenshot("deeplink-warm")
        print("tab states: \(app.tabBars.buttons.allElementsBoundByIndex.map { "\($0.identifier)=\($0.isSelected)" })")
        XCTAssertTrue(app.tabBars.buttons["tab-spaces"].isSelected)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(screen("screen-spaces").waitForExistence(timeout: 5))
    }

    func testALinkDuringOnboardingWaitsUntilOnboardingIsDone() throws {
        app.launchArguments = ["-demo", "YES", "-demoOnboarding", "YES"]
        app.launch()
        XCTAssertTrue(screen("screen-onboarding").waitForExistence(timeout: 15))

        try openLink()
        XCTAssertTrue(screen("screen-onboarding").waitForExistence(timeout: 5))
        XCTAssertFalse(screen("screen-label").exists)

        // Welcome's "Use this phone on its own" finishes onboarding (the gate flips by itself).
        app.buttons["onboarding-local"].tap()
        XCTAssertTrue(screen("screen-label").waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["tab-home"].isSelected)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 5))
    }

    func testAColdLinkLandsOnTheLabelWithHomeUnderneath() throws {
        app.launchArguments = ["-demo", "YES"]
        app.launch()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 15))
        app.terminate()

        try openLink(relaunch: true)

        // Opened by URL, the app may start without the demo arguments, on this simulator's own
        // (empty) inventory: then onboarding comes first and the link waits for it.
        let onboarding = app.buttons["onboarding-local"]
        if onboarding.waitForExistence(timeout: 5) { onboarding.tap() }
        XCTAssertTrue(screen("screen-label").waitForExistence(timeout: 15))
        attachScreenshot("deeplink-cold")
        XCTAssertTrue(app.tabBars.buttons["tab-home"].isSelected)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(screen("screen-home").waitForExistence(timeout: 5))
    }
}
