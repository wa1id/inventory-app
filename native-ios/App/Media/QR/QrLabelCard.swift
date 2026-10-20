import InventoryAppModels
import InventoryCore
import InventoryStrings
import SwiftUI

/// A QR code as a picture: black modules on white with a white quiet zone of `quietZone` points on
/// each side, `side` points across in all, scaled crisply (nearest neighbour) so the modules keep
/// hard edges (07 §5.4). Decorative on its own; the card around it carries the spoken label.
struct QrCodeImage: View {
    let payload: String
    let side: CGFloat
    let quietZone: CGFloat

    var body: some View {
        ZStack {
            MediaPalette.qrPaper
            if let modules = QrCodeRenderer.modules(for: payload) {
                Image(decorative: modules, scale: 1)
                    .interpolation(.none)
                    .antialiased(false)
                    .resizable()
                    .frame(width: max(0, side - 2 * quietZone), height: max(0, side - 2 * quietZone))
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// The label as it is printed (RN `QrCard`, 07 §5.2): the QR code over the container's name (only
/// when it has one) and its code on tape.
///
/// Always black on white, in dark mode too, because scanners need the contrast and a sticker is
/// printed on white; in dark mode the white card keeps a hairline edge so it sits with the other
/// sheets. On a narrow window the code shrinks instead of overflowing (``QrLabelGeometry``).
/// VoiceOver reads it as one image: "QR label for Tool chest, label C A B, J 9 2 R".
struct QrLabelCard: View {
    let token: String
    let name: String?
    let shortCode: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        let geometry = QrLabelGeometry.card(availableWidth: Double(availableWidth))
        card(codeSide: CGFloat(geometry.size))
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }

    /// The name, shown as stored, only when it is not blank (RN `name?.trim() ? name : null`).
    private var namedTitle: String? {
        guard let name, !name.jsTrimmed().isEmpty else { return nil }
        return name
    }

    private func card(codeSide: CGFloat) -> some View {
        VStack(spacing: 12) {
            QrCodeImage(payload: formatQrPayload(token), side: codeSide, quietZone: CGFloat(QrLabelGeometry.quietZone))
            if let namedTitle {
                Text(namedTitle)
                    .font(.title3.bold())
                    .foregroundStyle(MediaPalette.qrInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // RN `Tape size="l"`; decorative here, the card's label spells the code.
            Tape(code: shortCode, size: .large)
        }
        .padding(CGFloat(QrLabelGeometry.cardPadding))
        .background(MediaPalette.qrPaper, in: .rect(cornerRadius: 12))
        .environment(\.colorScheme, .light)
        .overlay {
            // Outside the card's forced light scheme, so the edge takes the dark separator.
            if colorScheme == .dark {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(.separator), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.Qr.cardA11y(
            label: ContainerRules.labelOf(name: name, shortCode: shortCode),
            spelled: spellCode(shortCode)
        ))
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("qr-card")
    }
}

#Preview("Card, named") {
    ScrollView {
        QrLabelCard(token: "0123456789abcdef0123456789abcdef", name: "Tool chest", shortCode: "CAB-J92R")
            .padding()
    }
    .background(Color(.systemGroupedBackground))
}

#Preview("Card, unnamed, dark") {
    ScrollView {
        QrLabelCard(token: "fedcba9876543210fedcba9876543210", name: nil, shortCode: "BOX-7K2M")
            .padding()
    }
    .background(Color(.systemGroupedBackground))
    .preferredColorScheme(.dark)
}
