import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// 06 §16.2 `useDelayedFlag(active, ms = 180)`.
@Suite("DelayedFlag (src/hooks/useDelayedFlag.ts)")
@MainActor
struct DelayedFlagTests {
    @Test("true only after the condition has held for the delay, 180 ms by default")
    func turnsOnAfterDelay() async throws {
        let clock = ManualClock()
        let flag = DelayedFlag(clock: clock)
        #expect(flag.delay == .milliseconds(180))
        flag.setActive(true)
        #expect(!flag.value)
        try await clock.waitForSleepers()
        await clock.advance(by: .milliseconds(179))
        #expect(!flag.value)
        await clock.advance(by: .milliseconds(1))
        #expect(flag.value)
    }

    @Test("resets at once when the condition ends, and the wait starts over")
    func resetsAtOnce() async throws {
        let clock = ManualClock()
        let flag = DelayedFlag(delay: .milliseconds(400), clock: clock)
        flag.setActive(true)
        try await clock.waitForSleepers()
        await clock.advance(by: .milliseconds(400))
        #expect(flag.value)
        flag.setActive(false)
        #expect(!flag.value)

        flag.setActive(true)
        try await clock.waitForSleepers()
        await clock.advance(by: .milliseconds(300))
        flag.setActive(false)
        flag.setActive(true)
        try await clock.waitForSleepers()
        await clock.advance(by: .milliseconds(300))
        #expect(!flag.value)
        await clock.advance(by: .milliseconds(100))
        #expect(flag.value)
    }

    @Test("a wait that ran out just as the condition broke does not count for the next one")
    func staleWaitIgnored() async {
        let clock = ShellStepClock()
        let flag = DelayedFlag(clock: clock)
        flag.setActive(true)
        await ShellWait.until("the first wait") { clock.sleeperCount == 1 }
        // The first wait ends, but its task has not run when the condition breaks and holds again.
        #expect(clock.fire(throughMilliseconds: 180) == 1)
        flag.setActive(false)
        flag.setActive(true)
        await ShellWait.until("the second wait") { clock.sleeperCount == 1 }
        await ShellWait.settle()
        #expect(!flag.value)
        clock.fire(throughMilliseconds: 359)
        await ShellWait.settle()
        #expect(!flag.value)
        clock.fire(throughMilliseconds: 360)
        await ShellWait.until("the second wait to end") { flag.value }
    }

    @Test("setting the same condition again does not restart the wait")
    func sameConditionKeepsWaiting() async throws {
        let clock = ManualClock()
        let flag = DelayedFlag(clock: clock)
        flag.setActive(true)
        try await clock.waitForSleepers()
        await clock.advance(by: .milliseconds(100))
        flag.setActive(true)
        await clock.advance(by: .milliseconds(80))
        #expect(flag.value)
        #expect(flag.isActive)
    }
}

/// 06 §16.3 `useNow(intervalMs = 60_000)`.
@Suite("NowTicker (src/hooks/useNow.ts)")
@MainActor
struct NowTickerTests {
    /// A wall clock the test sets.
    private final class Wall: Sendable {
        private let value = ShellQueuedReads<Int64>([.value(1000)])
        func set(_ ms: Int64) { value.answer([.value(ms)]) }
        var read: @Sendable () -> Int64 { { (try? self.value.call("")) ?? 0 } }
    }

    @Test("starts at the current time, and ticks every minute only while focused")
    func ticksWhileFocused() async throws {
        let clock = ManualClock()
        let wall = Wall()
        let ticker = NowTicker(clock: clock, currentTime: wall.read)
        #expect(ticker.now == 1000)
        #expect(ticker.interval == .seconds(60))

        wall.set(2000)
        ticker.focusChanged(true)
        #expect(ticker.now == 2000)
        try await clock.waitForSleepers()
        wall.set(62_000)
        await clock.advance(by: .seconds(59))
        #expect(ticker.now == 2000)
        await clock.advance(by: .seconds(1))
        #expect(ticker.now == 62_000)
        wall.set(122_000)
        await clock.advance(by: .seconds(60))
        #expect(ticker.now == 122_000)
    }

    @Test("does not tick in the background, and catches up at once on focus")
    func catchesUpOnFocus() async throws {
        let clock = ManualClock()
        let wall = Wall()
        let ticker = NowTicker(interval: .seconds(1), clock: clock, currentTime: wall.read)
        ticker.focusChanged(true)
        try await clock.waitForSleepers()
        ticker.focusChanged(false)
        wall.set(500_000)
        await clock.advance(by: .seconds(30))
        #expect(ticker.now == 1000)
        #expect(clock.pendingSleeperCount == 0)
        ticker.focusChanged(true)
        #expect(ticker.now == 500_000)
    }

    @Test("a tick that came due just as the screen lost focus does not land")
    func staleTickIgnored() async {
        let clock = ShellStepClock()
        let wall = Wall()
        let ticker = NowTicker(clock: clock, currentTime: wall.read)
        ticker.focusChanged(true)
        await ShellWait.until("the tick") { clock.sleeperCount == 1 }
        wall.set(61_000)
        #expect(clock.fire(throughMilliseconds: 60_000) == 1)
        ticker.focusChanged(false)
        await ShellWait.settle()
        #expect(ticker.now == 1000)
        #expect(clock.sleeperCount == 0)
    }
}

/// 09 §6: app activity routed to the sync pass and the connection, in RN's order.
@Suite("AppLifecycle (09 §6)")
@MainActor
struct AppLifecycleTests {
    @Test("every change reaches the handlers, the sync pass before the connection")
    func order() {
        let lifecycle = AppLifecycle(initial: .background)
        let log = ShellEventLog()
        lifecycle.register(.connection) { log.record("connection \($0)") }
        lifecycle.whenActive(.sync) { log.record("sync pass") }
        lifecycle.register(.other) { log.record("other \($0)") }
        lifecycle.register(.connection) { log.record("connection2 \($0)") }

        lifecycle.activityChanged(.active)
        #expect(log.events == ["sync pass", "connection active", "connection2 active", "other active"])
        #expect(lifecycle.activity == .active)
    }

    @Test("inactive → active counts as coming to the front; nothing runs the sync pass otherwise")
    func inactiveToActive() {
        let lifecycle = AppLifecycle(initial: .active)
        let log = ShellEventLog()
        lifecycle.whenActive(.sync) { log.record("sync pass") }
        lifecycle.register(.connection) { log.record("connection \($0)") }
        lifecycle.activityChanged(.inactive)
        lifecycle.activityChanged(.active)
        lifecycle.activityChanged(.background)
        #expect(log.events == ["connection inactive", "sync pass", "connection active", "connection background"])
    }

    @Test("reporting the same activity again routes nothing, as AppState fired only on change")
    func onlyChanges() {
        let lifecycle = AppLifecycle()
        let log = ShellEventLog()
        lifecycle.register(.connection) { log.record("connection \($0)") }
        lifecycle.activityChanged(.inactive)
        lifecycle.activityChanged(.active)
        lifecycle.activityChanged(.active)
        #expect(log.events == ["connection active"])
    }

    @Test("an unregistered handler is no longer called")
    func unregister() {
        let lifecycle = AppLifecycle()
        let log = ShellEventLog()
        let registration = lifecycle.whenActive(.sync) { log.record("sync pass") }
        lifecycle.unregister(registration)
        lifecycle.activityChanged(.active)
        #expect(log.events.isEmpty)
        #expect(AppLifecycle.Stage.sync < .connection)
    }
}
