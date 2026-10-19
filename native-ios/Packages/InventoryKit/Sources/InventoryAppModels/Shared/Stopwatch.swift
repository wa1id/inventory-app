/// Elapsed time on an injected clock, for the models' timings: how long the database took to
/// open (`database_ready {durationMs}`), how long a toast has been on screen (the error hold)
/// and how much of its life is left when a finger pauses it, the connection's refresh throttles,
/// and how long a scanned label has been out of view.
///
/// RN read `Date.now()` for these; reading the injected clock instead lets tests drive them
/// with `ManualClock`, the same clock the timers sleep on.
struct Stopwatch: Sendable {
    private let read: @Sendable () -> Duration

    init(_ clock: any Clock<Duration>) {
        self = Self.make(clock)
    }

    private init(read: @escaping @Sendable () -> Duration) {
        self.read = read
    }

    private static func make(_ clock: some Clock<Duration>) -> Stopwatch {
        let origin = clock.now
        return Stopwatch { origin.duration(to: clock.now) }
    }

    /// Time since the stopwatch was made; only differences between two readings mean anything.
    var now: Duration { read() }

    /// Whole milliseconds, rounded down, as `Date.now() - startedAt` gives them.
    static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
