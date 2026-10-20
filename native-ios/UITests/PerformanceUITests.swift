import XCTest

/// The real app on the 10 000-item inventory (`-demo YES -demoSeed large`, docs/PERFORMANCE.md):
/// it launches to Home, a search typed with the keyboard shows its results, and the 500-item
/// container opens. Timings are printed as `PERF |` lines. They include XCUITest's own
/// round trips (each query of the element tree takes tens of milliseconds), so they are an
/// upper bound on what she sees; the hosted `PerfHomeHostedTests` measure the app alone.
///
/// The cold-launch metric (`testColdLaunch`) relaunches the app five times, so it runs only when
/// asked: `TEST_RUNNER_INVENTORY_PERF=1` in the environment of `xcodebuild test`.
@MainActor
final class PerformanceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
    }

    private static let largeDemo = ["-demo", "YES", "-demoSeed", "large"]

    private func button(labelled prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func report(_ text: String) {
        print("PERF | UI: \(text)")
    }

    private static func milliseconds(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }

    func testTheLargeInventoryLaunchesSearchesAndOpensTheBigContainer() throws {
        app.launchArguments = Self.largeDemo
        let launched = Date()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["screen-home"].waitForExistence(timeout: 60))
        // The newest item of the large inventory heads Recently added.
        XCTAssertTrue(button(labelled: "Bike pump").waitForExistence(timeout: 60))
        report("launch (10 000 items written at boot) → Recently added shown: \(Self.milliseconds(since: launched)) ms")

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("screwdriver")
        let typed = Date()
        // The first rows (by name: "André’s screwdriver set", …).
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "screwdriver")).firstMatch.waitForExistence(timeout: 10))
        report("last key of `screwdriver` → its results shown: \(Self.milliseconds(since: typed)) ms")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "large-search"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Erase the word, then find the big container by its code.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "screwdriver".count))
        field.typeText("BIN-P4RT")
        let bin = button(labelled: "Parts bin")
        XCTAssertTrue(bin.waitForExistence(timeout: 10))
        let opened = Date()
        bin.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen-container"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.cells.element(boundBy: 3).waitForExistence(timeout: 15))
        report("tap Parts bin → its 500 items shown: \(Self.milliseconds(since: opened)) ms")
    }

    func testColdLaunch() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INVENTORY_PERF"] != nil, "measure-only: set TEST_RUNNER_INVENTORY_PERF=1")
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        app.launchArguments = Self.largeDemo
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true), XCTMemoryMetric(application: app)], options: options) {
            app.launch()
            _ = button(labelled: "Bike pump").waitForExistence(timeout: 60)
            app.terminate()
        }
    }
}
