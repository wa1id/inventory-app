import Foundation
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// The QuantityStepper's tap, hold-repeat and typing rules (src/ui/components/QuantityStepper.tsx;
/// 07 §4.7). RN has no tests for them; the timing is exact (07 Q2).
@MainActor
@Suite("QuantityHoldRepeater (QuantityStepper.tsx)")
struct EntitiesQuantityHoldRepeaterTests {
    @MainActor
    final class Harness {
        let clock = ManualClock()
        let haptics = SharedSeamsHapticRecorder()
        let changes = EntitiesChangeLog()
        let stepper: QuantityHoldRepeater

        init(value: Int, commitWhileTyping: Bool = false, disabled: Bool = false) {
            let changes = changes
            stepper = QuantityHoldRepeater(
                value: value,
                isDisabled: disabled,
                commitWhileTyping: commitWhileTyping,
                clock: clock,
                haptics: haptics.player,
                onChange: { changes.values.append($0) }
            )
        }
    }

    /// One repeat interval, once the repeat loop is asleep again (one wake per advance, so the
    /// woken loop always gets to sleep again before the clock moves on).
    private func tick(_ harness: Harness) async throws {
        try await harness.clock.waitForSleepers(1)
        await harness.clock.advance(by: .milliseconds(80))
    }

    @Test("a tap steps once, released before the hold delay")
    func tap() async throws {
        let harness = Harness(value: 3)
        harness.stepper.pressBegan(.plus)
        try await harness.clock.waitForSleepers(1)
        await harness.clock.advance(by: .milliseconds(399))
        harness.stepper.pressEnded()
        #expect(harness.changes.values == [4])
        #expect(harness.haptics.played == [.step])
        #expect(harness.stepper.value == 4)
        // Nothing more happens later.
        await harness.clock.advance(by: .seconds(2))
        #expect(harness.changes.values == [4])
    }

    @Test("holding steps once at 400 ms, then every 80 ms, ticking every fifth repeat, until release")
    func hold() async throws {
        let harness = Harness(value: 10)
        harness.stepper.pressBegan(.plus)
        try await harness.clock.waitForSleepers(1)
        await harness.clock.advance(by: .milliseconds(400))
        try await harness.clock.waitForSleepers(1)
        #expect(harness.changes.values == [11])
        #expect(harness.haptics.played == [.step])

        await harness.clock.advance(by: .milliseconds(79))
        #expect(harness.changes.values == [11])
        await harness.clock.advance(by: .milliseconds(1))
        try await harness.clock.waitForSleepers(1)
        #expect(harness.changes.values == [11, 12])

        for _ in 0..<4 { try await tick(harness) }
        try await harness.clock.waitForSleepers(1)
        #expect(harness.changes.values == [11, 12, 13, 14, 15, 16])
        // The first step plus one tick for the fifth repeat.
        #expect(harness.haptics.played == [.step, .step])

        harness.stepper.pressEnded()
        await harness.clock.advance(by: .seconds(1))
        // Releasing a hold is not a tap.
        #expect(harness.changes.values == [11, 12, 13, 14, 15, 16])
    }

    @Test("holding stops at a bound")
    func holdToBound() async throws {
        let harness = Harness(value: 9997)
        harness.stepper.pressBegan(.plus)
        try await harness.clock.waitForSleepers(1)
        await harness.clock.advance(by: .milliseconds(400))
        try await tick(harness)
        try await harness.clock.waitForSleepers(1)
        #expect(harness.changes.values == [9998, 9999])
        #expect(harness.stepper.isPlusDisabled)
        // The next repeat finds the bound and the repeating stops: nothing sleeps any more.
        try await tick(harness)
        #expect(harness.clock.pendingSleeperCount == 0)
        harness.stepper.pressEnded()
        #expect(harness.changes.values == [9998, 9999])
    }

    @Test("reaching zero plays the heavier tick, and minus then stops")
    func reachesZero() async throws {
        let harness = Harness(value: 1)
        harness.stepper.step(.minus)
        #expect(harness.changes.values == [0])
        #expect(harness.haptics.played == [.reachedZero])
        #expect(harness.stepper.isMinusDisabled)
        #expect(harness.stepper.step(.minus) == nil)
        #expect(harness.haptics.played == [.reachedZero])
    }

    @Test("a hold down to zero ticks zero, not the fifth-step tick")
    func holdDownToZero() async throws {
        let harness = Harness(value: 3)
        harness.stepper.pressBegan(.minus)
        try await harness.clock.waitForSleepers(1)
        await harness.clock.advance(by: .milliseconds(400))
        try await tick(harness)
        try await tick(harness)
        try await tick(harness)
        #expect(harness.clock.pendingSleeperCount == 0)
        #expect(harness.changes.values == [2, 1, 0])
        #expect(harness.haptics.played == [.step, .reachedZero])
    }

    @Test("a cancelled press does nothing; a disabled stepper does nothing")
    func cancelledAndDisabled() async throws {
        let harness = Harness(value: 3)
        harness.stepper.pressBegan(.plus)
        harness.stepper.pressCancelled()
        await harness.clock.advance(by: .seconds(1))
        #expect(harness.changes.values.isEmpty)

        let disabled = Harness(value: 3, disabled: true)
        disabled.stepper.pressBegan(.plus)
        disabled.stepper.pressEnded()
        #expect(disabled.stepper.step(.minus) == nil)
        #expect(disabled.changes.values.isEmpty)
        #expect(disabled.stepper.isPlusDisabled && disabled.stepper.isMinusDisabled)
    }

    @Test("a value above 9999 from another writer: plus is off, minus writes 9999")
    func aboveCap() {
        let harness = Harness(value: 12_000)
        #expect(harness.stepper.isPlusDisabled)
        harness.stepper.step(.minus)
        #expect(harness.changes.values == [9999])
    }

    @Test("a typed number commits on leaving the field; anything else reverts")
    func typing() {
        let harness = Harness(value: 5)
        harness.stepper.beginEditing()
        #expect(harness.stepper.draft == "5")
        harness.stepper.typeDraft("12")
        #expect(harness.stepper.fieldText == "12")
        #expect(harness.changes.values.isEmpty)
        harness.stepper.commitTyped()
        #expect(harness.changes.values == [12])
        #expect(harness.stepper.draft == nil)

        harness.stepper.beginEditing()
        harness.stepper.typeDraft("abc")
        harness.stepper.commitTyped()
        #expect(harness.changes.values == [12])
        #expect(harness.stepper.fieldText == "12")
    }

    @Test("the field takes four characters")
    func fourCharacters() {
        let harness = Harness(value: 5)
        harness.stepper.beginEditing()
        harness.stepper.typeDraft("123456")
        #expect(harness.stepper.draft == "1234")
        harness.stepper.commitTyped()
        #expect(harness.changes.values == [1234])
    }

    @Test("with commitWhileTyping every whole number is reported at once; partial input waits")
    func commitWhileTyping() {
        let harness = Harness(value: 1, commitWhileTyping: true)
        harness.stepper.beginEditing()
        harness.stepper.typeDraft("")
        #expect(harness.changes.values.isEmpty)
        harness.stepper.typeDraft("7")
        harness.stepper.typeDraft("70")
        #expect(harness.changes.values == [7, 70])
        harness.stepper.commitTyped()
        #expect(harness.changes.values == [7, 70])
    }

    @Test("a step with a draft open commits the draft first")
    func stepCommitsDraft() {
        let harness = Harness(value: 5)
        harness.stepper.beginEditing()
        harness.stepper.typeDraft("20")
        harness.stepper.step(.plus)
        #expect(harness.changes.values == [21])
        #expect(harness.stepper.draft == nil)
    }
}

/// Records the values a stepper reports.
@MainActor
final class EntitiesChangeLog {
    var values: [Int] = []
}
