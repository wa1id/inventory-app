import SwiftUI
import Testing
import UIKit
@testable import Inventory
import InventoryAppModels

/// Hosts a SwiftUI view in a window of its own on the test host's scene, for the shell's
/// app-hosted tests. Names carry the Shell prefix.
@MainActor
final class ShellTestWindow {
    let window: UIWindow

    init<Content: View>(_ content: Content) throws {
        let scene = try #require(ShellTestWindow.scene)
        window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: content)
        window.frame = scene.coordinateSpace.bounds
        window.isHidden = false
    }

    func close() {
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }

    static var scene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
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
