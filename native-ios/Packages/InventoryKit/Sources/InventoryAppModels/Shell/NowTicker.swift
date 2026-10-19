import InventoryCore
import Observation

/// The current time for copy that ages ("Last backup 5 minutes ago", "Added just now"),
/// ticking only while the screen is focused (RN `useNow(intervalMs = 60_000)`,
/// src/hooks/useNow.ts; 06 §16.3).
///
/// A screen in the background does not tick; when it is focused again it catches up at once,
/// then ticks every ``interval``. ``now`` is epoch milliseconds, the unit `Format.ago` takes.
@MainActor
@Observable
public final class NowTicker {
    /// Epoch milliseconds (JS `Date.now()`), as of the last tick.
    public private(set) var now: Int64
    /// Whether the screen is focused, as last reported.
    public private(set) var isFocused = false
    public let interval: Duration

    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let currentTime: @Sendable () -> Int64
    @ObservationIgnored private var ticking: Task<Void, Never>?

    /// - Parameters:
    ///   - interval: between ticks; a minute by default.
    ///   - clock: the ticks' clock.
    ///   - currentTime: the wall clock in epoch milliseconds.
    public init(
        interval: Duration = .seconds(60),
        clock: any Clock<Duration> = ContinuousClock(),
        currentTime: @escaping @Sendable () -> Int64 = { epochMillis() }
    ) {
        self.interval = interval
        self.clock = clock
        self.currentTime = currentTime
        now = currentTime()
    }

    /// The screen gained or lost focus: tick now and keep ticking, or stop.
    public func focusChanged(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        ticking?.cancel()
        ticking = nil
        guard focused else { return }
        now = currentTime()
        let interval = interval
        ticking = Task { [weak self, clock] in
            while true {
                do { try await clock.sleep(for: interval) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.now = self.currentTime()
            }
        }
    }
}
