import Observation

/// True only after a condition has stayed true for a while, so fast reads never flash a
/// skeleton or spinner (RN `useDelayedFlag(active, ms = delay.skeleton)`,
/// src/hooks/useDelayedFlag.ts; 06 §16.2).
///
/// ``setActive(_:)`` with the condition whenever it may have changed. ``value`` turns true once
/// the condition has been true for ``delay`` without a break, and false the moment it is not.
/// Uses: skeletons (180 ms), the boot caption (400 ms, `Motion.delay.bootCaption`), Home's
/// older-results handover (420 and 600 ms) and its search skeleton (200 ms).
@MainActor
@Observable
public final class DelayedFlag {
    /// The condition held for ``delay``.
    public private(set) var value = false
    /// The condition as last set.
    public private(set) var isActive = false
    /// How long the condition has to hold.
    public let delay: Duration

    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var timer: Task<Void, Never>?

    /// - Parameters:
    ///   - delay: how long the condition has to hold; 180 ms (`Motion.delay.skeleton`) by default.
    ///   - clock: the timer's clock.
    public init(delay: Duration = .milliseconds(Motion.delay.skeleton), clock: any Clock<Duration> = ContinuousClock()) {
        self.delay = delay
        self.clock = clock
    }

    /// The condition now. Turning it on starts the wait (once); turning it off resets at once.
    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        timer?.cancel()
        timer = nil
        guard active else {
            value = false
            return
        }
        let delay = delay
        timer = Task { [weak self, clock] in
            do { try await clock.sleep(for: delay) } catch { return }
            self?.elapsed()
        }
    }

    private func elapsed() {
        timer = nil
        if isActive { value = true }
    }
}
