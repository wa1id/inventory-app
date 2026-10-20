import SwiftUI
import InventoryAppModels
import InventoryStorage

/// An item's photo, or the `photo` placeholder (RN `Thumb`, 05 §14).
///
/// The stored URI goes through the environment's `PhotoPathResolver` (D-4), then ImageIO decodes
/// it at the drawn size off the main actor, with a small memory cache (``ThumbnailLoader``), so
/// scrolling never waits. A missing or unreadable photo leaves the placeholder, and a row reused
/// for another photo tries again. Decorative unless it has an action (the item screen's photo,
/// which opens it full screen).
struct Thumb: View {
    /// Callers pass `photoThumbUri ?? photoUri`: lists never load a full photo.
    let uri: String?
    /// 40, 48, 56, 76 or 88.
    var size: CGFloat = DesignMetrics.thumb
    /// The item screen only: opens the photo.
    var action: (() -> Void)?
    /// Required with an action: "Photo of Cordless drill".
    var accessibilityLabel: String?
    var identifier: String?

    @Environment(\.photoPathResolver) private var resolver
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: Loaded?

    /// The image and the request it answers, so a reused row never shows the last photo.
    private struct Loaded {
        let key: String
        let image: ThumbnailImage?
    }

    private var key: String { "\(uri ?? "")|\(Int(size * displayScale))" }

    var body: some View {
        if let action {
            Button(action: action) { picture }
                .buttonStyle(.plain)
                .frame(minWidth: DesignMetrics.minTouchTarget, minHeight: DesignMetrics.minTouchTarget)
                .contentShape(Rectangle())
                .accessibilityLabelIfPresent(accessibilityLabel)
                .accessibilityAddTraits(.isImage)
                .accessibilityIdentifierIfPresent(identifier)
        } else {
            picture
                .accessibilityHidden(true)
                .accessibilityIdentifierIfPresent(identifier)
        }
    }

    private var picture: some View {
        let shape = RoundedRectangle(cornerRadius: DesignMetrics.thumbRadius, style: .continuous)
        return ZStack {
            shape.fill(Color(uiColor: .tertiarySystemFill))
            Image(glyph: .photo)
                .font(.system(size: size > 56 ? 24 : 20))
                .foregroundStyle(.secondary)
            if let loaded, loaded.key == key, let image = loaded.image {
                Image(decorative: image.cgImage, scale: displayScale)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .task(id: key) { await load() }
    }

    private func load() async {
        ThumbnailMemoryRelief.install()
        let key = key
        guard let uri, let url = resolver.resolve(uri) else {
            loaded = Loaded(key: key, image: nil)
            return
        }
        let pixels = Int((size * displayScale).rounded(.up))
        let image = await ThumbnailLoader.shared.thumbnail(at: url, minimumPixelSize: pixels)
        guard !Task.isCancelled else { return }
        loaded = Loaded(key: key, image: image)
    }
}

/// Empties the thumbnail cache when the system runs low on memory; it refills as rows draw.
@MainActor
private enum ThumbnailMemoryRelief {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await ThumbnailLoader.shared.removeAll() }
        }
    }
}

#Preview("Thumbs") {
    HStack {
        Thumb(uri: nil, size: 40)
        Thumb(uri: nil, size: 48)
        Thumb(uri: "file:///missing.webp", size: 56)
        Thumb(uri: nil, size: 76)
        Thumb(uri: nil, size: 88, action: {}, accessibilityLabel: "Photo")
    }
    .padding()
}
