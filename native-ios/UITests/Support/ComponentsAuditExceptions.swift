import XCTest

/// The accessibility-audit exceptions the shared components need wherever they are drawn, each
/// with its reason (UI-KIT §4). Screens pass `AuditException.componentsDefaults(in: app)` to
/// `auditScreen(_:types:except:)` and add their own exceptions next to their test.
///
/// Every exception is narrowed as far as the audit allows: by the issue's description (so a
/// "Contrast failed" is never let through by a "nearly passed" reason), by the element's type or
/// label, or by where the element starts on the screen.
extension AuditException {
    /// The window's height, for the exceptions that depend on where an element starts.
    @MainActor
    static func componentsWindowHeight(_ app: XCUIApplication) -> CGFloat {
        let height = app.windows.firstMatch.frame.height
        return height > 0 ? height : 874
    }

    @MainActor
    static func componentsDefaults(in app: XCUIApplication) -> [AuditException] {
        componentsDefaults(windowHeight: componentsWindowHeight(app))
    }

    static func componentsDefaults(windowHeight: CGFloat) -> [AuditException] {
        [
            // Contrast.
            AuditException(.contrast, Match(description: "Contrast nearly passed"), because: """
                Stock secondary label and section-header colours (`.secondary`, the List header \
                style) measure just under 4.5:1 by Apple's own design; every custom colour passes \
                (ComponentsContrastTests).
                """),
            AuditException(.contrast, Match(description: "Contrast failed", minY: windowHeight - 150), because: """
                iOS 26 fades what scrolls under the bottom edge of a scroll view (the system's \
                soft scroll edge effect under the home indicator, a bottom bar or a bottom search \
                field); a row half under it measures as faint.
                """),
            AuditException(.contrast, Match(description: "Contrast failed", withoutElement: true), because: """
                Text cut off by the bottom edge of the screen, under the system's scroll edge \
                effect, which the audit cannot tie to an element: it comes only on pages whose \
                content runs past the bottom, never on pages that fit.
                """),
            AuditException(.contrast, Match(description: "Contrast failed", labelTest: componentsIsTileGlyph), because: """
                A space tile draws the space's stored icon (data: an emoji, several, or letters) \
                on a 24 % tint of its colour (08 §4.3); decorative and hidden from VoiceOver.
                """),

            // Dynamic Type.
            AuditException(.dynamicType, Match(description: "Dynamic Type font sizes are partially unsupported", labelPattern: componentsShortCodePattern), because: """
                The label tape is fixed geometry: its code stops growing at .xxxLarge (RN tape \
                maxScale 1.5–1.6, 08 §6) and never wraps; spoken tapes spell the code instead.
                """),
            AuditException(.dynamicType, Match(description: "Dynamic Type font sizes are partially unsupported", labelTest: componentsIsCount), because: """
                A count on a badge (the tape's badge size, the drop-zone count) sits in a fixed \
                pill and stops at .xxLarge (RN badge maxScale 1.3, 08 §6).
                """),
            AuditException(.dynamicType, Match(description: "Dynamic Type font sizes are partially unsupported", element: "", elementType: .textField), because: """
                A quantity stepper's digits sit in fixed 48/56 pt cells and stop at .xxxLarge \
                (RN stepper maxScale 1.6, 08 §6); VoiceOver adjusts the stepper as one element.
                """),
            AuditException(.dynamicType, Match(description: "Dynamic Type font sizes are partially unsupported", element: "camera-pill"), because: """
                The camera's title pill is pinned over the picture and stops at AX1 (RN meta \
                maxScale 2.0, 08 §6), so two lines never cut the container's name.
                """),
            AuditException(.dynamicType, Match(description: "Dynamic Type font sizes are", minY: windowHeight * 0.38), because: """
                Xcode's audit loses text that growing text pushes off the screen and reports it \
                as partially unsupported or unsupported: the same item row passes at the top of \
                a list and is reported halfway down it, and plain text in the same place passes \
                (lab runs for ComponentsGalleryAuditUITests). Each gallery section is also \
                audited alone at the top, where this does not happen.
                """),
            AuditException(.dynamicType, Match(withoutElement: true), because: """
                An issue the audit ties to no element names nothing to fix; it comes with text \
                that left the screen while the size changed (as above).
                """),
            AuditException(.dynamicType, Match(labelTest: componentsIsTileGlyph), because: """
                A space tile's stored icon is drawn at a fixed size for its tile, one line, \
                clipped, not scaled with Dynamic Type (RN allowFontScaling false, 08 §4.3).
                """),
            AuditException(.dynamicType, Match(description: "Dynamic Type font sizes are partially unsupported", element: "sheet-close"), because: """
                The shell's Cancel is a stock toolbar button: the navigation bar caps its items \
                and shows the Large Content Viewer, as every system bar does.
                """),

            // Text hidden on purpose.
            AuditException(.elementDetection, Match(description: "Potentially inaccessible text", withoutElement: true), because: """
                Visible text hidden from VoiceOver because it is read another way: a field's \
                label and hint through the field itself (TextFieldCopy.spokenLabel), decorative \
                tapes, tiles and the mark (08 §9.2 (3)).
                """),

            AuditException(.dynamicType, Match(description: "Dynamic Type font sizes are partially unsupported", labelTest: componentsIsTypeName), because: """
                The type grid spells the chosen type under its fixed 72 pt tile and stops at AX1, \
                shrinking rather than clipping (RN TypeGrid); every tile is read by its name.
                """),

            // Clipped text and targets in stock controls.
            AuditException(.textClipped, Match(withoutElement: true), because: """
                Text cut off by the bottom edge of the screen, which the audit cannot tie to an \
                element (as for contrast above).
                """),
            AuditException(.textClipped, Match(labelTest: componentsIsTileGlyph), because: """
                A space tile clips a stored icon longer than the tile (08 §4.3); the simulator \
                also draws colour emoji as wider boxes.
                """),
            AuditException(.textClipped, Match(elementType: .searchField), because: """
                The stock `.searchable` field (no SwiftUI control over it) cuts its placeholder \
                at large sizes; what is typed scrolls inside it.
                """),
            AuditException(.textClipped, Match(elementType: .textField), because: """
                A stock single-line TextField scrolls what is typed, and cuts a long placeholder, \
                rather than wrapping; the field's label and hint above it wrap.
                """),
            AuditException(.hitRegion, Match(element: "Clear text"), because: """
                The stock search field's clear button (system).
                """),
        ]
    }

    /// A short code as the tape shows it: `CAB-J92R`, `DRW-7K2M`.
    static let componentsShortCodePattern = "[A-Z0-9]{2,5}-[A-Z0-9]{3,5}"

    /// What a space tile draws: one or more emoji, or the schema default `cube`.
    static let componentsIsTileGlyph: @Sendable (String) -> Bool = { label in
        if label == "cube" { return true }
        return !label.isEmpty && label.unicodeScalars.allSatisfy { scalar in
            // Emoji drawn as pictures (not the digits and symbols that also carry the property),
            // with their variation selector and joiners.
            scalar.properties.isEmojiPresentation
                || (scalar.properties.isEmoji && scalar.value > 0x238C)
                || scalar.value == 0xFE0F || scalar.value == 0x200D
        }
    }

    /// The type grid's names (`strings.entities.typeNames`).
    static let componentsIsTypeName: @Sendable (String) -> Bool = { label in
        ["Box", "Drawer", "Shelf", "Cabinet", "Bin", "Bag", "Crate", "Container"].contains(label)
    }

    /// A badge's count: digits only.
    static let componentsIsCount: @Sendable (String) -> Bool = { label in
        !label.isEmpty && label.allSatisfy(\.isNumber)
    }
}
