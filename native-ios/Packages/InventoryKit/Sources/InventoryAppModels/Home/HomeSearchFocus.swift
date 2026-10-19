import Observation

/// The one-shot request for Home to focus its search field, from the search buttons on other
/// screens (RN src/ui/searchFocus.ts; 06 §3.5).
///
/// One request is held at a time, and a later one replaces it. Home consumes it each time it
/// gains focus (``homeFocusChanged(_:)``): without `afterTransition` it focuses at once; with it,
/// it waits until the screens being closed have finished animating away
/// (``transitionEnded()``, from the sheet's `onDismiss` or the end of the pop) or
/// ``transitionFallback`` (600 ms), whichever comes first, and gives up if Home loses focus
/// first, since focusing during a transition makes the keyboard fight the animation. It is a
/// one-shot flag rather than a route parameter, so the keyboard does not come back on every
/// later visit.
///
/// Home observes ``focusRequests`` and sets its `.searchable(isPresented:)` to true whenever
/// it goes up.
@MainActor
@Observable
public final class HomeSearchFocus {
    /// RN `SearchFocusRequest`.
    public struct Request: Sendable, Hashable {
        /// Screens are being closed on the way to Home.
        public var afterTransition: Bool

        public init(afterTransition: Bool) {
            self.afterTransition = afterTransition
        }
    }

    /// The longest a closing animation is waited for (RN `TRANSITION_FALLBACK_MS`).
    public nonisolated static let transitionFallback: Duration = .milliseconds(600)

    /// The request waiting for Home to gain focus.
    public private(set) var pending: Request?
    /// Bumped each time Home should focus its field now.
    public private(set) var focusRequests = 0
    /// A consumed request is waiting for the closing transition.
    public private(set) var isWaitingForTransition = false

    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var fallback: Task<Void, Never>?

    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// Asks Home to focus its field the next time it gains focus (RN `requestSearchFocus`).
    /// Pass `afterTransition` when screens are being closed to get there.
    public func request(afterTransition: Bool = false) {
        pending = Request(afterTransition: afterTransition)
    }

    /// Takes the pending request, if any; a request is only ever answered once.
    public func consume() -> Request? {
        defer { pending = nil }
        return pending
    }

    /// Home gained or lost focus.
    public func homeFocusChanged(_ focused: Bool) {
        guard focused else {
            stopWaiting()
            return
        }
        guard let taken = consume() else { return }
        guard taken.afterTransition else {
            focusNow()
            return
        }
        stopWaiting()
        isWaitingForTransition = true
        fallback = Task { [weak self, clock] in
            do { try await clock.sleep(for: Self.transitionFallback) } catch { return }
            guard !Task.isCancelled else { return }
            self?.transitionEnded()
        }
    }

    /// The closing transition that revealed Home has finished.
    public func transitionEnded() {
        guard isWaitingForTransition else { return }
        focusNow()
    }

    private func focusNow() {
        stopWaiting()
        focusRequests += 1
    }

    private func stopWaiting() {
        fallback?.cancel()
        fallback = nil
        isWaitingForTransition = false
    }
}
