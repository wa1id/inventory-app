import SwiftUI
import InventoryCore

/// The app's icons as SF Symbols (08 §5). RN drew 24 pt line glyphs from src/ui/icons/glyphs.tsx;
/// each case keeps the RN glyph's name. Icons are decorative: the control around them carries
/// the label.
enum Glyph: String, CaseIterable, Sendable {
    case search = "magnifyingglass"
    case close = "xmark"
    case back = "chevron.backward"
    case lock = "lock"
    case minus = "minus"
    case plus = "plus"
    case edit = "pencil"
    case move = "folder"
    case home = "house"
    case inbox = "tray"
    case photo = "photo"
    // Container types (data: `containers.visual_type`).
    case box = "shippingbox"
    case drawer = "tray.2"
    case shelf = "books.vertical"
    case cabinet = "cabinet"
    case bin = "archivebox"
    case bag = "bag"
    case crate = "square.grid.3x3"
    case other = "tag"
    case spaces = "square.split.bottomrightquarter"
    case camera = "camera"
    case gallery = "photo.on.rectangle"
    case scan = "qrcode.viewfinder"
    case qr = "qrcode"
    case settings = "gearshape"
    case flash = "bolt"
    case flashOff = "bolt.slash"
    case torchOn = "flashlight.on.fill"
    case torchOff = "flashlight.off.fill"
    case keyboard = "keyboard"
    case chevronRight = "chevron.right"
    case chevronDown = "chevron.down"
    case check = "checkmark"
    case trash = "trash"
    case share = "square.and.arrow.up"
    case warning = "exclamationmark.triangle"
    case info = "info.circle"
    case cloudOff = "icloud.slash"
    case server = "server.rack"
    case phone = "iphone"
    case backup = "clock.arrow.circlepath"
    case shield = "hand.raised"
    case refresh = "arrow.clockwise"
    case sparkle = "sparkles"
    case clock = "clock"
    case layers = "square.stack.3d.up"
    case link = "link"

    /// The SF Symbol's name.
    var systemName: String { rawValue }

    /// A container type's glyph; a type this build does not know is `other` (08 §4.4).
    static func container(_ type: ContainerVisualType) -> Glyph {
        switch type {
        case .box: .box
        case .drawer: .drawer
        case .shelf: .shelf
        case .cabinet: .cabinet
        case .bin: .bin
        case .bag: .bag
        case .crate: .crate
        default: .other
        }
    }
}

extension Image {
    /// The SF Symbol for a glyph.
    init(glyph: Glyph) {
        self.init(systemName: glyph.systemName)
    }
}

extension Label where Title == Text, Icon == Image {
    /// A label with a glyph as its icon.
    init(_ title: String, glyph: Glyph) {
        self.init(title, systemImage: glyph.systemName)
    }
}
