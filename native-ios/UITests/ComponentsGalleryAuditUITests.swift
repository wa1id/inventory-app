import XCTest

/// Xcode's accessibility audit over every page of the three DEBUG galleries (`-gallery
/// components|media|foundation -galleryPage N`): the shared components, the media views and the
/// place picker host, at the default text size and at the largest (AX5). Long pages are audited
/// again for Dynamic Type one section at a time, alone at the top (`-gallerySection`), since the
/// audit cannot follow text that growing text pushes off the screen (scrolling a section to the
/// top does not help: the sections above it grow back into view).
///
/// The exceptions every component needs are `AuditException.componentsDefaults` (with their
/// reasons); a page's own are listed with it below.
@MainActor
final class ComponentsGalleryAuditUITests: XCTestCase {
    private var app: XCUIApplication!

    /// The largest accessibility size, set for this launch only (the simulator keeps its own).
    private static let largest = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    /// At AX5 the Dynamic Type audit has no larger size to try, and the launch argument pins it.
    private static let notDynamicType: XCUIAccessibilityAuditType = [.contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .textClipped, .trait]

    override func setUp() async throws {
        // Every page is audited even after one fails, so a run lists everything at once.
        continueAfterFailure = true
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
    }

    private func audit(
        _ name: String,
        _ arguments: [String],
        largest: Bool = false,
        types: XCUIAccessibilityAuditType? = nil,
        except pageExceptions: [AuditException] = []
    ) throws {
        app.launchArguments = arguments + (largest ? Self.largest : [])
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), name)
        // The gallery's reads (the place picker's lists) and the skeleton's wait settle.
        sleep(2)
        let exceptions = AuditException.componentsDefaults(in: app) + pageExceptions
        let wanted = types ?? (largest ? Self.notDynamicType : .all)
        let label = largest ? "\(name)-ax5" : name
        // The Dynamic Type audit changes the text size while it runs, so it has a pass of its
        // own, after the others have measured the page as it settled.
        let others = wanted.subtracting(.dynamicType)
        if !others.isEmpty {
            try app.auditScreen(label, types: others, except: exceptions)
        }
        if wanted.contains(.dynamicType) {
            try app.auditScreen(label, types: .dynamicType, except: exceptions)
        }
    }

    private func gallery(_ name: String, page: Int, _ extra: [String] = []) -> [String] {
        ["-gallery", name, "-galleryPage", "\(page)"] + extra
    }

    // MARK: - Page exceptions

    /// The list dims while a pick saves.
    private static let busyPicker = AuditException(.contrast, AuditException.Match(description: "Contrast failed"), because: """
        While a pick saves the picker's list dims to 60 % and takes no touches (RN PlacePicker, \
        07 §4.1): inactive, and for a moment; the busy row's spinner and the pinned notice stay \
        undimmed.
        """)

    /// The keyboard is up on arrival.
    private static let keyboardBar = AuditException(.sufficientElementDescription, AuditException.Match(description: "Element has no description", elementType: .other), because: """
        The page focuses its field on arrival (RN autoFocus in the open-by-code picker): the \
        unlabelled cells are the system keyboard's suggestion bar.
        """)

    // MARK: - Components gallery

    private static let emojiLine = """
        The tokens page's plain emoji line, there to tell a simulator without colour emoji (it \
        draws them as boxes taller than the line, at a fixed size) from a tile bug.
        """

    /// The sections of the long component pages, by page; each is audited alone.
    private static let componentSections: [Int: [String]] = [
        0: ["Tape", "Mark", "Tiles and pips", "Highlight", "Glyphs"],
        1: ["Chip", "Stepper"],
        2: ["File", "Delete", "None"],
        3: ["Spaces", "Containers", "Search", "Location"],
        5: ["Stepper", "Saved", "Chip"],
        6: ["Banner", "Suggestion"],
        7: ["Skeleton", "Buttons", "Status pill"],
        9: ["Text fields", "Code", "Settings"],
        10: ["Chips", "Segmented", "Choice", "Emoji", "Swatch", "Type"],
        16: ["Placeholder", "Photo", "Row"],
    ]

    private func componentExceptions(page: Int, largest: Bool) -> [AuditException] {
        switch page {
        case 0:
            [
                AuditException(.textClipped, AuditException.Match(labelPrefix: "Emoji:"), because: Self.emojiLine),
                AuditException(.dynamicType, AuditException.Match(labelPrefix: "Emoji:"), because: Self.emojiLine),
            ]
        case 7:
            ["3 photos taken", "Into Tool chest, Garage"].map { label in
                AuditException(.dynamicType, AuditException.Match(description: "Dynamic Type font sizes are partially unsupported", element: label), because: """
                    The camera's status pill (the gallery's sample over a gradient) is pinned over \
                    the picture and stops at AX1 (RN meta maxScale 2.0, 08 §6).
                    """)
            }
        case 12:
            [Self.busyPicker]
        case 15:
            [
                AuditException(.contrast, AuditException.Match(description: "Contrast failed"), because: """
                    The page focuses Category on arrival to show its suggestion chips: the \
                    keyboard rises (on a fresh simulator with its first-use tip over it) and the \
                    fields move and sit under it while the audit measures. The same fields pass on \
                    the inputs page (9).
                    """),
            ]
        default:
            []
        }
    }

    func testComponentsGalleryAtTheDefaultSize() throws {
        for page in 0...17 {
            // A long page's Dynamic Type check is done section by section below.
            let sections = Self.componentSections[page] ?? []
            try audit(
                "components\(page)",
                gallery("components", page: page),
                types: sections.isEmpty ? .all : Self.notDynamicType,
                except: componentExceptions(page: page, largest: false)
            )
            for section in sections {
                try audit("components\(page)-\(section)", gallery("components", page: page, ["-gallerySection", section]), types: .dynamicType, except: componentExceptions(page: page, largest: false))
            }
        }
        for state in ["loading", "failure", "nomatch"] {
            try audit("components13-\(state)", gallery("components", page: 13, ["-galleryState", state]))
        }
        try audit("components13-open", gallery("components", page: 13, ["-galleryState", "open"]), except: [Self.keyboardBar])
    }

    func testComponentsGalleryAtTheLargestSize() throws {
        for page in 0...17 {
            try audit("components\(page)", gallery("components", page: page), largest: true, except: componentExceptions(page: page, largest: true))
        }
        for state in ["loading", "failure", "nomatch"] {
            try audit("components13-\(state)", gallery("components", page: 13, ["-galleryState", state]), largest: true)
        }
        try audit("components13-open", gallery("components", page: 13, ["-galleryState", "open"]), largest: true, except: [Self.keyboardBar])
    }

    // MARK: - Media gallery

    private func mediaExceptions(page: Int, largest: Bool = false) -> [AuditException] {
        switch page {
        case 5 where largest, 6 where largest, 7 where largest:
            [
                "Point the camera at the label on a box.", "Opening that label…",
                "That code was not made by this app.", "Not one of our labels", "Scan again",
            ].map { label in
                AuditException(.contrast, AuditException.Match(description: "Contrast failed", element: label), because: """
                    At AX5 a camera notice's words scroll inside it (at most 30 % of the window, \
                    CameraPanel.wordsHeightShare): the audit measures a text's whole frame, \
                    including the part scrolled out of the panel over the gallery's stand-in scene \
                    (white at the top), and the panel's soft scroll edge beside its buttons. At \
                    the default size the same notices and buttons pass, on RN's darker chip glass.
                    """)
            }
        case 10:
            [
                AuditException(.dynamicType, AuditException.Match(description: "Dynamic Type font sizes are partially unsupported", element: "Into the drop zone"), because: """
                    The camera's title pill is pinned over the picture and stops at AX1 (RN meta \
                    maxScale 2.0, 08 §6).
                    """),
            ]
        case 11:
            [
                AuditException(.contrast, AuditException.Match(description: "Contrast failed"), because: """
                    While a library photo is stored the permission screen's buttons pause, dimmed \
                    by the stock styles (05 §4.8); WCAG exempts inactive controls, and "Saving your \
                    photo…" says why.
                    """),
            ]
        default:
            []
        }
    }

    func testMediaGalleryAtTheDefaultSize() throws {
        for page in 0...11 {
            try audit("media\(page)", gallery("media", page: page), except: mediaExceptions(page: page))
        }
    }

    func testMediaGalleryAtTheLargestSize() throws {
        for page in 0...11 {
            try audit("media\(page)", gallery("media", page: page), largest: true, except: mediaExceptions(page: page, largest: true))
        }
    }

    // MARK: - Foundation gallery (PlacePickerHost)

    private func foundationExceptions(page: Int) -> [AuditException] {
        switch page {
        case 4: [Self.keyboardBar]
        case 5: [Self.busyPicker]
        default: []
        }
    }

    func testFoundationGalleryAtTheDefaultSize() throws {
        for page in 0...7 {
            try audit("foundation\(page)", gallery("foundation", page: page), except: foundationExceptions(page: page))
        }
    }

    func testFoundationGalleryAtTheLargestSize() throws {
        for page in 0...7 {
            try audit("foundation\(page)", gallery("foundation", page: page), largest: true, except: foundationExceptions(page: page))
        }
    }
}
