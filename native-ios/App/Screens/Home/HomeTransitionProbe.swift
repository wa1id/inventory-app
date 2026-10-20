import SwiftUI
import UIKit

/// Tells Home when the pop that revealed it has finished animating, so a search button pressed
/// on a screen pushed on Home's own stack focuses the field right after the pop instead of
/// after `HomeSearchFocus`'s 600 ms fallback (RN waited for the root stack's `transitionEnd`,
/// src/ui/searchFocus.ts:40-78; 06 §3.5).
///
/// The shell reports the end of a sheet's or cover's dismissal itself
/// (`Router.modalDismissalFinished()`); a pop on a tab's stack has no such report in SwiftUI.
/// While ``isWaiting`` is true, this view looks up the navigation controller it sits in and,
/// when a transition is running there, calls ``onTransitionEnd`` when it completes. With no
/// transition running it does nothing, and the fallback still applies.
struct HomeTransitionProbe: UIViewRepresentable {
    /// `HomeSearchFocus.isWaitingForTransition`.
    let isWaiting: Bool
    let onTransitionEnd: @MainActor () -> Void

    func makeUIView(context: Context) -> HomeTransitionProbeView {
        let view = HomeTransitionProbeView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: HomeTransitionProbeView, context: Context) {
        view.onTransitionEnd = onTransitionEnd
        view.setWaiting(isWaiting)
    }
}

/// The probe's view: it keeps a weak reference to its navigation controller while it is in a
/// window, since a screen covered by a pushed one is out of the window until the pop begins.
final class HomeTransitionProbeView: UIView {
    var onTransitionEnd: (@MainActor () -> Void)?
    private weak var navigationController: UINavigationController?
    private var isWaiting = false
    /// Bumped per wait, so a completion from an earlier wait never answers a later one.
    private var waitGeneration = 0

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, let found = Self.navigationController(from: self) { navigationController = found }
    }

    func setWaiting(_ waiting: Bool) {
        guard waiting != isWaiting else { return }
        isWaiting = waiting
        waitGeneration &+= 1
        guard waiting else { return }
        let generation = waitGeneration
        // The pop starts when SwiftUI applies the new path, after this update: look once it has.
        DispatchQueue.main.async { [weak self] in
            self?.attach(generation: generation, attemptsLeft: Self.attempts)
        }
    }

    /// How many times to look for the transition, `retryDelay` apart, before leaving it to the
    /// fallback: SwiftUI may apply the new path a moment after this view hears of the wait.
    private static let attempts = 6
    private static let retryDelay: DispatchTimeInterval = .milliseconds(30)

    private func attach(generation: Int, attemptsLeft: Int) {
        guard isWaiting, generation == waitGeneration else { return }
        if navigationController == nil { navigationController = Self.navigationController(from: self) }
        guard let coordinator = navigationController?.transitionCoordinator else {
            guard attemptsLeft > 1 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
                self?.attach(generation: generation, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard let self, !context.isCancelled, self.isWaiting, generation == self.waitGeneration else { return }
            self.onTransitionEnd?()
        }
    }

    /// The navigation controller of the view controller that hosts `view`.
    static func navigationController(from view: UIView) -> UINavigationController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController {
                if let navigation = controller as? UINavigationController { return navigation }
                if let navigation = controller.navigationController { return navigation }
            }
            responder = current.next
        }
        return nil
    }
}
