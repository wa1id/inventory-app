import XCTest

/// Xcode's accessibility audit over the shell's own chrome (08 §9): the tab items (the bottom bar
/// on an iPhone; the top bar and the sidebar on an iPad), the connection banner and the
/// removed-phone layer. Run it on both: `scripts/mac.sh uitest` and `DEVICE=ipad`. Screen content
/// under the chrome belongs to the screens' own audits; where it shows here, its exceptions say
/// so.
@MainActor
final class ShellAccessibilityUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app.terminate()
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

    /// `auditScreen` (UITests/Support), plus the one issue its exceptions cannot single out: an
    /// iPad's top tab bar and sidebar are stock UIKit, whose titles keep a fixed size, and XCTest
    /// resolves no element for them (no identifier, label or frame), so they are let through by
    /// that alone. On an iPhone the bottom tab bar raises nothing.
    private func audit(_ name: String, except exceptions: [AuditException]) throws {
        let isPad = app.shellIsPad
        try app.performAccessibilityAudit(for: .all) { issue in
            if isPad, issue.element == nil, issue.auditType == .dynamicType { return true }
            let identifier = issue.element?.identifier ?? ""
            let label = issue.element?.label ?? ""
            let covered = exceptions.contains { exception in
                exception.type == issue.auditType
                    && (exception.element == nil || exception.element == identifier || exception.element == label)
            }
            if !covered {
                print("[audit] \(name): \(issue.auditType.rawValue) \(issue.compactDescription) (id \"\(identifier)\", label \"\(label)\", frame \(issue.element?.frame ?? .zero))")
            }
            return covered
        }
    }

    /// The Scan tab: the camera's permission screen under the tab items, with no list. Once the
    /// simulator has granted the camera (an earlier test can leave it so), the screen shows the
    /// camera's failure panel instead, which the screens' own audits cover.
    func testTheTabItemsPassTheAudit() throws {
        launch(["-demoTab", "scan"])
        XCTAssertTrue(screen("screen-scan").waitForExistence(timeout: 15))
        sleep(2)
        try audit("tabs", except: Self.scanContent)
        guard app.shellIsPad else { return }
        // The sidebar, open in landscape.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.cells.matching(identifier: "tab-scan").firstMatch.waitForExistence(timeout: 5))
        sleep(2)
        try audit("sidebar", except: Self.scanContent)
    }

    /// The Scan screen's camera chrome under the tab items when the simulator's camera does not
    /// start: not the shell's.
    private static let scanContent = [
        AuditException(.contrast, element: ShellAuditCopy.cameraFailed,
                       because: "TRACK shared: Scan's camera panel (CameraPanel) when the simulator's camera does not start; the screens' audits own it"),
        AuditException(.contrast, element: ShellAuditCopy.typeACode,
                       because: "TRACK shared: the camera panel's secondary button over the camera; the screens' audits own it"),
        AuditException(.dynamicType, element: "camera-pill",
                       because: "TRACK shared: the camera's title pill (CameraChrome) keeps its size over the picture; the screens' audits own it"),
    ]

    func testTheRemovedPhoneLayerPassesTheAudit() throws {
        launch(["-demoHousehold", "revoked"])
        XCTAssertTrue(screen("revoked").waitForExistence(timeout: 15))
        sleep(1)
        try audit("revoked", except: [
            AuditException(.contrast, element: ShellAuditCopy.revokedBody,
                           because: "the stock secondary label colour (RN's muted body), which the audit finds nearly passing"),
        ])
    }

    /// Spaces of a household whose home server does not answer: the banner over the list's
    /// error state.
    func testTheConnectionBannerPassesTheAudit() throws {
        launch(["-demoHousehold", "offline", "-demoTab", "spaces"])
        let banner = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", ShellAuditCopy.reconnecting)).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 15))
        sleep(1)
        try audit("offline", except: [
            AuditException(.dynamicType, element: ShellAuditCopy.reconnecting,
                           because: "the banner is pinned above the content, so its text stops at RN's meta cap (maxScale 2.0 = AX1, 08 §6)"),
            AuditException(.hitRegion, element: ShellAuditCopy.tryAgain,
                           because: "TRACK shared: the banner's Try again is BannerView's small LoadingButton, an 18 pt tall hit area (as Home's notice's Not now)"),
            AuditException(.contrast, element: ShellAuditCopy.offlineErrorBody,
                           because: "the list's error state is a stock ContentUnavailableView, whose description uses the secondary label colour the audit finds nearly passing"),
        ])
    }
}

/// The copy these audits name, as the app shows it (strings.ts).
private enum ShellAuditCopy {
    static let reconnecting = "Reconnecting to the home server… What you see may be a few minutes old."
    static let tryAgain = "Try again"
    static let revokedBody = "It may have been removed on another phone. Join again to see the household inventory."
    static let offlineErrorBody = "Check the internet connection, then try again. Nothing on this phone was lost."
    static let cameraFailed = "The camera did not start. Close and try again, or type the code instead."
    static let typeACode = "Type a code instead"
}
