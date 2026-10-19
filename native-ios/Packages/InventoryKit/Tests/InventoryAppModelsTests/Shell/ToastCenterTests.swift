import InventoryStrings
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// 09 §4.6 / §14.2 `ToastCenterTests` and 06 §14 (no RN tests exist for the provider).
@Suite("ToastCenter (src/providers/ToastProvider.tsx)")
@MainActor
struct ToastCenterTests {
    /// A centre on a manual clock that records what it announces.
    @MainActor
    private final class Harness {
        let clock = ManualClock()
        let spoken = ShellEventLog()
        let center: ToastCenter

        init(voiceOver: Bool = false) {
            let spoken = spoken
            center = ToastCenter(clock: clock, isVoiceOverRunning: voiceOver, announce: { spoken.record($0) })
        }

        /// Moves the clock to `ms` after the start, once `sleepers` timers are asleep.
        func at(_ ms: Int, sleepers: Int = 1) async throws {
            try await clock.waitForSleepers(sleepers)
            await clock.advance(to: ManualClock.Instant(offset: .milliseconds(ms)))
        }

        var message: String? { center.current?.message }
    }

    private static func undo(_ log: ShellEventLog? = nil) -> ToastAction {
        ToastAction(label: "Undo", accessibilityLabel: "Undo moving Cordless drill") { log?.record("undo") }
    }

    @Test("ids run toast-1, toast-2, … and the tone defaults to info")
    func idSequence() {
        let harness = Harness()
        #expect(harness.center.show(ToastOptions(message: "a")) == "toast-1")
        #expect(harness.center.show(ToastOptions(message: "b")) == "toast-2")
        #expect(harness.center.show(ToastOptions(message: "c", tone: .error)) == "toast-3")
        #expect(harness.center.current?.id == "toast-3")
        #expect(harness.center.current?.tone == .error)
        let presenter: any ToastPresenting = harness.center
        #expect(presenter.show(ToastOptions(message: "d")) == "toast-4")
    }

    @Test("a plain toast lives 5 s, then leaves for 120 ms and is removed")
    func plainLife() async throws {
        let harness = Harness()
        harness.center.show(ToastOptions(message: "Saved"))
        try await harness.at(4999)
        #expect(harness.message == "Saved")
        #expect(!harness.center.leaving)
        try await harness.at(5000)
        #expect(harness.center.leaving)
        #expect(harness.message == "Saved")
        try await harness.at(5119)
        #expect(harness.message == "Saved")
        try await harness.at(5120)
        #expect(harness.center.current == nil)
        #expect(!harness.center.leaving)
    }

    @Test("a toast with an action lives 9 s; a caller's duration overrides both")
    func actionAndOverrideLives() async throws {
        let harness = Harness()
        harness.center.show(ToastOptions(message: "Moved", action: Self.undo()))
        try await harness.at(8999)
        #expect(!harness.center.leaving)
        try await harness.at(9000)
        #expect(harness.center.leaving)
        try await harness.at(9120)

        harness.center.show(ToastOptions(message: "Quick", duration: .seconds(2)))
        try await harness.at(11119)
        #expect(!harness.center.leaving)
        try await harness.at(11120)
        #expect(harness.center.leaving)
    }

    @Test("lives double while VoiceOver runs, as of when the toast is presented")
    func voiceOverDoubles() async throws {
        let harness = Harness(voiceOver: true)
        harness.center.show(ToastOptions(message: "Saved"))
        harness.center.isVoiceOverRunning = false
        try await harness.at(9999)
        #expect(!harness.center.leaving)
        try await harness.at(10000)
        #expect(harness.center.leaving)
        try await harness.at(10120)

        harness.center.isVoiceOverRunning = true
        harness.center.show(ToastOptions(message: "Moved", action: Self.undo()))
        try await harness.at(10120 + 17999)
        #expect(!harness.center.leaving)
        try await harness.at(10120 + 18000)
        #expect(harness.center.leaving)
    }

    @Test("a new toast replaces the current one, and the old one's timer no longer counts")
    func replaces() async throws {
        let harness = Harness()
        harness.center.show(ToastOptions(message: "first"))
        try await harness.at(3000)
        harness.center.show(ToastOptions(message: "second"))
        try await harness.at(5000)
        #expect(harness.message == "second")
        #expect(!harness.center.leaving)
        try await harness.at(8000)
        #expect(harness.center.leaving)
    }

    @Test("a new toast replaces one that is leaving, and cancels its removal")
    func replacesLeaving() async throws {
        let harness = Harness()
        let first = harness.center.show(ToastOptions(message: "first"))
        harness.center.dismiss(first)
        #expect(harness.center.leaving)
        harness.center.show(ToastOptions(message: "second"))
        #expect(!harness.center.leaving)
        try await harness.at(200)
        #expect(harness.message == "second")
        #expect(!harness.center.leaving)
    }

    @Test("an error holds for 1.5 s: a newcomer waits, then shows")
    func errorHold() async throws {
        let harness = Harness()
        harness.center.show(ToastOptions(message: "Not saved", tone: .error))
        try await harness.at(500)
        let id = harness.center.show(ToastOptions(message: "Saved"))
        #expect(id == "toast-2")
        #expect(harness.message == "Not saved")
        try await harness.at(1499, sleepers: 2)
        #expect(harness.message == "Not saved")
        try await harness.at(1500)
        #expect(harness.message == "Saved")
        #expect(harness.center.current?.id == "toast-2")
    }

    @Test("the hold ends when the error has been up 1.5 s, not 1.5 s after the newcomer")
    func holdTimerFromShownAt() async throws {
        let harness = Harness()
        harness.center.show(ToastOptions(message: "Not saved", tone: .error))
        try await harness.at(1000)
        harness.center.show(ToastOptions(message: "Saved"))
        try await harness.at(1500, sleepers: 2)
        #expect(harness.message == "Saved")
    }

    @Test("of several waiting toasts the newest wins")
    func newestPendingWins() async throws {
        let harness = Harness()
        harness.center.show(ToastOptions(message: "Not saved", tone: .error))
        try await harness.at(200)
        harness.center.show(ToastOptions(message: "A"))
        try await harness.at(400, sleepers: 2)
        harness.center.show(ToastOptions(message: "B"))
        try await harness.at(1500, sleepers: 2)
        #expect(harness.message == "B")
        try await harness.at(10000)
        #expect(!harness.spoken.events.contains("A"))
    }

    @Test("a waiting error is never replaced by an info toast, only by a newer error")
    func pendingErrorKept() async throws {
        let harness = Harness()
        harness.center.show(ToastOptions(message: "E1", tone: .error))
        try await harness.at(100)
        harness.center.show(ToastOptions(message: "E2", tone: .error))
        harness.center.show(ToastOptions(message: "info"))
        try await harness.at(1500, sleepers: 2)
        #expect(harness.message == "E2")

        harness.center.show(ToastOptions(message: "E3", tone: .error))
        harness.center.show(ToastOptions(message: "E4", tone: .error))
        try await harness.at(3000, sleepers: 2)
        #expect(harness.message == "E4")
        #expect(!harness.spoken.events.contains("info"))
        #expect(!harness.spoken.events.contains("E3"))
    }

    @Test("past 1.5 s an error is replaced at once")
    func errorReplacedAfterHold() async throws {
        let harness = Harness()
        harness.center.show(ToastOptions(message: "Not saved", tone: .error))
        try await harness.at(1500)
        harness.center.show(ToastOptions(message: "Saved"))
        #expect(harness.message == "Saved")
    }

    @Test("an info toast never holds a newcomer")
    func infoDoesNotHold() {
        let harness = Harness()
        harness.center.show(ToastOptions(message: "Saved"))
        harness.center.show(ToastOptions(message: "Not saved", tone: .error))
        #expect(harness.message == "Not saved")
    }

    @Test("a leaving error still holds within its 1.5 s; once removed, newcomers show at once")
    func leavingErrorStillHolds() async throws {
        let harness = Harness()
        let error = harness.center.show(ToastOptions(message: "Not saved", tone: .error))
        try await harness.at(100)
        harness.center.dismiss(error)
        try await harness.at(150)
        harness.center.show(ToastOptions(message: "held"))
        #expect(harness.message == "Not saved")
        try await harness.at(220, sleepers: 2)
        #expect(harness.center.current == nil)
        try await harness.at(1500)
        #expect(harness.message == "held")

        let second = Harness()
        let failed = second.center.show(ToastOptions(message: "Not saved", tone: .error))
        second.center.dismiss(failed)
        try await second.at(120)
        #expect(second.center.current == nil)
        second.center.show(ToastOptions(message: "now"))
        #expect(second.message == "now")
    }

    @Test("dismissing a waiting toast drops it")
    func dismissPending() async throws {
        let harness = Harness()
        harness.center.show(ToastOptions(message: "Not saved", tone: .error))
        let waiting = harness.center.show(ToastOptions(message: "Saved"))
        harness.center.dismiss(waiting)
        try await harness.at(1500, sleepers: 2)
        #expect(harness.message == "Not saved")
        #expect(!harness.center.leaving)
    }

    @Test("dismissing the current toast makes it leave; an unknown id does nothing")
    func dismissCurrent() async throws {
        let harness = Harness()
        let id = harness.center.show(ToastOptions(message: "Saved"))
        harness.center.dismiss("toast-99")
        #expect(!harness.center.leaving)
        harness.center.dismiss(id)
        #expect(harness.center.leaving)
        try await harness.at(120)
        #expect(harness.center.current == nil)
    }

    @Test("a finger on the toast freezes its life; lifting it resumes with what was left")
    func pauseAndResume() async throws {
        let harness = Harness()
        harness.center.show(ToastOptions(message: "Saved"))
        try await harness.at(1000)
        harness.center.pause()
        await harness.clock.advance(to: ManualClock.Instant(offset: .milliseconds(20000)))
        #expect(harness.message == "Saved")
        #expect(!harness.center.leaving)
        harness.center.resume()
        try await harness.at(23999)
        #expect(!harness.center.leaving)
        try await harness.at(24000)
        #expect(harness.center.leaving)
    }

    @Test("lifting a finger always leaves at least 2.5 s")
    func resumeFloor() async throws {
        let harness = Harness()
        harness.center.show(ToastOptions(message: "Saved"))
        try await harness.at(4000)
        harness.center.pause()
        harness.center.resume()
        try await harness.at(6499)
        #expect(!harness.center.leaving)
        try await harness.at(6500)
        #expect(harness.center.leaving)
    }

    @Test("resuming never doubles again for VoiceOver")
    func resumeDoesNotRedouble() async throws {
        let harness = Harness(voiceOver: true)
        harness.center.show(ToastOptions(message: "Saved"))
        try await harness.at(1000)
        harness.center.pause()
        harness.center.resume()
        try await harness.at(9999)
        #expect(!harness.center.leaving)
        try await harness.at(10000)
        #expect(harness.center.leaving)

        let floor = Harness(voiceOver: true)
        floor.center.show(ToastOptions(message: "Saved"))
        try await floor.at(9000)
        floor.center.pause()
        floor.center.resume()
        try await floor.at(11499)
        #expect(!floor.center.leaving)
        try await floor.at(11500)
        #expect(floor.center.leaving)
    }

    @Test("pause needs a running life, and resume needs a pause")
    func pauseResumeGuards() async throws {
        let harness = Harness()
        harness.center.pause()
        harness.center.resume()
        #expect(harness.center.current == nil)

        harness.center.show(ToastOptions(message: "Saved"))
        try await harness.at(1000)
        harness.center.resume()
        try await harness.at(5000)
        #expect(harness.center.leaving)
        harness.center.pause()
        try await harness.at(5120)
        #expect(harness.center.current == nil)
    }

    @Test("presenting announces the message, with the action's availability, queued")
    func announcement() async throws {
        let harness = Harness()
        harness.center.show(ToastOptions(message: "Saved in the drop zone."))
        harness.center.show(ToastOptions(message: "Moved to Tool chest (Garage)", action: Self.undo()))
        #expect(harness.spoken.events == [
            "Saved in the drop zone.",
            "Moved to Tool chest (Garage), \(L10n.A11y.availableAction(label: "Undo"))",
        ])
        #expect(harness.center.current?.spokenText == "Moved to Tool chest (Garage), Undo available")
        #expect(harness.center.current?.actionAccessibilityLabel == "Undo moving Cordless drill")
        #expect(ToastCenter.spokenText(for: ToastOptions(message: "Saved")) == "Saved")
    }

    @Test("a held toast is announced when it shows, not when it was asked for")
    func heldAnnouncement() async throws {
        let harness = Harness()
        harness.center.show(ToastOptions(message: "Not saved", tone: .error))
        harness.center.show(ToastOptions(message: "Saved"))
        #expect(harness.spoken.events == ["Not saved"])
        try await harness.at(1500, sleepers: 2)
        #expect(harness.spoken.events == ["Not saved", "Saved"])
    }

    @Test("the action runs once, then the toast leaves; never while leaving")
    func actionOnce() async throws {
        let harness = Harness()
        let log = ShellEventLog()
        let id = harness.center.show(ToastOptions(message: "Moved", action: Self.undo(log)))
        harness.center.performAction(of: id)
        harness.center.performAction(of: id)
        #expect(log.events == ["undo"])
        #expect(harness.center.leaving)

        let other = harness.center.show(ToastOptions(message: "Moved again", action: Self.undo(log)))
        harness.center.dismiss(other)
        harness.center.performAction(of: other)
        #expect(log.events == ["undo"])
        harness.center.performAction(of: "toast-99")
        #expect(log.events == ["undo"])
    }

    @Test("bottom chrome: the latest registration wins, and unregistering falls back")
    func chrome() {
        let harness = Harness()
        #expect(harness.center.chromeHeight == nil)
        let tabBar = harness.center.registerChrome(height: 83)
        let bottomBar = harness.center.registerChrome(height: 120)
        #expect(harness.center.chromeHeight == 120)
        harness.center.unregisterChrome(bottomBar)
        #expect(harness.center.chromeHeight == 83)
        harness.center.unregisterChrome(tabBar)
        #expect(harness.center.chromeHeight == nil)
        #expect(ToastCenter.Layout.gap == 12)
        #expect(ToastCenter.Layout.swipeDismissDistance == 24)
        #expect(ToastCenter.Layout.maxWidth == 480)
    }

    @Test("the timing constants are RN's")
    func constants() {
        #expect(ToastCenter.errorHold == .milliseconds(1500))
        #expect(ToastCenter.exitDuration == .milliseconds(120))
        #expect(ToastCenter.resumeFloor == .milliseconds(2500))
    }
}
