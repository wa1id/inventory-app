import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// 06 §3.5: the one-shot search-focus request (src/ui/searchFocus.ts).
@Suite("HomeSearchFocus (src/ui/searchFocus.ts)")
@MainActor
struct HomeSearchFocusTests {
    @Test("a request is answered once, the next time Home gains focus")
    func answeredOnce() {
        let focus = HomeSearchFocus(clock: ManualClock())
        focus.request()
        #expect(focus.pending == HomeSearchFocus.Request(afterTransition: false))
        focus.homeFocusChanged(true)
        #expect(focus.focusRequests == 1)
        #expect(focus.pending == nil)
        focus.homeFocusChanged(false)
        focus.homeFocusChanged(true)
        #expect(focus.focusRequests == 1)
    }

    @Test("a later request replaces the earlier one; consume takes it")
    func laterReplaces() {
        let focus = HomeSearchFocus(clock: ManualClock())
        focus.request()
        focus.request(afterTransition: true)
        #expect(focus.consume() == HomeSearchFocus.Request(afterTransition: true))
        #expect(focus.consume() == nil)
    }

    @Test("after a transition, Home waits for it to end")
    func waitsForTransition() async throws {
        let clock = ManualClock()
        let focus = HomeSearchFocus(clock: clock)
        focus.request(afterTransition: true)
        focus.homeFocusChanged(true)
        #expect(focus.focusRequests == 0)
        #expect(focus.isWaitingForTransition)
        try await clock.waitForSleepers()
        focus.transitionEnded()
        #expect(focus.focusRequests == 1)
        #expect(!focus.isWaitingForTransition)
        #expect(clock.pendingSleeperCount == 0)
        await clock.advance(by: .seconds(1))
        #expect(focus.focusRequests == 1)
    }

    @Test("or 600 ms at most")
    func fallback() async throws {
        let clock = ManualClock()
        let focus = HomeSearchFocus(clock: clock)
        focus.request(afterTransition: true)
        focus.homeFocusChanged(true)
        try await clock.waitForSleepers()
        await clock.advance(by: .milliseconds(599))
        #expect(focus.focusRequests == 0)
        await clock.advance(by: .milliseconds(1))
        #expect(focus.focusRequests == 1)
        #expect(HomeSearchFocus.transitionFallback == .milliseconds(600))
    }

    @Test("losing focus first gives up, and the request stays answered")
    func lostFocusGivesUp() async throws {
        let clock = ManualClock()
        let focus = HomeSearchFocus(clock: clock)
        focus.request(afterTransition: true)
        focus.homeFocusChanged(true)
        try await clock.waitForSleepers()
        focus.homeFocusChanged(false)
        await clock.advance(by: .seconds(1))
        focus.transitionEnded()
        #expect(focus.focusRequests == 0)
        focus.homeFocusChanged(true)
        #expect(focus.focusRequests == 0)
    }

    @Test("a transition ending with no request waiting does nothing")
    func strayTransition() {
        let focus = HomeSearchFocus(clock: ManualClock())
        focus.transitionEnded()
        focus.homeFocusChanged(true)
        #expect(focus.focusRequests == 0)
    }
}
