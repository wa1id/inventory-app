import Foundation
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// The stepper's ± are stock buttons, so a drag that starts on one scrolls the list. A button
/// reports its pressed state and calls its action separately, in either order, and a scroll ends
/// the press with no action: `pressLifted()` and `buttonActivated(_:)` must still give one step
/// per tap, none per scroll and none extra after a hold.
@MainActor
@Suite("Components stepper presses")
struct ComponentsStepperPressTests {
    @MainActor
    final class Harness {
        let clock = ManualClock()
        let haptics = SharedSeamsHapticRecorder()
        var changes: [Int] = []
        lazy var stepper = QuantityHoldRepeater(
            value: value,
            clock: clock,
            haptics: haptics.player,
            onChange: { [weak self] in self?.changes.append($0) }
        )
        let value: Int

        init(value: Int) {
            self.value = value
        }
    }

    @Test("a tap steps once whether the lift or the action comes first")
    func tapInEitherOrder() async throws {
        let liftFirst = Harness(value: 3)
        liftFirst.stepper.pressBegan(.plus)
        liftFirst.stepper.pressLifted()
        liftFirst.stepper.buttonActivated(.plus)
        #expect(liftFirst.changes == [4])
        #expect(liftFirst.haptics.played == [.step])

        let actionFirst = Harness(value: 3)
        actionFirst.stepper.pressBegan(.plus)
        actionFirst.stepper.buttonActivated(.plus)
        actionFirst.stepper.pressLifted()
        #expect(actionFirst.changes == [4])
        await actionFirst.clock.advance(by: .seconds(1))
        #expect(actionFirst.changes == [4])
    }

    @Test("a quick tap whose press was never seen still steps, in its own direction")
    func unseenPress() async throws {
        let harness = Harness(value: 3)
        // A press on plus that a scroll took: lifted, no action.
        harness.stepper.pressBegan(.plus)
        harness.stepper.pressLifted()
        // Then a tap on minus too quick for its pressed state to show.
        harness.stepper.buttonActivated(.minus)
        #expect(harness.changes == [2])
    }

    @Test("a scroll that takes the touch steps nothing and stops the hold")
    func scrollCancels() async throws {
        let harness = Harness(value: 3)
        harness.stepper.pressBegan(.plus)
        try await harness.clock.waitForSleepers(1)
        harness.stepper.pressLifted()
        await harness.clock.advance(by: .seconds(2))
        #expect(harness.changes.isEmpty)
        #expect(harness.clock.pendingSleeperCount == 0)
    }

    @Test("the release after a hold does not step again, in either order")
    func holdRelease() async throws {
        for liftFirst in [true, false] {
            let harness = Harness(value: 10)
            harness.stepper.pressBegan(.plus)
            try await harness.clock.waitForSleepers(1)
            await harness.clock.advance(by: .milliseconds(400))
            try await harness.clock.waitForSleepers(1)
            await harness.clock.advance(by: .milliseconds(80))
            try await harness.clock.waitForSleepers(1)
            #expect(harness.changes == [11, 12])
            if liftFirst {
                harness.stepper.pressLifted()
                harness.stepper.buttonActivated(.plus)
            } else {
                harness.stepper.buttonActivated(.plus)
                harness.stepper.pressLifted()
            }
            await harness.clock.advance(by: .seconds(1))
            #expect(harness.changes == [11, 12], "lift first: \(liftFirst)")
        }
    }

    @Test("a dimmed button's tap changes nothing and plays nothing")
    func boundTap() {
        let harness = Harness(value: 0)
        harness.stepper.buttonActivated(.minus)
        #expect(harness.changes.isEmpty)
        #expect(harness.haptics.played.isEmpty)
    }
}
