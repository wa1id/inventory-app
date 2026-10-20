import Foundation
import InventoryCore
import InventoryStrings
import Testing
@testable import InventoryAppModels

/// Port of src/hooks/__tests__/useSpreadGap.test.ts: the gap the picker grids spread with.
@Suite("spreadGap (useSpreadGap.ts)")
struct ComponentsSpreadGapTests {
    @Test("keeps the minimum gap until the row is measured")
    func minimumUntilMeasured() {
        #expect(TileSpread.gap(width: 0, tile: 48, minGap: 8) == 8)
    }

    @Test("spreads as many tiles as fit so the row reaches both edges")
    func spreads() {
        let gap = TileSpread.gap(width: 358, tile: 48, minGap: 8)
        #expect(gap == 14)
        #expect(6 * 48 + 5 * gap <= 358)
        #expect(TileSpread.columns(width: 358, tile: 48, minGap: 8) == 6)
    }

    @Test("never rounds a row past its width")
    func neverPastWidth() {
        let gap = TileSpread.gap(width: 358.33, tile: 48, minGap: 4)
        #expect(6 * 48 + 5 * gap <= 358.33)
    }

    @Test("keeps to a fixed number of columns when asked")
    func fixedColumns() {
        #expect(abs(TileSpread.gap(width: 358, tile: 72, minGap: 8, columns: 4) - 23.3) < 0.05)
        #expect(TileSpread.gap(width: 288, tile: 72, minGap: 8, columns: 3) == 36)
        #expect(TileSpread.columns(width: 358, tile: 72, minGap: 8, columns: 4) == 4)
    }

    @Test("falls back to fewer columns, or the minimum, when they do not fit")
    func fallsBack() {
        #expect(TileSpread.gap(width: 250, tile: 72, minGap: 8, columns: 4) == 17)
        #expect(TileSpread.gap(width: 60, tile: 48, minGap: 8) == 8)
        #expect(TileSpread.columns(width: 250, tile: 72, minGap: 8, columns: 4) == 3)
        #expect(TileSpread.columns(width: 30, tile: 48, minGap: 8) == 1)
    }
}

/// Port of src/ui/__tests__/theme.test.tsx (`onColor`, `SPACE_PRESETS`) plus 08 §11 (j), and the
/// choice rules of the emoji and swatch pickers (07 §4.12).
@Suite("Space palette (theme.ts, EmojiPicker.tsx, SwatchPicker.tsx)")
struct ComponentsSpacePaletteTests {
    @Test("puts light text on dark fills and dark text on light fills")
    func onColorExtremes() {
        #expect(SpacePalette.onColor("#000000") == "#FFFFFF")
        #expect(SpacePalette.onColor("#FFFFFF") == "#12161C")
    }

    @Test("accepts shorthand hex and a missing leading hash")
    func onColorShorthand() {
        #expect(SpacePalette.onColor("#000") == "#FFFFFF")
        #expect(SpacePalette.onColor("fff") == "#12161C")
    }

    @Test("weights green more than blue, so it is not a naive average")
    func onColorWeights() {
        #expect(SpacePalette.onColor("#0000FF") == "#FFFFFF")
        #expect(SpacePalette.onColor("#00FF00") == "#12161C")
    }

    @Test("clears WCAG AA for large text on every space colour")
    func onColorContrast() {
        for color in SpacePalette.colors {
            #expect(HexColor.contrast(SpacePalette.onColor(color), color) >= 3)
        }
    }

    @Test("picks the higher-contrast foreground, not the intuitive one")
    func onColorDefaultBlue() {
        #expect(SpacePalette.onColor("#5B8DEF") == "#12161C")
    }

    @Test("returns #12161C for all six palette colours and the fallback grey")
    func onColorPaletteVectors() {
        for color in SpacePalette.colors + [HexColor.spaceFallback] {
            #expect(SpacePalette.onColor(color) == "#12161C")
        }
    }

    @Test("offers distinct one-tap names drawn from the shared palette")
    func presets() {
        let names = SpacePalette.presets.map(\.name)
        #expect(Set(names).count == names.count)
        for preset in SpacePalette.presets {
            #expect(SpacePalette.colors.contains(preset.color))
            #expect(!preset.icon.isEmpty)
        }
        #expect(names == ["Garage", "Wardrobe", "Loft", "Cellar"])
    }

    @Test("keeps the variation selectors of the stored icons")
    func exactEmoji() {
        #expect(SpacePalette.icons[0].unicodeScalars.map(\.value) == [0x1F6CB, 0xFE0F])
        #expect(SpacePalette.icons[2].unicodeScalars.map(\.value) == [0x1F6CF, 0xFE0F])
        #expect(SpacePalette.icons.count == 10)
        // Every offered icon has a spoken name.
        for icon in SpacePalette.icons + ["👕", "🚪"] {
            #expect(L10n.Entities.IconNames[icon] != nil, "\(icon)")
        }
    }

    @Test("offers the presets' icons after the list, twelve in all")
    func iconChoices() {
        let choices = SpacePalette.iconChoices(value: "🧰")
        #expect(choices.count == 12)
        #expect(choices.map(\.icon).suffix(2) == ["👕", "🚪"])
        #expect(choices.filter(\.isSelected).map(\.name) == ["Toolbox"])
        #expect(choices.map(\.identifier).first == "space-icon-0")
    }

    @Test("puts a stored icon in neither list first, selected, as the current icon")
    func iconChoicesStoredFirst() {
        // A sofa stored without U+FE0F is not the offered sofa.
        let choices = SpacePalette.iconChoices(value: "🛋")
        #expect(choices.count == 13)
        #expect(choices[0].icon == "🛋")
        #expect(choices[0].isSelected)
        #expect(choices[0].name == L10n.Entities.currentIcon)
        #expect(choices.filter(\.isSelected).count == 1)
        #expect(SpacePalette.iconChoices(value: "cube")[0].icon == "cube")
    }

    @Test("a blank icon selects nothing and adds nothing")
    func iconChoicesBlank() {
        #expect(SpacePalette.iconChoices(value: "").count == 12)
        #expect(SpacePalette.iconChoices(value: "  ").allSatisfy { !$0.isSelected })
        #expect(SpacePalette.iconChoices(value: "  ").count == 12)
    }

    @Test("names the swatches and selects through safeColor, keeping what is stored")
    func colourChoicesListed() {
        let choices = SpacePalette.colourChoices(value: "#5b8def")
        #expect(choices.count == 6)
        #expect(choices.map(\.name) == ["Blue", "Green", "Orange", "Purple", "Amber", "Teal"])
        #expect(choices.filter(\.isSelected).map(\.swatch) == ["#5B8DEF"])
        #expect(choices[0].identifier == "space-colour-#5B8DEF")
        #expect(choices.allSatisfy { $0.checkColor == "#12161C" })
    }

    @Test("puts a colour outside the palette first as the selected current colour")
    func colourChoicesCurrent() {
        let choices = SpacePalette.colourChoices(value: "#123456")
        #expect(choices.count == 7)
        #expect(choices[0].swatch == "#123456")
        #expect(choices[0].name == L10n.Entities.currentColour)
        #expect(choices[0].isSelected)
        #expect(choices.dropFirst().allSatisfy { !$0.isSelected })
        #expect(choices[0].checkColor == "#FFFFFF")
        // Junk renders as the fallback grey, still first and selected.
        let junk = SpacePalette.colourChoices(value: "blue")
        #expect(junk[0].fill == HexColor.spaceFallback)
        #expect(junk[0].swatch == "blue")
    }

    @Test("the preview row shows the trimmed name or the fallback")
    func previewName() {
        #expect(SpacePalette.previewName("  Attic ", fallback: "Kitchen") == "Attic")
        #expect(SpacePalette.previewName(" \u{00A0}", fallback: "Kitchen") == "Kitchen")
    }

    @Test("tiles draw the trimmed icon or the house")
    func tileGlyphs() {
        #expect(SpacePalette.tileGlyph(" 🚗 ") == "🚗")
        #expect(SpacePalette.tileGlyph("\u{FEFF}") == nil)
        #expect(SpacePalette.tileGlyph(nil) == nil)
        #expect(SpacePalette.tileGlyph("cube") == "cube")
        #expect(SpacePalette.tileMetrics(size: 32) == (17, 7))
        #expect(SpacePalette.tileMetrics(size: 48) == (24, 9))
        #expect(SpacePalette.tileMetrics(size: 56) == (28, 10))
        #expect(SpacePalette.tileMetrics(size: 64) == (34, 12))
    }
}
