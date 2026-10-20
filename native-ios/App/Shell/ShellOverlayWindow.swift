import Observation
import SwiftUI
import UIKit
import InventoryAppModels

/// A window above sheets and covers that lets touches through everywhere except the toast card,
/// and captures every touch while the removed-phone layer shows (D-8; 09 §7.7, 06 §2.2). It never
/// becomes key, so the keyboard and the dialogs stay with the app's window.
final class ShellOverlayWindow: UIWindow {
    /// The removed-phone layer is up: every touch lands here.
    var capturesAllTouches = false
    /// The toast card's frame in window coordinates; touches inside it land here.
    var touchableFrame: () -> CGRect? = { nil }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        if capturesAllTouches { return hit }
        if let frame = touchableFrame(), frame.contains(point) { return hit }
        return nil
    }

    override var canBecomeKey: Bool { false }
}

/// Hosts the overlay content. Its status bar follows the app's window, so a toast over the
/// camera never brings the status bar back.
final class ShellOverlayHostingController<Content: View>: UIHostingController<Content> {
    private var appTop: UIViewController? {
        var top = ShellDialogPresenter.topViewController()
        while let child = top?.childForStatusBarStyle { top = child }
        return top
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { appTop?.preferredStatusBarStyle ?? .default }
    override var prefersStatusBarHidden: Bool { appTop?.prefersStatusBarHidden ?? false }
}

/// Installs the overlay window once the gate has passed and keeps it showing only while there is
/// something to show (a toast, the removed-phone layer); hidden, it can change nothing.
@MainActor
final class ShellOverlayController {
    let state = ShellOverlayState()
    private let app: AppContainer
    private(set) var window: ShellOverlayWindow?

    init(app: AppContainer) {
        self.app = app
    }

    /// Creates the window on `scene`, once.
    func install(on scene: UIWindowScene) {
        guard window == nil else { return }
        let window = ShellOverlayWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let host = ShellOverlayHostingController(rootView: ShellOverlayRoot(app: app, state: state))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        let state = state
        window.touchableFrame = { state.cardFrame }
        window.isHidden = true
        self.window = window
        follow()
    }

    /// Re-applies ``update()`` whenever the toast or the connection state changes.
    private func follow() {
        update()
        withObservationTracking {
            _ = app.toasts.current
            _ = app.connection.state
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    private func update() {
        guard let window else { return }
        let revoked = app.connection.state == .revoked
        window.capturesAllTouches = revoked
        window.rootViewController?.view.accessibilityViewIsModal = revoked
        window.isHidden = !(revoked || app.toasts.current != nil)
    }
}

/// The overlay's content: the toast, and the removed-phone layer over everything.
struct ShellOverlayRoot: View {
    let app: AppContainer
    let state: ShellOverlayState

    var body: some View {
        ZStack {
            ToastHost(toasts: app.toasts, overlay: state)
            if app.connection.state == .revoked {
                RevokedOverlay()
                    .transition(.opacity)
            }
        }
        .shellEnvironment(app)
    }
}

/// Reports the window scene the view lands in (the overlay window goes on the same scene).
struct ShellWindowSceneReader: UIViewRepresentable {
    let onScene: @MainActor (UIWindowScene) -> Void

    func makeUIView(context: Context) -> ShellSceneProbeView {
        let view = ShellSceneProbeView()
        view.onScene = onScene
        return view
    }

    func updateUIView(_ view: ShellSceneProbeView, context: Context) {
        view.onScene = onScene
    }
}

final class ShellSceneProbeView: UIView {
    var onScene: (@MainActor (UIWindowScene) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let scene = window?.windowScene { onScene?(scene) }
    }
}
