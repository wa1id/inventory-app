import InventoryAppModels
import InventoryCore
import InventoryStrings
import SwiftUI

// The capture screen's chrome (RN src/ui/capture/CameraChrome.tsx, 05 §4.10): everything drawn
// over the live picture, white on glass in either colour scheme. Decorative pieces never take a
// touch, so a tap anywhere else still reaches the focus layer under them.

/// The width of the shutter row's side slots (RN `SIDE_SLOT`, the minimum touch target).
private let captureSideSlot = DesignMetrics.minTouchTarget

/// Where the photos will go, at the top of the camera: "Into the drop zone", or the container's
/// location line ("● Garage › Tool chest [CAB-J92R]"). The screen shows it for the drop zone at
/// once and for a container only once its place has loaded, never a wrong guess. One element,
/// spoken as `CaptureFlow.intoA11y`.
struct CaptureIntoPill: View {
    let place: CaptureIntoPlace?
    let accessibilityLabel: String

    var body: some View {
        Group {
            if let place {
                // The location line's inline form (pip, "Space › Container", tape) as a plain
                // HStack: the shared `LocationLine` flows its pieces with a custom layout, which
                // over the camera measured one line while drawing two, so the glass did not fit.
                HStack(spacing: 6) {
                    SpacePip(color: place.spaceColor, size: 10)
                    Text(verbatim: place.pillLine)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Tape(code: place.containerShortCode, size: .small)
                }
                .textRole(.meta)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minHeight: 36)
                // Rounded rather than a capsule: the names may take two lines.
                .glassEffect(.regular.tint(MediaPalette.glassTint), in: .rect(cornerRadius: 18))
                // RN's `meta` text stops at 2× (AX1) on the camera.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .accessibilityElement(children: .ignore)
            } else {
                CameraTitlePill(text: L10n.Capture.into, systemImage: Glyph.inbox.systemName)
            }
        }
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("capture-into")
        .allowsHitTesting(false)
    }
}

/// The shutter: a 3 pt white ring around a white disc, 76 pt across (RN `Shutter`). Busy (single
/// mode saving its photo) spins and takes no press; dimmed (fast mode while the camera still
/// takes the last shot) fades, so an ignored tap shows.
struct CaptureShutter: View {
    var isBusy = false
    var isDimmed = false
    /// The session runs; a press before that would only fail (05 §4.4).
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Color.clear
        }
        .buttonStyle(CaptureShutterStyle(isBusy: isBusy))
        .disabled(isBusy || !isEnabled)
        .opacity(isDimmed ? 0.5 : 1)
        .accessibilityLabel(Text(L10n.Capture.takePhoto))
        .accessibilityIdentifier("capture-shutter")
    }
}

private struct CaptureShutterStyle: ButtonStyle {
    let isBusy: Bool

    static let side: CGFloat = 76
    static let disc: CGFloat = 62

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white, lineWidth: 3)
            Circle()
                .fill(Color.white)
                .frame(width: Self.disc, height: Self.disc)
                .scaleEffect(configuration.isPressed && !isBusy ? 0.92 : 1)
            if isBusy {
                ProgressView()
                    .tint(.black)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .contentShape(Circle())
        .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// A brief white flash each time a fast shot comes back (RN `ShutterFlash`): 0 → 0.5 → 0 over
/// 120 ms, so a shot that landed is seen as well as felt. Skipped under Reduce Motion.
struct CaptureShutterFlash: View {
    /// Changes with every shot that landed (`CaptureModel.shotSerial`).
    let trigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opacity = 0.0

    var body: some View {
        Color.white
            .opacity(opacity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: trigger) {
                let half = Motion.duration(reduceMotion: reduceMotion).shutterFlash / 2
                guard half > 0 else { return }
                opacity = 0
                withAnimation(.linear(duration: Double(half) / 1000)) {
                    opacity = 0.5
                } completion: {
                    withAnimation(.shellCurve(Motion.Easing.out, ms: half)) { opacity = 0 }
                }
            }
    }
}

/// Corner guides showing how much of the frame the item should fill (RN `Reticle`): inset 22 %
/// from the top, 28 % from the bottom and 10 % from each side, 40 pt arms, 3 pt strokes, white at
/// 85 %. Framing guidance only: the photo is not cropped to it.
struct CaptureReticle: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ScannerReticleCorners(arm: 40, inset: 1.5)
                .stroke(MediaPalette.reticle, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .frame(width: size.width * 0.8, height: size.height * 0.5)
                .offset(x: size.width * 0.1, y: size.height * 0.22)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The newest photo of a fast set as a small tile with the running count on tape, so each shot
/// visibly lands (RN `LastShot`). Decorative: the status pill says the same in words. Nothing but
/// its room before the first shot.
struct CaptureLastShotTile: View {
    let photo: CapturedPhoto?
    /// `CaptureModel.shotSerial`: a new shot to draw.
    let serial: Int
    let count: Int

    @State private var image: ThumbnailImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if photo != nil {
                Group {
                    if let image {
                        Image(decorative: image.cgImage, scale: 1)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.white.opacity(0.25)
                    }
                }
                .frame(width: captureSideSlot, height: captureSideSlot)
                .clipShape(.rect(cornerRadius: DesignMetrics.thumbRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: DesignMetrics.thumbRadius)
                        .strokeBorder(Color.white, lineWidth: 2)
                }
                if count > 0 {
                    Tape(code: String(count), size: .badge)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .fixedSize()
                        .offset(x: 6, y: -6)
                }
            }
        }
        .frame(width: captureSideSlot, height: captureSideSlot)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .accessibilityIdentifier("capture-last-shot")
        .task(id: serial) {
            guard let data = photo?.data else {
                image = nil
                return
            }
            let decoded = await Task.detached(priority: .userInitiated) {
                CaptureShotThumbnail.decode(data)
            }.value
            if !Task.isCancelled { image = decoded }
        }
    }
}

/// Ends a fast set: "Done · 4", the count in the camera accent (RN `DoneButton`). Dimmed until
/// the first shot, when it simply closes the camera.
struct CaptureDoneButton: View {
    let count: Int
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            label
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(minWidth: 96, minHeight: captureSideSlot)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(MediaPalette.glassTint).interactive(), in: .capsule)
        .opacity(count > 0 ? 1 : 0.55)
        // The shutter row has fixed slots; the count stays readable through the large content
        // viewer above AX1.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .accessibilityShowsLargeContentViewer {
            Text(verbatim: accessibilityLabel)
        }
        .accessibilityIdentifier("capture-done")
    }

    private var label: Text {
        guard count > 0 else { return Text(L10n.Capture.done) }
        // Bold, so the accent count reads as large text over any scene (RN: 3.8 : 1 at worst).
        let tally = Text(verbatim: " · \(count)").foregroundStyle(MediaPalette.tape).bold().monospacedDigit()
        return Text("\(Text(L10n.Capture.done))\(tally)")
    }
}

/// Keeps the shutter centred when one side has nothing to show (RN `SideSpacer`).
struct CaptureSideSpacer: View {
    var body: some View {
        Color.clear
            .frame(width: captureSideSlot, height: captureSideSlot)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
