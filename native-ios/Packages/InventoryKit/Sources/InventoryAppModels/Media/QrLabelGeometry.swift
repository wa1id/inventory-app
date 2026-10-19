import Foundation

/// The QR label's sizes: the on-screen card and the picture the share sheet carries
/// (07 §5.2-5.3; RN `src/ui/container/QrCard.tsx`, `src/ui/container/labelImage.ts`).
///
/// The card draws the code `modules` points across inside a white quiet zone of
/// ``quietZone`` points, so the code with its quiet zone is `size = modules + 2 × 16` points.
/// The picture is a 1024 px snapshot of that drawing, so its white margin keeps the card's
/// ratio `16 / size` (about 65 px at the standard size; 07 Q6 keeps this parity even though it
/// is about 2.4 modules, under the 4 the QR specification asks for).
public enum QrLabelGeometry {
    /// The code's modules on screen at most (RN `MODULES`).
    public static let maxModules: Double = 220
    /// The code never shrinks below this on a narrow window.
    public static let minModules: Double = 120
    /// White drawn into the picture around the modules on each side (RN `QUIET`).
    public static let quietZone: Double = 16
    /// The card's padding (RN `PADDING = space.xl`).
    public static let cardPadding: Double = 24
    /// The screen's side gutter the card sits inside (RN `GUTTER`).
    public static let screenGutter: Double = 16
    /// The shared picture's side in pixels (RN `PICTURE_PX`).
    public static let picturePixels = 1024

    /// The code's size on the card.
    public struct Card: Sendable, Hashable {
        /// The modules' side in points.
        public let modules: Double
        /// The code with its quiet zone, in points (`modules + 2 × quietZone`).
        public let size: Double

        public init(modules: Double, size: Double) {
            self.modules = modules
            self.size = size
        }

        /// The white margin as a share of the side (16 / 252 at the standard size).
        public var quietRatio: Double { QrLabelGeometry.quietZone / size }
    }

    /// The card's code for a window `windowWidth` points wide (RN `QrCard.tsx:43-48`):
    /// `room = width − 2·16 − 2·24 − 2`, `modules = max(120, min(220, room − 32))`.
    /// Every iPhone at standard zoom (≥ 334 pt) gets 220 / 252; a 320 pt window gets 206 / 238.
    // RN: src/ui/container/QrCard.tsx:43-48
    public static func card(windowWidth: Double) -> Card {
        card(availableWidth: windowWidth - 2 * screenGutter)
    }

    /// The card's code when the card is offered `availableWidth` points, which is the window less
    /// the screen's two 16 pt gutters (what RN measured from the window).
    public static func card(availableWidth: Double) -> Card {
        let room = availableWidth - 2 * cardPadding - 2
        let modules = max(minModules, min(maxModules, room - 2 * quietZone))
        return Card(modules: modules, size: modules + 2 * quietZone)
    }

    /// The shared picture's white margin in whole pixels on each side: the card's quiet-zone
    /// ratio scaled to `pixels` (RN snapshot of the card's SVG, `labelImage.ts:12-33`).
    public static func pictureMargin(cardSize: Double, pixels: Int = picturePixels) -> Int {
        guard cardSize > 0, cardSize.isFinite else { return 0 }
        return Int((Double(pixels) * quietZone / cardSize).rounded())
    }
}

/// The share picture's file: `label-<code>.png` in a temporary directory, replaced on every share.
/// The first native launch purges RN's leftovers by the same pattern (DECISIONS U11).
public enum QrLabelPictureFile {
    /// `label-` + the short code with everything but ASCII letters, digits and `-` removed, or
    /// `label-label.png` when nothing is left (RN `shortCode.replace(/[^A-Za-z0-9-]/g, '') || 'label'`).
    // RN: src/ui/container/labelImage.ts:43-46
    public static func name(shortCode: String) -> String {
        let kept = shortCode.unicodeScalars.filter { scalar in
            scalar.isASCII && (scalar == "-" || CharacterSet.alphanumerics.contains(scalar))
        }
        let stem = String(String.UnicodeScalarView(kept))
        return "label-\(stem.isEmpty ? "label" : stem).png"
    }
}
