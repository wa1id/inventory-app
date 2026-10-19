import Foundation

// RN: src/ui/color.ts. Colour maths for stored space colours. A stored colour
// is any string (the drop zone's teal, presets, whatever the desk or an older
// build wrote), so everything starts from `safeColor`.

/// Colour helpers over `#RRGGBB` strings.
public enum HexColor {
    /// The desk's fallback grey for unusable values (mirrors `fixed.spaceFallback`).
    public static let spaceFallback = "#8A948D"

    /// Any stored value → `#RRGGBB` upper case; invalid → ``spaceFallback`` (RN `safeColor`).
    ///
    /// Trims (JS rules), allows an optional `#`, accepts 3, 4, 6 or 8 ASCII hex
    /// digits; short forms double their first three digits, and alpha is dropped.
    public static func safeColor(_ value: String?) -> String {
        var scalars = Array((value ?? "").jsTrimmed().unicodeScalars)
        if scalars.first == "#" { scalars.removeFirst() }
        guard [3, 4, 6, 8].contains(scalars.count), scalars.allSatisfy(\.isASCIIHexDigit) else {
            return spaceFallback
        }
        let digits = scalars.count <= 4 ? scalars.prefix(3).flatMap { [$0, $0] } : Array(scalars.prefix(6))
        return "#" + String(String.UnicodeScalarView(digits)).uppercased()
    }

    /// The 0–255 channels of a colour, after ``safeColor(_:)`` (RN `rgb`).
    public static func rgb(_ hex: String) -> (r: Int, g: Int, b: Int) {
        let digits = Array(safeColor(hex).unicodeScalars.dropFirst())
        func channel(_ offset: Int) -> Int {
            Int(String(String.UnicodeScalarView(digits[offset..<(offset + 2)])), radix: 16) ?? 0
        }
        return (channel(0), channel(2), channel(4))
    }

    /// `#RRGGBB` from 0–255 channels, rounded (JS `Math.round`) and clamped (RN `toHex`).
    public static func toHex(_ r: Double, _ g: Double, _ b: Double) -> String {
        "#" + byte(r) + byte(g) + byte(b)
    }

    /// `color-mix(in srgb, a weightA, b)`: a per-channel sRGB lerp, rounded (RN `mixHex`).
    public static func mixHex(_ a: String, _ b: String, weightA: Double) -> String {
        let first = rgb(a)
        let second = rgb(b)
        func mix(_ x: Int, _ y: Int) -> Double { Double(x) * weightA + Double(y) * (1 - weightA) }
        return toHex(mix(first.r, second.r), mix(first.g, second.g), mix(first.b, second.b))
    }

    /// A space colour's tint on an opaque surface: the 24 % fill behind its emoji (RN `spaceTint`).
    public static func spaceTint(_ color: String, surface: String, amount: Double = 0.24) -> String {
        mixHex(color, surface, weightA: amount)
    }

    /// `#RRGGBBAA` with the alpha clamped to 0…1, e.g. the 45 % tile edge (RN `withAlpha`).
    public static func withAlpha(_ color: String, _ alpha: Double) -> String {
        safeColor(color) + byte(min(1, max(0, alpha)) * 255)
    }

    /// WCAG 2.x relative luminance (RN `luminance`).
    public static func luminance(_ hex: String) -> Double {
        func channel(_ value: Int) -> Double {
            let srgb = Double(value) / 255
            return srgb <= 0.03928 ? srgb / 12.92 : pow((srgb + 0.055) / 1.055, 2.4)
        }
        let (r, g, b) = rgb(hex)
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// WCAG contrast ratio between two colours, 1–21 (RN `contrast`).
    public static func contrast(_ a: String, _ b: String) -> Double {
        let first = luminance(a)
        let second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// Two upper-case hex digits of a channel, after JS `Math.round` and a clamp to 0…255.
    private static func byte(_ channel: Double) -> String {
        let clamped = min(255, max(0, jsRound(channel)))
        let value = Int(clamped)
        let digits = String(value, radix: 16, uppercase: true)
        return value < 16 ? "0" + digits : digits
    }

    /// JS `Math.round`: halves round toward +∞.
    private static func jsRound(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        let floor = value.rounded(.down)
        return value - floor >= 0.5 ? floor + 1 : floor
    }
}
