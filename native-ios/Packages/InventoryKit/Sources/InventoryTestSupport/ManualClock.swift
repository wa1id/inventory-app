import Synchronization

/// A `Clock<Duration>` that only moves when a test moves it.
///
/// Inject it wherever production code takes `any Clock<Duration>` (timers are Tasks that
/// `try await clock.sleep(for:)`), then drive time from the test:
///
/// ```swift
/// let clock = ManualClock()
/// let model = ConnectionModel(..., clock: clock)
/// model.start()                          // arms a 2.5 s retry
/// try await clock.waitForSleepers()      // the retry Task is now asleep on the clock
/// await clock.advance(by: .milliseconds(2500))
/// #expect(model.attempts == 2)
/// ```
///
/// - Sleepers wake in deadline order (ties in the order they went to sleep), one at a time:
///   ``advance(by:)`` wakes one, lets it run to its next suspension point, then wakes the
///   next, so their effects land in that order and a loop that sleeps again inside the window
///   fires as often as it would in real time.
/// - A sleep whose deadline has already passed returns at once, as on a real clock.
/// - Cancelling a sleeping task wakes it with `CancellationError` and forgets the sleeper.
/// - ``waitForSleepers(_:timeout:)`` suspends until that many sleepers are registered, so a
///   test never races the Task it just started; it fails after a real-time timeout rather
///   than hanging the run.
public final class ManualClock: Clock, Sendable {
    public struct Instant: InstantProtocol, CustomStringConvertible {
        /// Time since the clock's origin.
        public var offset: Duration

        public init(offset: Duration) {
            self.offset = offset
        }

        public func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }

        public var description: String { "ManualClock+\(offset)" }
    }

    /// ``waitForSleepers(_:timeout:)`` gave up.
    public struct Timeout: Error, CustomStringConvertible {
        public let expected: Int
        public let pending: Int
        public let timeout: Duration

        public var description: String {
            "ManualClock: expected \(expected) pending sleeper(s) within \(timeout) of real time, found \(pending)"
        }
    }

    private struct Sleeper {
        let id: UInt64
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Waiter {
        let id: UInt64
        let count: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Instant
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
        var waiters: [Waiter] = []
        /// Ids whose task was cancelled before its continuation was registered.
        var cancelledEarly: Set<UInt64> = []

        mutating func makeID() -> UInt64 {
            nextID += 1
            return nextID
        }

        /// Removes and returns the waiters the current sleeper count satisfies.
        mutating func takeSatisfiedWaiters() -> [Waiter] {
            let ready = waiters.filter { $0.count <= sleepers.count }
            waiters.removeAll { $0.count <= sleepers.count }
            return ready
        }
    }

    private let state: Mutex<State>

    public init(now: Instant = Instant(offset: .zero)) {
        state = Mutex(State(now: now))
    }

    public var now: Instant { state.withLock { $0.now } }

    public var minimumResolution: Duration { .zero }

    /// How many tasks are asleep on this clock right now.
    public var pendingSleeperCount: Int { state.withLock { $0.sleepers.count } }

    /// The earliest deadline among the sleepers, if any.
    public var nextDeadline: Instant? { state.withLock { $0.sleepers.map(\.deadline).min() } }

    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        try Task.checkCancellation()
        let id = state.withLock { $0.makeID() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (immediate, satisfied): (Result<Void, any Error>?, [Waiter]) = state.withLock { state in
                    if state.cancelledEarly.remove(id) != nil { return (.failure(CancellationError()), []) }
                    if deadline <= state.now { return (.success(()), []) }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return (nil, state.takeSatisfiedWaiters())
                }
                if let immediate { continuation.resume(with: immediate) }
                for waiter in satisfied { waiter.continuation.resume() }
            }
        } onCancel: {
            let sleeper: Sleeper? = state.withLock { state in
                if let index = state.sleepers.firstIndex(where: { $0.id == id }) {
                    return state.sleepers.remove(at: index)
                }
                state.cancelledEarly.insert(id)
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward by `duration`, waking every sleeper whose deadline it reaches.
    public func advance(by duration: Duration) async {
        await advance(to: now.advanced(by: duration))
    }

    /// Moves time forward to `target` (never backwards), one sleeper at a time: the clock
    /// reads the earliest deadline, the sleeper that went to sleep first with that deadline
    /// wakes, and it gets to run to its next suspension point before the next one wakes.
    public func advance(to target: Instant) async {
        while true {
            let due: Sleeper? = state.withLock { state in
                // `min(by:)` keeps the first of equal deadlines: registration order.
                guard let index = state.sleepers.indices.min(by: { state.sleepers[$0].deadline < state.sleepers[$1].deadline }),
                      state.sleepers[index].deadline <= target
                else {
                    if state.now < target { state.now = target }
                    return nil
                }
                let sleeper = state.sleepers.remove(at: index)
                if state.now < sleeper.deadline { state.now = sleeper.deadline }
                return sleeper
            }
            guard let due else { break }
            due.continuation.resume()
            await Self.settle()
        }
        await Self.settle()
    }

    /// Waits until at least `count` tasks are asleep on this clock.
    ///
    /// - Throws: ``Timeout`` when they are not there after `timeout` of real time.
    public func waitForSleepers(_ count: Int = 1, timeout: Duration = .seconds(10)) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.registerWaiter(count) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Timeout(expected: count, pending: self.pendingSleeperCount, timeout: timeout)
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func registerWaiter(_ count: Int) async throws {
        let id = state.withLock { $0.makeID() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = state.withLock { state in
                    if state.cancelledEarly.remove(id) != nil { return .failure(CancellationError()) }
                    if state.sleepers.count >= count { return .success(()) }
                    state.waiters.append(Waiter(id: id, count: count, continuation: continuation))
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let waiter: Waiter? = state.withLock { state in
                if let index = state.waiters.firstIndex(where: { $0.id == id }) {
                    return state.waiters.remove(at: index)
                }
                state.cancelledEarly.insert(id)
                return nil
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Gives the tasks that were just woken a chance to run to their next suspension point:
    /// the caller yields repeatedly, each time behind a background-priority hop, so work
    /// queued on the main actor and on the cooperative pool goes first.
    private static func settle() async {
        for _ in 0..<10 {
            await Task.detached(priority: .background) { await Task.yield() }.value
            await Task.yield()
        }
    }
}
