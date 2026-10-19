/// Elapsed time on an injected clock, for the shell's timings: how long the database took to
/// open (`database_ready {durationMs}`), how long a toast has been on screen (the error hold)
/// and how much of its life is left when a finger pauses it.
///
/// RN read `Date.now()` for these; reading the injected clock instead lets tests drive them
/// with `ManualClock`, the same clock the timers sleep on.
struct ShellStopwatch: Sendable {
    private let read: @Sendable () -> Duration

    init(_ clock: any Clock<Duration>) {
        self = Self.make(clock)
    }

    private init(read: @escaping @Sendable () -> Duration) {
        self.read = read
    }

    private static func make(_ clock: some Clock<Duration>) -> ShellStopwatch {
        let origin = clock.now
        return ShellStopwatch { origin.duration(to: clock.now) }
    }

    /// Time since the stopwatch was made; only differences between two readings mean anything.
    var now: Duration { read() }

    /// Whole milliseconds, rounded down, as `Date.now() - startedAt` gives them.
    static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
