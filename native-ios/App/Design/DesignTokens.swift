import SwiftUI
import InventoryCore

// The few design tokens the native look keeps (08 §4.5). Everything else is a system colour,
// a stock control style or a list metric. Named colours come from Assets.xcassets:
// - AccentColor: ink, the interactive tint (U2).
// - Tape / TapeInk: the label tape and the mark, never a text or control tint (U2).
// - SearchMark: the background of search matches (RN `mark`).
// - PipRing: the 1 pt ring on pips and swatches, so a white space stays visible.

extension Color {
    /// A stored space colour, drawn through `safeColor`: any junk draws as the desk's grey
    /// `#8A948D` (08 §4.2). The colour is data, so it ignores the colour scheme.
    init(spaceHex value: String?) {
        let channels = HexColor.rgb(HexColor.safeColor(value))
        self.init(.sRGB, red: Double(channels.r) / 255, green: Double(channels.g) / 255, blue: Double(channels.b) / 255, opacity: 1)
    }
}

/// Colours the components draw with besides the asset catalog's.
enum DesignColor {
    /// Errors and "None left" as text (RN `signal`, 08 §4.5): `#B3361A` light, `#FF9573` dark.
    /// The system red (`#FF3B30`) measures 3.5:1 on white and fails WCAG AA for text; these keep
    /// at least 4.5:1 on the cells, the page and ``signalWash`` in both schemes (6.1:1 on white,
    /// 5.2:1 on the light wash, 6.8:1 on the dark wash).
    static let signal = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xFF / 255, green: 0x95 / 255, blue: 0x73 / 255, alpha: 1)
            : UIColor(red: 0xB3 / 255, green: 0x36 / 255, blue: 0x1A / 255, alpha: 1)
    })
    /// The warning banner's wash (RN `signalWash`): `#FBECE7` light, `#3A231C` dark, opaque so
    /// the measured contrast holds over any surface.
    static let signalWash = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x3A / 255, green: 0x23 / 255, blue: 0x1C / 255, alpha: 1)
            : UIColor(red: 0xFB / 255, green: 0xEC / 255, blue: 0xE7 / 255, alpha: 1)
    })
}

/// The opaque surface a space tile sits on. The tile mixes 24 % of the space colour into it, so
/// text beside the tile keeps its contrast whatever colour was picked (RN `spaceTint`).
enum SpaceTileSurface: Sendable, Hashable {
    /// A grouped list cell (RN `sheet`), the default.
    case cell
    /// A grouped page background (RN `plaster`): the space header, the presets.
    case page
    /// A plain list or screen background.
    case plain

    var color: Color {
        switch self {
        case .cell: Color(uiColor: .secondarySystemGroupedBackground)
        case .page: Color(uiColor: .systemGroupedBackground)
        case .plain: Color(uiColor: .systemBackground)
        }
    }
}

/// Fixed sizes the components keep (RN tokens.ts; 08 §4.5).
enum DesignMetrics {
    /// Content is centred at this width on iPad (U4).
    static let contentMaxWidth: CGFloat = 640
    /// Below this window width rows and bars stack (RN `NARROW_WIDTH`).
    static let narrowWidth: CGFloat = 360
    /// The iOS minimum for a custom tappable.
    static let minTouchTarget: CGFloat = 44
    /// List thumbnails (RN `THUMB_SMALL`, `THUMB`, `THUMB_PHOTO`, `THUMB_DETAIL`).
    static let thumbSmall: CGFloat = 48
    static let thumb: CGFloat = 56
    static let thumbPhoto: CGFloat = 76
    static let thumbDetail: CGFloat = 88
    /// The rounded corner of a thumbnail (RN `radius.thumb`).
    static let thumbRadius: CGFloat = 7
    /// Space tiles come in these sizes (RN `SpaceTileSize`).
    static let spaceTileSizes: [CGFloat] = [32, 48, 56, 64]
    /// Type tiles: picker rows, rows, and the type grid.
    static let typeTileSizes: [CGFloat] = [40, 48, 72]
    /// A wide card's corner (banners, the where card).
    static let cardRadius: CGFloat = 12
}

extension View {
    /// Keeps content to the readable column on iPad (640 pt), centred (U4).
    func readableContentWidth() -> some View {
        frame(maxWidth: DesignMetrics.contentMaxWidth).frame(maxWidth: .infinity)
    }
}
