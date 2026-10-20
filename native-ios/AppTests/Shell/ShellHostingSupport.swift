import SwiftUI
import Testing
import UIKit
@testable import Inventory
import InventoryAppModels

/// Hosts a SwiftUI view in a window of its own on the test host's scene, for the shell's
/// app-hosted tests. Names carry the Shell prefix.
///
/// The view sees the scene's real phase (`\.scenePhase`, active while the tests run): SwiftUI only
/// sets it for its own scenes, so a bare hosting controller would report `.background` and the
/// cameras would never start.
@MainActor
final class ShellTestWindow {
    let window: UIWindow
    private let phase: ShellTestScenePhase

    /// - Parameters:
    ///   - size: the window's size; the whole scene by default.
    ///   - horizontalSizeClass: overrides the size class the view sees (a compact window on an
    ///     iPad, as in Split View or Slide Over).
    init<Content: View>(
        _ content: Content,
        size: CGSize? = nil,
        horizontalSizeClass: UIUserInterfaceSizeClass? = nil
    ) throws {
        let scene = try #require(ShellTestWindow.scene)
        let phase = ShellTestScenePhase(scene: scene)
        self.phase = phase
        window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ShellTestScenePhaseHost(phase: phase, content: content))
        if let horizontalSizeClass { host.traitOverrides.horizontalSizeClass = horizontalSizeClass }
        window.rootViewController = host
        let bounds = scene.effectiveGeometry.coordinateSpace.bounds
        window.frame = size.map { CGRect(origin: .zero, size: $0) } ?? bounds
        window.isHidden = false
    }

    func close() {
        phase.stop()
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }

    static var scene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

/// The phase of the scene a test window is on, following its activation.
@MainActor
@Observable
final class ShellTestScenePhase {
    private(set) var phase: ScenePhase
    @ObservationIgnored private weak var scene: UIScene?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(scene: UIScene) {
        self.scene = scene
        phase = Self.phase(of: scene.activationState)
        let names = [
            UIScene.willEnterForegroundNotification, UIScene.didActivateNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sceneChanged() }
            }
        }
    }

    private func sceneChanged() {
        guard let scene else { return }
        phase = Self.phase(of: scene.activationState)
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    static func phase(of state: UIScene.ActivationState) -> ScenePhase {
        switch state {
        case .foregroundActive: .active
        case .foregroundInactive: .inactive
        case .background, .unattached: .background
        @unknown default: .inactive
        }
    }
}

private struct ShellTestScenePhaseHost<Content: View>: View {
    let phase: ShellTestScenePhase
    let content: Content

    var body: some View {
        content.environment(\.scenePhase, phase.phase)
    }
}

enum ShellTestWait {
    /// Polls `condition` on the main actor, letting UIKit and SwiftUI run, until it holds.
    @MainActor
    static func until(
        _ description: String,
        timeout: Duration = .seconds(10),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now > deadline {
                Issue.record("timed out waiting for \(description)", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

extension UIView {
    /// Every descendant, depth first.
    var shellDescendants: [UIView] {
        subviews.flatMap { [$0] + $0.shellDescendants }
    }
}
