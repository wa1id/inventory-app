import InventoryCore
import InventoryStrings

// RN: src/ui/theme.ts (SPACE_COLORS, SPACE_ICONS, SPACE_PRESETS, onColor) and the choice rules of
// src/ui/components/pickers/EmojiPicker.tsx and SwatchPicker.tsx (07 §4.12, 08 §4.2-4.3).
// Emoji are compared and stored exactly: "🛋️" (with U+FE0F) is not "🛋".

/// The colours, icons and presets a space can be made with, and how the pickers offer them.
public enum SpacePalette {
    /// The colours offered, in order (RN `SPACE_COLORS`), written as they are stored.
    public static let colors = ["#5B8DEF", "#2E9E4F", "#E4572E", "#B15BEF", "#E0A800", "#0F9BB0"]

    /// The icons offered, in order (RN `SPACE_ICONS`), with their variation selectors.
    public static let icons = ["🛋\u{FE0F}", "🍳", "🛏\u{FE0F}", "🚗", "🧰", "📚", "🧺", "🏠", "🪴", "🎒"]

    /// A one-tap starting point for a space (RN `SPACE_PRESETS` entry).
    public struct Preset: Sendable, Hashable, Identifiable {
        /// An English literal that becomes the stored name (DECISIONS U9).
        public let name: String
        public let icon: String
        public let color: String

        public var id: String { name }
    }

    /// Garage, Wardrobe, Loft, Cellar (RN `SPACE_PRESETS`).
    public static let presets = [
        Preset(name: "Garage", icon: "🚗", color: colors[0]),
        Preset(name: "Wardrobe", icon: "👕", color: colors[3]),
        Preset(name: "Loft", icon: "🏠", color: colors[2]),
        Preset(name: "Cellar", icon: "🚪", color: colors[4]),
    ]

    /// The dark foreground `onColor` picks; not the ink token.
    public static let onLight = "#12161C"
    /// The light foreground `onColor` picks.
    public static let onDark = "#FFFFFF"

    /// The readable foreground on a fill of `hex`: whichever of white and `#12161C` measures
    /// the higher WCAG contrast, white on a tie (RN `onColor`). The swatch checkmark.
    public static func onColor(_ hex: String) -> String {
        HexColor.contrast(onDark, hex) >= HexColor.contrast(onLight, hex) ? onDark : onLight
    }

    // MARK: Icon picker

    /// One tile of the icon picker.
    public struct IconChoice: Sendable, Hashable, Identifiable {
        public let icon: String
        /// "Toolbox", or "Current icon" for one the app does not name.
        public let name: String
        public let isSelected: Bool
        /// Its place in the grid: `space-icon-<index>`.
        public let index: Int

        public var id: Int { index }
        public var identifier: String { "space-icon-\(index)" }
    }

    /// The icon picker's tiles (RN `EmojiPicker`): the offered icons, then the presets' icons not
    /// among them (👕, 🚪), and a stored icon that is in neither list first, selected. A blank
    /// value (an edit form before it is seeded) selects nothing and adds nothing.
    public static func iconChoices(options: [String] = icons, value: String) -> [IconChoice] {
        var offered = options
        for preset in presets where !offered.contains(where: { EntityText.same($0, preset.icon) }) {
            offered.append(preset.icon)
        }
        let listed = offered.contains { EntityText.same($0, value) }
        let choices = listed || !EntityText.hasText(value) ? offered : [value] + offered
        return choices.enumerated().map { index, icon in
            IconChoice(
                icon: icon,
                name: L10n.Entities.IconNames[icon] ?? L10n.Entities.currentIcon,
                isSelected: EntityText.same(icon, value),
                index: index
            )
        }
    }

    // MARK: Colour picker

    /// One swatch of the colour picker.
    public struct ColourChoice: Sendable, Hashable, Identifiable {
        /// The string written when it is picked, as the palette spells it (or the stored value).
        public let swatch: String
        /// `#RRGGBB` to draw.
        public let fill: String
        /// "Amber", or "Current colour" for a stored colour outside the palette.
        public let name: String
        public let isSelected: Bool
        public let index: Int
        /// The checkmark's colour on this fill.
        public var checkColor: String { SpacePalette.onColor(fill) }

        public var id: Int { index }
        /// `space-colour-<#RRGGBB>`.
        public var identifier: String { "space-colour-\(fill)" }
    }

    /// The colour picker's swatches (RN `SwatchPicker`). A stored colour matches a swatch through
    /// `safeColor`, so `#5b8def` selects Blue (and stays lower case until another is tapped); a
    /// colour outside the palette comes first as the selected "Current colour".
    public static func colourChoices(palette: [String] = colors, value: String) -> [ColourChoice] {
        let target = HexColor.safeColor(value)
        let listed = palette.contains { HexColor.safeColor($0) == target }
        let swatches = listed ? palette : [value] + palette
        return swatches.enumerated().map { index, swatch in
            let fill = HexColor.safeColor(swatch)
            let isCurrent = !listed && index == 0
            return ColourChoice(
                swatch: swatch,
                fill: fill,
                name: isCurrent ? L10n.Entities.currentColour : (L10n.Entities.ColourNames[fill] ?? L10n.Entities.currentColour),
                isSelected: listed ? fill == target : index == 0,
                index: index
            )
        }
    }

    /// The space form's preview name: the trimmed name, or the fallback while it is blank
    /// (RN `values.name.trim() || previewFallbackName`).
    public static func previewName(_ name: String, fallback: String) -> String {
        let trimmed = name.jsTrimmed()
        return trimmed.isEmpty ? fallback : trimmed
    }

    // MARK: Tiles

    /// What a space tile draws: the stored icon trimmed (JS rules), or nil for the house glyph
    /// (RN `SpaceTile`). The stored value is never rewritten; `cube` draws as the letters.
    public static func tileGlyph(_ icon: String?) -> String? {
        let glyph = (icon ?? "").jsTrimmed()
        return glyph.isEmpty ? nil : glyph
    }

    /// The emoji size and corner radius for a tile of `size` pt (32, 48, 56 or 64; RN `TILE`).
    public static func tileMetrics(size: Int) -> (emoji: Double, radius: Double) {
        switch size {
        case ...32: (17, 7)
        case ...48: (24, 9)
        case ...56: (28, 10)
        default: (34, 12)
        }
    }
}
