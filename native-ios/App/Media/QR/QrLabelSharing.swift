import InventoryAppModels
import InventoryCore
import InventoryStrings
import SwiftUI
import UIKit

/// Why the label picture could not be made.
enum QrLabelPictureError: Error, Equatable {
    case renderFailed
}

/// The picture the label's share sheet carries (RN `writeLabelPicture`, 07 §5.3): only the QR code
/// with its white quiet zone, 1024 × 1024 px, sharp enough to print a label a few centimetres wide.
/// The name and the code tape stay on screen only, as in RN (07 Q7; DECISIONS U10, no whole-card
/// picture in v1). The margin keeps the on-screen card's ratio (`16 / size`, about 65 px), since
/// RN's picture was a snapshot of the card's drawing (07 Q6 parity).
@MainActor
enum QrLabelPicture {
    /// The picture, rendered with `ImageRenderer` at one pixel per point.
    static func render(payload: String, cardSize: Double) -> CGImage? {
        let pixels = CGFloat(QrLabelGeometry.picturePixels)
        let margin = CGFloat(QrLabelGeometry.pictureMargin(cardSize: cardSize))
        let renderer = ImageRenderer(content: QrCodeImage(payload: payload, side: pixels, quietZone: margin))
        renderer.scale = 1
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(width: pixels, height: pixels)
        return renderer.cgImage
    }

    /// The picture as PNG bytes.
    static func pngData(payload: String, cardSize: Double) -> Data? {
        render(payload: payload, cardSize: cardSize).flatMap { UIImage(cgImage: $0).pngData() }
    }

    /// Writes the picture to `<directory>/label-<code>.png`, replacing the one from the last share
    /// (the system clears the temporary directory as it likes; the first native launch purges
    /// RN's `Caches/label-*.png`, DECISIONS U11).
    static func write(
        payload: String,
        shortCode: String,
        cardSize: Double,
        in directory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        guard let data = pngData(payload: payload, cardSize: cardSize) else { throw QrLabelPictureError.renderFailed }
        let url = directory.appending(path: QrLabelPictureFile.name(shortCode: shortCode), directoryHint: .notDirectory)
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// "Share label…" (RN `qr.tsx` `shareLabel`, 07 §5.3-5.4): the system share sheet with the label
/// picture and "<label> (<code>)", so it offers Save Image and Print (DECISIONS D-10). When the
/// picture cannot be made, the label and its `inventory://c/…` link go as text instead, as RN
/// fell back. Drawn full width, at the same gutters as the card, whose size the picture follows.
struct QrLabelShareLink: View {
    let token: String
    let name: String?
    let shortCode: String

    @State private var availableWidth: CGFloat = 0
    @State private var picture: Prepared?

    private struct Prepared: Equatable {
        let key: String
        let url: URL
        let preview: UIImage
    }

    private var payload: String { formatQrPayload(token) }

    private var cardSize: Double {
        QrLabelGeometry.card(availableWidth: Double(availableWidth)).size
    }

    /// What the picture depends on. Whether the width is known yet is part of it: on a window so
    /// narrow that the measured card is the same as the unmeasured default, the key would otherwise
    /// never change after the first (skipped) pass and the picture would never be made.
    private var key: String { "\(token)|\(shortCode)|\(cardSize)|\(availableWidth > 0)" }

    var body: some View {
        Group {
            if let picture, picture.key == key {
                ShareLink(
                    item: picture.url,
                    message: Text(ContainerRules.shareText(name: name, shortCode: shortCode, payload: payload, withPayload: false)),
                    preview: SharePreview(
                        ContainerRules.labelOf(name: name, shortCode: shortCode),
                        image: Image(uiImage: picture.preview)
                    )
                ) {
                    label
                }
            } else {
                ShareLink(item: ContainerRules.shareText(name: name, shortCode: shortCode, payload: payload, withPayload: true)) {
                    label
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityIdentifier("qr-share")
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .task(id: key) {
            guard availableWidth > 0 else { return }
            prepare()
        }
    }

    private var label: some View {
        Label(L10n.Qr.share, systemImage: "square.and.arrow.up")
            .frame(maxWidth: .infinity)
    }

    private func prepare() {
        do {
            let url = try QrLabelPicture.write(payload: payload, shortCode: shortCode, cardSize: cardSize)
            guard let preview = UIImage(contentsOfFile: url.path(percentEncoded: false)) else { return }
            picture = Prepared(key: key, url: url, preview: preview)
        } catch {
            // The text share still works.
            MediaLog.camera.error("label picture failed")
            picture = nil
        }
    }
}

#Preview("Share label") {
    VStack(spacing: 24) {
        QrLabelCard(token: "0123456789abcdef0123456789abcdef", name: "Tool chest", shortCode: "CAB-J92R")
        QrLabelShareLink(token: "0123456789abcdef0123456789abcdef", name: "Tool chest", shortCode: "CAB-J92R")
    }
    .padding()
}
