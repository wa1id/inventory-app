import XCTest

/// Xcode's accessibility audit on the main states of every screen, at the default text size and
/// at the largest accessibility size (AX5). Each state opens through the DEBUG demo's launch
/// arguments (UI-KIT §6), so no test taps its way there.
///
/// Text size: each launch passes `-UIPreferredContentSizeCategoryName` (Large, or
/// `UICTContentSizeCategoryAccessibilityXXXL`), so a run never depends on the size the simulator
/// was last left at. At AX5 the Dynamic Type audit has no larger size to try, so it runs only at
/// the default size, in a pass of its own after the others (it changes the text size while it
/// runs).
///
/// Only the first screen of each state is audited: what has scrolled under the navigation bar,
/// the tab bar or a bottom bar is measured against their glass, not where it rests.
///
/// What every screen lets through is `AuditException.componentsDefaults(in:)`
/// (`Support/ComponentsAuditExceptions.swift`, each with its reason); a state's own exceptions
/// are written next to it, with their reason.
@MainActor
final class ScreensAuditUITests: XCTestCase {
    private var app: XCUIApplication!

    /// True prints every issue and fails nothing (a survey).
    private static let survey = false

    enum Size: String, CaseIterable {
        case standard = "UICTContentSizeCategoryL"
        case largest = "UICTContentSizeCategoryAccessibilityXXXL"

        var label: String { self == .standard ? "default" : "AX5" }
    }

    override func setUp() async throws {
        // Both sizes are audited even after one fails, so a run lists everything at once.
        continueAfterFailure = true
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
    }

    // MARK: - Harness

    private func audit(
        _ name: String,
        _ arguments: [String],
        ready: String,
        settle: TimeInterval = 1,
        except exceptions: [AuditException] = [],
        largest largestExceptions: [AuditException] = []
    ) throws {
        for size in Size.allCases {
            app.launchArguments = ["-demo", "YES"] + arguments + ["-UIPreferredContentSizeCategoryName", size.rawValue]
            app.launch()
            let label = "\(name)@\(size.label)"
            guard app.descendants(matching: .any)[ready].firstMatch.waitForExistence(timeout: 25) else {
                XCTFail("\(label): \(ready) never showed")
                attach("\(label)-not-ready")
                app.terminate()
                continue
            }
            Thread.sleep(forTimeInterval: settle)
            attach(label)
            let all = AuditException.componentsDefaults(in: app) + Self.everywhere + exceptions
                + (size == .largest ? largestExceptions : []) + behindKeyboard()
            let others: XCUIAccessibilityAuditType = [.contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .textClipped, .trait]
            try retryingSlowAudit { try app.auditScreen(label, types: others, except: all, reportOnly: Self.survey) }
            if size == .standard {
                try retryingSlowAudit { try app.auditScreen(label, types: .dynamicType, except: all, reportOnly: Self.survey) }
            }
            app.terminate()
        }
    }

    /// With the keyboard up (a screen that focuses its field on arrival, as RN's autoFocus did),
    /// the rows behind it: the audit measures them against the keys.
    private func behindKeyboard() -> [AuditException] {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists, keyboard.frame.height > 0 else { return [] }
        // The suggestion bar sits just above the frame XCUITest reports for the keyboard.
        let top = keyboard.frame.minY - 60
        return [XCUIAccessibilityAuditType.contrast, .textClipped].map { type in
            AuditException(type, Match(minY: top), because: """
                Behind the keyboard or its suggestion bar, which this state raises on arrival: \
                the audit measures the rows under them against the keys.
                """)
        } + [
            AuditException(.sufficientElementDescription, Match(element: "", minY: top), because: """
                The system keyboard's own unlabelled cells (its suggestion bar), not the app's.
                """),
        ]
    }

    /// XCTest gives up on an audit that takes too long ("Audit failed to complete in time", code
    /// -56) when the build Mac is busy; that one error is tried again, twice. Issues found are
    /// reported, never retried away.
    private func retryingSlowAudit(_ run: () throws -> Void) throws {
        var attempt = 0
        while true {
            do {
                try run()
                return
            } catch let error as NSError where error.domain == "com.apple.xcode.xctest.accessibilityAudit" && error.code == -56 && attempt < 2 {
                attempt += 1
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func area(_ area: String, _ state: String, route: String? = nil) -> [String] {
        ["-demoArea", area, "-demoState", state] + (route.map { ["-demoRoute", $0] } ?? [])
    }

    /// The Add sheet without the keyboard it raises on arrival, so the audit sees the form
    /// rather than rows behind the keys (whose contrast it would measure against them).
    private static func add(_ state: String, _ extra: [String] = []) -> [String] {
        extra + ["-demoKeyboardDown", "YES"] + area("add", state)
    }

    // MARK: - Exceptions

    private typealias Match = AuditException.Match
    private static let partly = "Dynamic Type font sizes are partially unsupported"

    /// In every state, on top of `componentsDefaults`.
    private static let everywhere: [AuditException] = [
        AuditException(.dynamicType, Match(description: partly, element: "add-cancel"), because: """
            The Add sheet's own Cancel is a stock toolbar button: the navigation bar caps its \
            items and shows the Large Content Viewer, as every system bar does.
            """),
        AuditException(.dynamicType, Match(description: partly, labelPrefix: "Reconnecting to the home server"), because: """
            The connection banner is pinned above the content and stops at AX1 (RN banner text \
            maxScale 2.0, 08 §6; UI-KIT §2 ConnectionBanner).
            """),
    ]

    /// The head of a space or container screen: its crumb and type line stop at AX1 (RN label
    /// and meta maxScale 2.0, 08 §6) and its QR entry at the button cap (1.6 → .xxxLarge), so
    /// the contents start on the first screen at AX5 (UI-KIT §6.8).
    private static func headCap(_ labels: [String]) -> [AuditException] {
        labels.map { label in
            AuditException(.dynamicType, Match(description: partly, element: label), because: """
                A detail screen's head stops at RN's caps for its roles (label and meta 2.0 → \
                AX1, button 1.6 → .xxxLarge; 08 §6), so the contents start on the first screen \
                at AX5.
                """)
        }
    }

    /// Text that at AX5 runs on past the bottom of the first screen, under the tab bar.
    private static func underTabBar(_ labelPrefix: String) -> AuditException {
        AuditException(.contrast, Match(description: "Contrast failed", labelPrefix: labelPrefix), because: """
            At AX5 this text runs on under the tab bar at the bottom of the first screen (its \
            frame ends past the window), where the audit measures it against the bar's glass \
            and scroll edge effect; it passes where it rests, at the default size.
            """)
    }

    /// A row that at AX5 runs on to the bottom edge of a sheet on the first screen.
    private static func atBottomEdge(_ labelPrefix: String) -> AuditException {
        AuditException(.contrast, Match(description: "Contrast failed", labelPrefix: labelPrefix), because: """
            At AX5 this row runs on to the bottom edge of the sheet on the first screen, under \
            the system's soft scroll edge effect there, where the audit measures it faded; it \
            passes where it rests, at the default size.
            """)
    }

    /// A row that at AX5 sits behind the screen's bottom bar on the first screen.
    private static func underBottomBar(_ label: String) -> AuditException {
        AuditException(.contrast, Match(description: "Contrast failed", element: label), because: """
            At AX5 this row sits behind the bottom bar on the first screen (the content scrolls \
            under the iOS 26 bar), where the audit measures it against the bar's glass and scroll \
            edge effect; it passes where it rests, at the default size.
            """)
    }

    /// A camera notice's words and buttons: white on the panel's dark tinted Liquid Glass.
    private static func cameraPanel(_ labelPrefixes: [String]) -> [AuditException] {
        labelPrefixes.map { prefix in
            AuditException(.contrast, Match(description: "Contrast failed", labelPrefix: prefix), because: """
                White text on a camera notice (CameraPanel: Liquid Glass tinted with RN's 62 % \
                camera chip over the picture). The audit's own screenshots of these states \
                measure 15–17:1 for the words and 9.7:1 on a button's fill; its sample of the \
                glass disagrees. At AX5 the words also scroll within 30 % of the window.
                """)
        }
    }

    /// A label whose copy ends in an ellipsis (an action that opens something).
    private static func endsInEllipsis(_ label: String) -> AuditException {
        AuditException(.textClipped, Match(element: label), because: """
            The copy itself ends in an ellipsis (RN's wording for an action that opens \
            something), which the audit takes for cut text; the screenshot of this state shows \
            the label whole.
            """)
    }

    /// A pinned notice longer than its share of the height at AX5.
    private static func pinnedNoticeScrolls(_ labelPrefix: String) -> AuditException {
        AuditException(.contrast, Match(description: "Contrast failed", labelPrefix: labelPrefix), because: """
            At AX5 a pinned notice takes at most 40 % of the height and scrolls within it \
            (`.pinnedNotice`, UI-KIT §2): its words run under that scroll view's bottom edge \
            effect, where the audit measures the faded edge. The same words pass at the default \
            size.
            """)
    }

    /// The camera's pinned chrome over the picture stops at AX1 (RN meta maxScale 2.0, 08 §6):
    /// the capture screen's "Into" pill.
    private static func cameraPill(_ labels: [String]) -> [AuditException] {
        labels.map { label in
            AuditException(.dynamicType, Match(description: partly, element: label), because: """
                The capture screen's Into pill is pinned over the picture and stops at AX1 (RN \
                meta maxScale 2.0, 08 §6), so two lines never cut the place's name.
                """)
        }
    }

    // MARK: - Home, Spaces, Drop zone

    func testHome() throws {
        try audit("home", [], ready: "home-settings", settle: 2, largest: [
            Self.underTabBar("This phone keeps its own inventory."),
        ])
    }

    func testHomeSearch() throws {
        try audit("homeSearch", Self.area("home", "search"), ready: "screen-home", settle: 3, except: [
            AuditException(.contrast, Match(description: "Contrast failed", element: "AA batteries"), because: """
                The matched word sits on the search highlight (HighlightedText on SearchMark): \
                black on light yellow, 16.6:1 in the AX5 screenshot of this state; the audit \
                sometimes measures the words against the highlight's edge.
                """),
        ])
    }

    func testHomeReconnecting() throws {
        try audit("homeReconnecting", Self.area("home", "reconnecting"), ready: "home-settings", settle: 6, largest: [
            Self.underTabBar("Your household’s things show here"),
        ])
    }

    func testSpaces() throws {
        try audit("spaces", ["-demoTab", "spaces"], ready: "spaces-create", settle: 2)
    }

    func testDropZone() throws {
        try audit("dropZone", ["-demoTab", "dropZone"], ready: "drop-zone-search", settle: 2)
    }

    // MARK: - Account

    func testSettings() throws {
        try audit("settings", ["-demoRoute", "settings"], ready: "settings-household")
    }

    func testSettingsBackupFailing() throws {
        try audit("settingsBackupFailing", Self.area("account", "backupFailing", route: "settings"), ready: "settings-household", settle: 3)
    }

    func testPrivacy() throws {
        try audit("privacy", ["-demoRoute", "privacy"], ready: "screen-privacy")
    }

    func testHouseholdJoin() throws {
        try audit("householdJoin", Self.area("account", "unpaired", route: "household"), ready: "join-submit", except: [
            AuditException(.contrast, Match(description: "Contrast failed", element: "Name for this phone"), because: """
                The name field's label is primary text on the white cell (the screenshot of this \
                state); the audit reported it as failed in one run of three, with nothing \
                drawn over it.
                """),
        ])
    }

    func testHouseholdPaired() throws {
        try audit("householdPaired", Self.area("account", "paired", route: "household"), ready: "household-connection", settle: 2)
    }

    func testBackupOff() throws {
        try audit("backupOff", Self.area("account", "backupOff", route: "backup"), ready: "backup-enable")
    }

    func testBackupReveal() throws {
        try audit("backupReveal", Self.area("account", "backupReveal", route: "backup"), ready: "backup-code", except: [
            AuditException(.dynamicType, Match(description: Self.partly, labelPattern: "[0-9A-Z\\n-]{20,}"), because: """
                The recovery code grows with the text but breaks only between its groups: one of \
                three fixed line layouts (`BackupCodeText`, a ViewThatFits), so a group is never \
                split across lines, which the audit reports as partial support.
                """),
            Self.endsInEllipsis("Share recovery code…"),
        ])
    }

    func testOnboarding() throws {
        try audit("onboarding", Self.area("account", "onboarding"), ready: "onboarding-join")
    }

    func testOnboardingJoin() throws {
        try audit("onboardingJoin", Self.area("account", "onboardingJoin"), ready: "join-submit")
    }

    // MARK: - Labels

    func testScanCamera() throws {
        try audit("scanCamera", Self.area("labels", "camera"), ready: "scan-type-code", largest: Self.cameraPanel([
            "Point the camera at the label on a box.", "Type a code instead",
        ]))
    }

    func testScanFailed() throws {
        try audit("scanFailed", Self.area("labels", "scanFailed"), ready: "scan-try-again", except: Self.cameraPanel([
            "Type a code instead",
        ]), largest: Self.cameraPanel([
            "The home server did not answer", "Check the internet connection",
        ]))
    }

    func testScanCodeList() throws {
        try audit("scanCodeList", Self.area("labels", "codeList"), ready: "scan-back-to-camera", settle: 2, except: [
            AuditException(.dynamicType, Match(description: Self.partly, element: "Back to the camera"), because: """
                "Back to the camera" is pinned above the list, outside its scroll view, and stops \
                at AX1 (RN banner and pinned text maxScale 2.0, 08 §6), as the connection banner.
                """),
        ], largest: [
            AuditException(.contrast, Match(description: "Contrast failed", element: "Back to the camera"), because: """
                Ink on the page (15:1), pinned right under the navigation bar: at AX5 the bar's \
                search field and scroll edge effect reach over it, and the audit measures it \
                against them.
                """),
        ])
    }

    func testLabelUnlinked() throws {
        try audit("labelUnlinked", ["-demoRoute", "label"], ready: "screen-label", settle: 2, largest: [
            Self.pinnedNoticeScrolls("This label is not linked to a container yet."),
        ])
    }

    func testQrLabel() throws {
        try audit("qrLabel", ["-demoRoute", "qrLabel:Tool_chest"], ready: "qr-card", largest: [
            Self.underTabBar("Print this and stick it on the container."),
        ])
    }

    func testStickerNotOurs() throws {
        try audit("stickerNotOurs", Self.area("labels", "stickerNotOurs"), ready: "link-close", settle: 4, largest: Self.cameraPanel([
            "That code was not made by this app.",
        ]))
    }

    // MARK: - Places

    func testSpace() throws {
        try audit("space", ["-demoTab", "spaces", "-demoRoute", "space:Garage"], ready: "containers-create", except: Self.headCap(["3 containers and 4 items"]) + [
            AuditException(.contrast, Match(description: "Contrast failed", element: "3 containers and 4 items"), because: """
                The counts are reported with their whole row's frame (x 16, 370 × 88 pt: the \
                space tile included), so the audit sometimes samples the tile's tint; the words \
                are the stock secondary colour on the page beside the tile (screenshots of this \
                state at both sizes).
                """),
        ])
    }

    func testContainer() throws {
        try audit("container", ["-demoRoute", "container:Tool_chest"], ready: "items-add", except: Self.headCap(["Garage", "Cabinet · 2 items", "QR label"]))
    }

    func testSpaceNew() throws {
        try audit("spaceNew", ["-demoRoute", "spaceNew"], ready: "space-create-custom", except: [
            AuditException(.contrast, Match(description: "Contrast failed", element: "Quick add"), because: """
                The first heading sits right under the sheet's navigation bar, inside the bar's \
                scroll edge effect, where the audit measures it; it is primary text on the page \
                (the iPhone SE screenshot of this sheet shows it black on the grouped background).
                """),
        ], largest: [Self.underBottomBar("Your own")])
    }

    func testContainerEdit() throws {
        try audit("containerEdit", ["-demoRoute", "containerEdit:Tool_chest"], ready: "container-save")
    }

    // MARK: - Item

    func testItem() throws {
        try audit("item", ["-demoRoute", "item:Cordless_drill"], ready: "item-title", except: [
            AuditException(.textClipped, Match(element: "Edit details"), because: """
                Shown whole (the screenshot of this state); on the first screen it sits just \
                above the tab bar, inside the bar's scroll edge effect, where the audit reports \
                it as clipped.
                """),
        ])
    }

    func testItemEdit() throws {
        try audit("itemEdit", ["-demoRoute", "itemEdit:Cordless_drill"], ready: "item-save-changes")
    }

    func testMove() throws {
        try audit("move", ["-demoRoute", "move:Cordless_drill"], ready: "screen-move", settle: 2)
    }

    func testPhoto() throws {
        try audit("photo", ["-demoRoute", "photo:Cordless_drill"], ready: "photo-image")
    }

    // MARK: - Add

    func testAdd() throws {
        try audit("add", Self.add("empty"), ready: "item-save", settle: 1.5, except: [Self.endsInEllipsis("Snap several at once…")])
    }

    func testAddSaveProblemOffline() throws {
        try audit(
            "addOffline",
            Self.add("saveProblem", ["-demoHousehold", "offline"]),
            ready: "add-save-problem",
            settle: 3,
            except: ["The home server did not answer", "It was not saved."].map { prefix in
                AuditException(.dynamicType, Match(description: Self.partly, labelPrefix: prefix), because: """
                    The save notice is pinned above the form and stops at AX1, as the connection \
                    banner above it (RN banner text maxScale 2.0, 08 §6), so the form keeps room.
                    """)
            },
            largest: [Self.pinnedNoticeScrolls("It was not saved.")]
        )
    }

    func testAddPlace() throws {
        try audit("addPlace", Self.add("place"), ready: "add-back", settle: 2, largest: [
            Self.atBottomEdge("New container in Attic…"),
        ])
    }

    // MARK: - Capture

    func testCapture() throws {
        try audit("capture", Self.area("capture", "single"), ready: "capture-shutter", settle: 1.5, except: Self.cameraPill(["Garage › Tool chest"]))
    }

    func testCaptureNotices() throws {
        try audit(
            "captureNotices",
            Self.area("capture", "notices"),
            ready: "capture-dropped",
            settle: 3,
            except: Self.cameraPanel(["The camera did not take the photo.", "1 photo could not be saved."])
                + Self.cameraPill(["Into the drop zone"])
        )
    }

    func testReview() throws {
        // The rows land a few seconds after the screen (the demo saves the set first); the audit
        // waits for the last named one, then for its fade in.
        try audit("review", Self.area("capture", "reviewNamed"), ready: "Wood glue", settle: 2, largest: [
            Self.underBottomBar("Tape measure"),
        ])
    }
}
