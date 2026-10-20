import SwiftUI
import InventoryAppModels
import InventoryCore

/// A space's colour as a small dot before its name (RN `SpacePip`). Decorative: the name always
/// follows, so colour never carries meaning alone.
struct SpacePip: View {
    let color: String?
    /// 10 inline and on camera chrome, 12 in rows and picker headers, 14 on the where card.
    var size: CGFloat = 12

    var body: some View {
        Circle()
            .fill(Color(spaceHex: color))
            .overlay(Circle().strokeBorder(Color(.pipRing), lineWidth: 1))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A space's icon on a 24 % tint of its colour (RN `SpaceTile`).
///
/// The tint is opaque: the surface colour is drawn first, then the space colour at 24 %, so
/// text beside the tile keeps its contrast whatever colour was picked, also over glass. The
/// edge is the colour at 45 %. The stored icon is drawn as given (an emoji, several, letters),
/// one line, clipped, not scaled with Dynamic Type; a blank one draws the house. Decorative.
struct SpaceTile: View {
    let icon: String?
    let color: String?
    /// 32, 48, 56 or 64.
    var size: CGFloat = 56
    var surface: SpaceTileSurface = .cell

    var body: some View {
        let metrics = SpacePalette.tileMetrics(size: Int(size))
        let shape = RoundedRectangle(cornerRadius: metrics.radius, style: .continuous)
        ZStack {
            shape.fill(surface.color)
            shape.fill(Color(spaceHex: color).opacity(0.24))
            shape.strokeBorder(Color(spaceHex: color).opacity(0.45), lineWidth: 1)
            if let glyph = SpacePalette.tileGlyph(icon) {
                // A fixed picture: the name beside it scales, the emoji does not. Centred when it
                // fits; several characters ("cube") start at the edge and are cut off at the end,
                // as RN's one clipped line.
                let text = Text(verbatim: glyph)
                    .font(.system(size: metrics.emoji))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()
                ViewThatFits(in: .horizontal) {
                    text
                    text.frame(width: size - 2, alignment: .leading)
                }
                .frame(width: size, height: size)
                .clipped()
            } else {
                Image(glyph: .home)
                    .font(.system(size: size / 2))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}

/// A container type as a symbol in a small rounded square (RN `TypeTile`). An unknown stored
/// type draws the `other` tag. Decorative.
struct TypeTile: View {
    let type: ContainerVisualType
    /// 40, 48 or 72.
    var size: CGFloat = 48
    /// Another glyph in the same frame (the drop zone's tray in the place picker).
    var glyph: Glyph?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size >= 72 ? 10 : 9, style: .continuous)
        Image(glyph: glyph ?? Glyph.container(type))
            .font(.system(size: size >= 72 ? 28 : 22))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(shape.fill(Color(uiColor: .tertiarySystemFill)))
            .accessibilityHidden(true)
    }
}

#Preview("Tiles") {
    List {
        HStack(spacing: 12) {
            SpaceTile(icon: "🚗", color: "#5B8DEF", size: 32)
            SpaceTile(icon: "🧰", color: "#2E9E4F", size: 48)
            SpaceTile(icon: "🛋\u{FE0F}", color: "#E4572E", size: 56)
            SpaceTile(icon: "", color: "#E0A800", size: 64)
        }
        HStack(spacing: 12) {
            SpaceTile(icon: "cube", color: "junk", size: 56)
            SpaceTile(icon: "AB", color: "#0F9BB0", size: 56, surface: .page)
            TypeTile(type: .box)
            TypeTile(type: "spaceship", size: 40)
            TypeTile(type: .other, size: 40, glyph: .inbox)
        }
        HStack {
            SpacePip(color: "#5B8DEF", size: 10)
            SpacePip(color: "#FFFFFF")
            SpacePip(color: "#000000", size: 14)
        }
    }
}
