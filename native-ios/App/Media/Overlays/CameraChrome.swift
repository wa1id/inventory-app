import InventoryAppModels
import InventoryStrings
import SwiftUI

/// The few colours the camera and the QR label keep (DECISIONS U2, 08 §4.5). Camera chrome ignores
/// the colour scheme: it sits on a live picture, white on glass.
enum MediaPalette {
    /// The label-tape yellow from the asset catalog: the camera accent (focus square, locked
    /// reticle, a toggle that is on) and the code tape. Never a text or control tint.
    static let tape = Color("Tape")
    /// Ink on the tape (`#1D1A0E`, RN `tapeInk`), in both schemes.
    static let tapeInk = Color(red: 0x1D / 255, green: 0x1A / 255, blue: 0x0E / 255)
    /// The error edge of a camera notice (`#FF9573`, RN `camera.errorBar`): coral text over a bright
    /// scene measures 2.5:1, so errors get this bar instead (08 §4.5).
    static let errorBar = Color(red: 1, green: 0x95 / 255, blue: 0x73 / 255)
    /// The scanner's reticle while it looks (white at 85 %, RN `camera.reticle`).
    static let reticle = Color.white.opacity(0.85)
    /// A dark tint under the glass so white text stays readable over a bright scene (RN drew a
    /// 62 % dark chip).
    static let glassTint = Color.black.opacity(0.35)
    /// The QR label is black on white in both schemes, so every scanner reads it (08 §4.5).
    static let qrInk = Color.black
    static let qrPaper = Color.white
}

/// A round glass button over the camera picture (RN `IconButton variant="camera"`): a 48 pt
/// target with a white glyph, or the camera accent while a toggle is on (announced as selected).
struct CameraGlassIconButton: View {
    let systemImage: String
    let label: String
    /// A toggle's state (torch, flash); nil for a plain button.
    var isSelected: Bool?
    var identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(isSelected == true ? MediaPalette.tape : Color.white)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(MediaPalette.glassTint).interactive(), in: .circle)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected == true ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            Label(label, systemImage: systemImage)
        }
        .accessibilityIdentifier(identifier)
    }
}

/// White text on a glass capsule over the camera (RN `StatusPill`): the scanner's title, the
/// capture screen's running count. Two lines at most.
struct CameraTitlePill: View {
    let text: String
    var systemImage: String?
    /// A running count (RN `live`): VoiceOver treats it as updating frequently.
    var updatesFrequently = false
    var identifier: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
            Text(text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 36)
        .glassEffect(.regular.tint(MediaPalette.glassTint), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(updatesFrequently ? .updatesFrequently : [])
        .accessibilityIdentifier(identifier ?? "camera-pill")
    }
}

/// Four corner brackets around where the label should go (RN `QrScanner` `Reticle`): 240 pt,
/// 40 pt arms, 3 pt strokes, white while looking and the camera accent once a code is locked.
/// Decorative: hidden from VoiceOver and never takes a touch.
struct ScannerReticle: View {
    var isLocked: Bool

    static let side: CGFloat = 240
    static let arm: CGFloat = 40
    static let thickness: CGFloat = 3

    var body: some View {
        ScannerReticleCorners(arm: Self.arm, inset: Self.thickness / 2)
            .stroke(
                isLocked ? MediaPalette.tape : MediaPalette.reticle,
                style: StrokeStyle(lineWidth: Self.thickness, lineCap: .round, lineJoin: .round)
            )
            .frame(width: Self.side, height: Self.side)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The reticle's four L-shaped corners.
struct ScannerReticleCorners: Shape {
    var arm: CGFloat
    var inset: CGFloat

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: inset)
        let reach = max(0, arm - inset)
        var path = Path()
        // Top-left, top-right, bottom-right, bottom-left: down/up the side, then along the edge.
        path.move(to: CGPoint(x: box.minX, y: box.minY + reach))
        path.addLine(to: CGPoint(x: box.minX, y: box.minY))
        path.addLine(to: CGPoint(x: box.minX + reach, y: box.minY))
        path.move(to: CGPoint(x: box.maxX - reach, y: box.minY))
        path.addLine(to: CGPoint(x: box.maxX, y: box.minY))
        path.addLine(to: CGPoint(x: box.maxX, y: box.minY + reach))
        path.move(to: CGPoint(x: box.maxX, y: box.maxY - reach))
        path.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
        path.addLine(to: CGPoint(x: box.maxX - reach, y: box.maxY))
        path.move(to: CGPoint(x: box.minX + reach, y: box.maxY))
        path.addLine(to: CGPoint(x: box.minX, y: box.maxY))
        path.addLine(to: CGPoint(x: box.minX, y: box.maxY - reach))
        return path
    }
}

/// A button on a camera notice (RN `CameraButton` / the camera-styled secondary button).
struct CameraPanelAction: Identifiable {
    /// Also the accessibility identifier (RN testID), e.g. `scan-type-code`.
    let id: String
    let label: String
    var systemImage: String?
    let perform: () -> Void
}

/// A notice over the bottom of the camera picture (RN `ScanPanel`, the sticker-link `Panel`, the
/// scanner's failure panel; 06 §8.2, §15.1): white words on glass, a spinner while busy, and the
/// coral error edge for errors.
///
/// Error and busy notices are announced to VoiceOver when they appear and whenever their words
/// change, as `"<title>. <message>"`; the standing hint is not news and is not announced.
struct CameraPanel: View {
    enum Tone: Hashable {
        /// The standing hint: no announcement.
        case hint
        /// Something is under way: a spinner.
        case busy
        /// Something went wrong: the error edge.
        case error
    }

    let tone: Tone
    var title: String?
    let message: String
    var actions: [CameraPanelAction] = []

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// What VoiceOver hears when the panel appears (nil for the hint).
    var announcement: String? {
        guard tone != .hint else { return nil }
        return title.map { "\($0). \(message)" } ?? message
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                if tone == .busy {
                    ProgressView()
                        .tint(.white)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let title {
                        Text(title)
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Text(message)
                        .font(.body)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !actions.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { buttons }
                    VStack(alignment: .leading, spacing: 8) { buttons }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .padding(.leading, tone == .error ? 4 : 0)
        .frame(maxWidth: 640, alignment: .leading)
        .background(alignment: .leading) {
            if tone == .error {
                Rectangle()
                    .fill(MediaPalette.errorBar)
                    .frame(width: 4)
            }
        }
        .clipShape(.rect(cornerRadius: 20))
        .glassEffect(.regular.tint(MediaPalette.glassTint), in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .onAppear(perform: announce)
        .onChange(of: announcement) { announce() }
    }

    @ViewBuilder private var buttons: some View {
        ForEach(actions) { action in
            Button(action: action.perform) {
                Group {
                    if let systemImage = action.systemImage {
                        Label(action.label, systemImage: systemImage)
                    } else {
                        Text(action.label)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.bordered)
            // A capsule around a label that wraps to three lines at the largest sizes is an oval.
            .buttonBorderShape(dynamicTypeSize.isAccessibilitySize ? .roundedRectangle : .automatic)
            .tint(.white)
            .accessibilityIdentifier(action.id)
        }
    }

    private func announce() {
        guard let announcement else { return }
        AccessibilityNotification.Announcement(announcement).post()
    }
}

extension CameraPanel {
    /// The Scan tab's footer from `ScanModel.panel` (06 §8.2): Scan again (`scan-again`), Try again
    /// with the refresh glyph (`scan-try-again`), Type a code with the keyboard glyph
    /// (`scan-type-code`).
    init(_ panel: ScanPanel, perform: @escaping (ScanPanelAction) -> Void) {
        let tone: Tone = switch panel.tone {
        case .hint: .hint
        case .busy: .busy
        case .error: .error
        }
        self.init(
            tone: tone,
            title: panel.title,
            message: panel.message,
            actions: panel.actions.map { action in
                switch action {
                case .scanAgain:
                    CameraPanelAction(id: "scan-again", label: action.label) { perform(action) }
                case .tryAgain:
                    CameraPanelAction(id: "scan-try-again", label: action.label, systemImage: "arrow.clockwise") { perform(action) }
                case .typeCode:
                    CameraPanelAction(id: "scan-type-code", label: action.label, systemImage: "keyboard") { perform(action) }
                }
            }
        )
    }
}

#Preview("Camera chrome") {
    ZStack {
        LinearGradient(colors: [.white, .gray, .black], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        ScannerReticle(isLocked: false)
        VStack(spacing: 16) {
            HStack {
                CameraGlassIconButton(systemImage: "xmark", label: L10n.Camera.close, identifier: "close") {}
                CameraTitlePill(text: L10n.Scan.title)
                    .frame(maxWidth: .infinity)
                CameraGlassIconButton(systemImage: "flashlight.on.fill", label: L10n.Camera.torchState(on: true), isSelected: true, identifier: "torch") {}
            }
            Spacer()
            CameraPanel(tone: .error, title: L10n.Scan.invalidTitle, message: L10n.Scan.invalidBody, actions: [
                CameraPanelAction(id: "again", label: L10n.Scan.scanAgain) {},
                CameraPanelAction(id: "type", label: L10n.Scan.typeCode, systemImage: "keyboard") {},
            ])
        }
        .padding()
    }
    .environment(\.colorScheme, .dark)
}
