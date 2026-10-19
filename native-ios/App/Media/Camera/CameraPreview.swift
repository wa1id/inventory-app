import InventoryAppModels
import InventoryStrings
import SwiftUI

/// The live camera picture, full-bleed and black behind, that runs the session while it is on
/// screen (05 §8.3: start and stop with the screen and the scene).
///
/// The session runs while the view is shown, `runs` is true (the screen's own condition: the
/// permission is granted, the scanner is active…) and the app is not in the background. With a
/// `focus` model, a tap focuses there and draws the 72 pt square (05 §8.2, DECISIONS U7).
///
/// Put the camera chrome over it; chrome that is only decoration must not take touches
/// (`allowsHitTesting(false)`), so a tap anywhere else still reaches the focus layer.
struct CameraPreview: View {
    let camera: CameraController
    var runs = true
    var focus: TapToFocusModel?

    @Environment(\.scenePhase) private var scenePhase
    @State private var isShown = false

    var body: some View {
        CameraPreviewLayerView(camera: camera)
            .overlay {
                if let focus {
                    CameraTapToFocusLayer(focus: focus) { point in
                        camera.focus(atLayerPoint: point)
                    }
                }
            }
            .background(Color.black)
            .onAppear { isShown = true }
            .onDisappear { isShown = false }
            .onChange(of: shouldRun, initial: true) { _, run in
                camera.setRunning(run)
            }
    }

    private var shouldRun: Bool {
        isShown && runs && scenePhase != .background
    }
}

/// `CameraPreviewUIView` in SwiftUI.
struct CameraPreviewLayerView: UIViewRepresentable {
    let camera: CameraController

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        camera.attach(view)
        return view
    }

    func updateUIView(_ view: CameraPreviewUIView, context: Context) {
        camera.attach(view)
    }
}

/// Tap to focus over the preview (RN `TapToFocusLayer`, 05 §8.2): a tap hands its point to
/// `onFocus` and draws the focus square in the camera accent for 700 ms.
///
/// For VoiceOver it is one button, "Focus camera" (`strings.capture.tapToFocus`), that focuses
/// at the centre of the picture.
struct CameraTapToFocusLayer: View {
    let focus: TapToFocusModel
    let onFocus: (CGPoint) -> Void

    @State private var size: CGSize = .zero

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                tap(at: location)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .overlay(alignment: .topLeading) {
                if let origin = focus.spotOrigin {
                    CameraFocusSquare()
                        .offset(x: origin.x, y: origin.y)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(L10n.Capture.tapToFocus)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                tap(at: CGPoint(x: size.width / 2, y: size.height / 2))
            }
            .accessibilityIdentifier("capture-tap-focus")
    }

    private func tap(at point: CGPoint) {
        focus.tap(at: point)
        onFocus(point)
    }
}

/// The fleeting square where the camera meters: 72 pt, a 2 pt edge in the camera accent (the
/// `Tape` yellow, also Camera.app's), radius 4. Decorative.
struct CameraFocusSquare: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(MediaPalette.tape, lineWidth: 2)
            .frame(width: TapToFocus.spotSize, height: TapToFocus.spotSize)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .accessibilityIdentifier("capture-focus-spot")
    }
}

#Preview("Focus square") {
    ZStack {
        Color.black
        CameraFocusSquare()
    }
}
