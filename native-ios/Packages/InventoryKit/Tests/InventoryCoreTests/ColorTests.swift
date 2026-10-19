import Testing
@testable import InventoryCore

// Port of src/ui/__tests__/color.test.ts (the "token contrast" block checks the
// RN design tokens, which the native app replaces with system colours, so it
// is not ported here), plus 08 §11 (g) and Fixtures/color.json.

/// `lightColors` / `darkColors` from src/ui/tokens.ts, as the RN test uses them.
private let lightInk = "#1C211E"
private let lightSheet = "#FFFFFF"
private let darkInk = "#E8ECE8"
private let darkSheet = "#1C201E"

@Suite("safeColor")
struct SafeColorTests {
    @Test("normalises 6-digit hex to upper case with a hash")
    func normalisesSixDigitHex() {
        #expect(HexColor.safeColor("#5b8def") == "#5B8DEF")
        #expect(HexColor.safeColor("5B8DEF") == "#5B8DEF")
        #expect(HexColor.safeColor("  #0F9BB0 ") == "#0F9BB0")
    }

    @Test("expands 3- and 4-digit shorthand and drops alpha")
    func expandsShorthandAndDropsAlpha() {
        #expect(HexColor.safeColor("#abc") == "#AABBCC")
        #expect(HexColor.safeColor("#abcd") == "#AABBCC")
        #expect(HexColor.safeColor("#11223344") == "#112233")
    }

    @Test("falls back to the desk grey for", arguments: [nil, "", "blue", "#12", "#12345", "#GGGGGG", "rgb(0,0,0)"])
    func fallsBackToTheDeskGrey(value: String?) {
        #expect(HexColor.safeColor(value) == "#8A948D")
    }

    // 08 §11 (g) and §4.2 extra vectors.
    @Test("trims the JS white space set and accepts ASCII digits only")
    func whitespaceAndDigitParity() {
        #expect(HexColor.safeColor("\u{FEFF}#5B8DEF") == "#5B8DEF")
        #expect(HexColor.safeColor("\u{00A0}#5b8def\u{00A0}") == "#5B8DEF")
        #expect(HexColor.safeColor("\u{0085}#5B8DEF") == "#8A948D")
        #expect(HexColor.safeColor("＃５Ｂ８ＤＥＦ") == "#8A948D")
        #expect(HexColor.safeColor("abc") == "#AABBCC")
        #expect(HexColor.safeColor("ABCD") == "#AABBCC")
        #expect(HexColor.safeColor("#5B8DEFF") == "#8A948D")
    }
}

@Suite("rgb and toHex")
struct RgbAndToHexTests {
    @Test("round-trips channels")
    func roundTripsChannels() {
        #expect(HexColor.rgb("#5B8DEF") == (91, 141, 239))
        #expect(HexColor.toHex(91, 141, 239) == "#5B8DEF")
    }

    @Test("rounds and clamps")
    func roundsAndClamps() {
        #expect(HexColor.toHex(-4, 255.6, 127.5) == "#00FF80")
    }
}

@Suite("mixHex")
struct MixHexTests {
    @Test("returns each end at weight 1 and 0")
    func returnsEachEnd() {
        #expect(HexColor.mixHex("#5B8DEF", "#FFFFFF", weightA: 1) == "#5B8DEF")
        #expect(HexColor.mixHex("#5B8DEF", "#FFFFFF", weightA: 0) == "#FFFFFF")
    }

    @Test("lerps per channel")
    func lerpsPerChannel() {
        #expect(HexColor.mixHex("#000000", "#FFFFFF", weightA: 0.5) == "#808080")
    }
}

@Suite("spaceTint")
struct SpaceTintTests {
    @Test("matches the desk’s 24 % colour-mix")
    func matchesTheDeskColourMix() {
        #expect(HexColor.spaceTint("#5B8DEF", surface: "#FFFFFF", amount: 0.24) == "#D8E4FB")
    }

    @Test("defaults to 24 % and tolerates junk colours")
    func defaultsAndToleratesJunk() {
        #expect(HexColor.spaceTint("#5B8DEF", surface: "#FFFFFF") == "#D8E4FB")
        #expect(HexColor.spaceTint("not a colour", surface: "#FFFFFF") == HexColor.mixHex("#8A948D", "#FFFFFF", weightA: 0.24))
    }

    @Test("keeps ink readable on the tint of any colour, light and dark")
    func keepsInkReadable() {
        for color in ["#000000", "#FFFFFF", "#E0A800", "#0F9BB0", "#5B8DEF"] {
            #expect(HexColor.contrast(lightInk, HexColor.spaceTint(color, surface: lightSheet)) > 9)
            #expect(HexColor.contrast(darkInk, HexColor.spaceTint(color, surface: darkSheet)) > 6)
        }
    }
}

@Suite("withAlpha")
struct WithAlphaTests {
    @Test("appends the alpha byte")
    func appendsTheAlphaByte() {
        #expect(HexColor.withAlpha("#5B8DEF", 0.45) == "#5B8DEF73")
        #expect(HexColor.withAlpha("#abc", 1) == "#AABBCCFF")
        #expect(HexColor.withAlpha("#5B8DEF", 0) == "#5B8DEF00")
    }
}

@Suite("luminance and contrast")
struct LuminanceAndContrastTests {
    @Test("measures the WCAG extremes")
    func measuresTheWCAGExtremes() {
        #expect(HexColor.luminance("#000000") == 0)
        #expect(HexColor.luminance("#FFFFFF") == 1)
        #expect(abs(HexColor.contrast("#000000", "#FFFFFF") - 21) < 1e-5)
        #expect(abs(HexColor.contrast("#FFFFFF", "#000000") - 21) < 1e-5)
    }
}

@Suite("color parity (Fixtures/color.json)")
struct ColorParityTests {
    struct Safe: Decodable { let input: String; let safe: String; let rgb: [Int] }
    struct Hex: Decodable { let r: Double; let g: Double; let b: Double; let hex: String }
    struct Mix: Decodable { let a: String; let b: String; let weight: Double; let hex: String }
    struct Tint: Decodable { let color: String; let surface: String; let hex: String }
    struct Alpha: Decodable { let color: String; let alpha: Double; let hex: String }
    struct Luminance: Decodable { let color: String; let luminance: Double }
    struct Contrast: Decodable { let a: String; let b: String; let contrast: Double }
    struct File: Decodable {
        let safe: [Safe]
        let hex: [Hex]
        let mix: [Mix]
        let tint: [Tint]
        let alpha: [Alpha]
        let luminance: [Luminance]
        let contrast: [Contrast]
    }

    let file: File

    init() throws {
        file = try loadFixture("color")
    }

    @Test("safeColor and rgb match JS")
    func safeMatchesJS() {
        for entry in file.safe {
            #expect(HexColor.safeColor(entry.input) == entry.safe, "\(scalarDump(entry.input))")
            let (r, g, b) = HexColor.rgb(entry.input)
            #expect([r, g, b] == entry.rgb)
        }
    }

    @Test("toHex, mixHex, spaceTint and withAlpha match JS")
    func blendsMatchJS() {
        for entry in file.hex {
            #expect(HexColor.toHex(entry.r, entry.g, entry.b) == entry.hex, "\(entry.r) \(entry.g) \(entry.b)")
        }
        for entry in file.mix {
            #expect(HexColor.mixHex(entry.a, entry.b, weightA: entry.weight) == entry.hex, "\(entry.a) \(entry.b) \(entry.weight)")
        }
        for entry in file.tint {
            #expect(HexColor.spaceTint(entry.color, surface: entry.surface) == entry.hex)
        }
        for entry in file.alpha {
            #expect(HexColor.withAlpha(entry.color, entry.alpha) == entry.hex, "\(entry.color) \(entry.alpha)")
        }
    }

    @Test("luminance and contrast match JS")
    func ratiosMatchJS() {
        for entry in file.luminance {
            #expect(abs(HexColor.luminance(entry.color) - entry.luminance) < 1e-12, "\(entry.color)")
        }
        for entry in file.contrast {
            #expect(abs(HexColor.contrast(entry.a, entry.b) - entry.contrast) < 1e-9, "\(entry.a) \(entry.b)")
        }
    }
}
