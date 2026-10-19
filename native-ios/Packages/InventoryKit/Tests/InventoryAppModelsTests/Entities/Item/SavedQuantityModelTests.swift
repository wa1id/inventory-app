import Foundation
import InventoryCore
import InventoryStrings
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// `useSavedQuantity` (src/hooks/useSavedQuantity.ts) as a model. RN has no tests for it; these
/// are the ones 07 §8 item 16 asks for, plus the paths 01 §9.3 pins.
@MainActor
@Suite("SavedQuantityModel (useSavedQuantity.ts)")
struct EntitiesSavedQuantityModelTests {
    @MainActor
    final class Harness {
        let items: EntitiesFakeItems
        let haptics = SharedSeamsHapticRecorder()
        let invalidations = SharedSeamsInvalidationCounter()
        let telemetry = RecordingTelemetry()
        let failures = EntitiesFailureLog()
        let model: SavedQuantityModel

        init(items: EntitiesFakeItems, quantity: Int = 5, updatedAt: Int64 = 10) {
            self.items = items
            let failures = failures
            model = SavedQuantityModel(
                itemId: "item-1",
                quantity: quantity,
                updatedAt: updatedAt,
                items: items,
                invalidator: invalidations,
                haptics: haptics.player,
                telemetry: TelemetryReporter(sink: telemetry),
                onError: { failures.kinds.append($0) }
            )
        }

        func settle() async {
            await model.flushTask?.value
        }
    }

    private static func saved(_ quantity: Int, _ updatedAt: Int64) -> EntitiesFakeItems.Answer<Item?> {
        .value(EntitiesFixtures.item(quantity: quantity, updatedAt: updatedAt))
    }

    private static let conflict = EntitiesFakeItems.Answer<Item?>.failure(ConflictError(updatedAt: 20))

    private static func fresh(_ quantity: Int, _ updatedAt: Int64) -> EntitiesFakeItems.Answer<ItemWithContext?> {
        .value(EntitiesFixtures.context(quantity: quantity, updatedAt: updatedAt))
    }

    @Test("five quick sets while the first write is pending make exactly two writes, the second over the first's stamp")
    func coalesces() async {
        let items = EntitiesFakeItems(updates: [Self.saved(6, 11), Self.saved(10, 12)])
        await items.setHoldUpdates(true)
        let harness = Harness(items: items)

        harness.model.setQuantity(6)
        await EntitiesFakeItems.waitForHeld(items, count: 1)
        for next in 7...10 { harness.model.setQuantity(next) }
        #expect(harness.model.quantity == 10)
        await items.releaseNextUpdate()
        await EntitiesFakeItems.waitForHeld(items, count: 1)
        await items.releaseNextUpdate()
        await harness.settle()

        let calls = await items.updates
        #expect(calls.map(\.input.quantity) == [6, 10])
        #expect(calls.map(\.input.expectedUpdatedAt) == [10, 11])
        #expect(calls.allSatisfy { $0.input.name == nil && $0.input.tags == nil && $0.input.containerId == nil })
        #expect(harness.model.quantity == 10)
        #expect(harness.model.errorKind == nil)
        #expect(harness.telemetry.names == ["item_updated", "item_updated"])
        #expect(harness.invalidations.count == 2)
        #expect(harness.haptics.played.isEmpty)
    }

    @Test("a conflict re-reads and retries at most three times; the fourth fails with the error haptic")
    func conflictRetries() async {
        let items = EntitiesFakeItems(
            updates: Array(repeating: Self.conflict, count: 4),
            reads: [Self.fresh(5, 20), Self.fresh(5, 21), Self.fresh(5, 22)]
        )
        let harness = Harness(items: items)
        harness.model.setQuantity(6)
        await harness.settle()

        #expect(await items.stamps == [10, 20, 21, 22])
        #expect(await items.reads.count == 3)
        #expect(harness.model.errorKind == .other)
        #expect(harness.model.error == L10n.Quantity.notSaved)
        #expect(harness.model.quantity == 5)
        #expect(harness.haptics.played == [.error])
        #expect(harness.failures.kinds == [.other])
    }

    @Test("an item deleted elsewhere snaps back and says gone, without a haptic")
    func gone() async {
        let harness = Harness(items: EntitiesFakeItems(updates: [.value(nil)]))
        harness.model.setQuantity(6)
        await harness.settle()
        #expect(harness.model.errorKind == .gone)
        #expect(harness.model.error == L10n.Quantity.gone)
        #expect(harness.model.quantity == 5)
        #expect(harness.haptics.played.isEmpty)
        #expect(harness.invalidations.count == 1)
    }

    @Test("an item deleted between a conflict and the re-read is gone, without a haptic")
    func goneAfterConflict() async {
        let harness = Harness(items: EntitiesFakeItems(updates: [Self.conflict], reads: [.value(nil)]))
        harness.model.setQuantity(6)
        await harness.settle()
        #expect(harness.model.errorKind == .gone)
        #expect(harness.haptics.played.isEmpty)
        #expect(harness.invalidations.count == 1)
    }

    @Test("a re-read that throws reads as other, without a haptic")
    func rereadThrows() async {
        let harness = Harness(items: EntitiesFakeItems(updates: [Self.conflict], reads: [.failure(EntitiesFailure("read"))]))
        harness.model.setQuantity(6)
        await harness.settle()
        #expect(harness.model.errorKind == .other)
        #expect(harness.model.quantity == 5)
        #expect(harness.haptics.played.isEmpty)
        #expect(harness.invalidations.count == 0)
    }

    @Test("a re-read already at the new count writes nothing more")
    func rereadAlreadyThere() async {
        let items = EntitiesFakeItems(updates: [Self.conflict], reads: [Self.fresh(6, 20)])
        let harness = Harness(items: items)
        harness.model.setQuantity(6)
        await harness.settle()
        #expect(await items.updates.count == 1)
        #expect(harness.model.errorKind == nil)
        #expect(harness.model.quantity == 6)
        // Nothing is pending, so the screen's next read is taken.
        harness.model.itemDidChange(quantity: 8, updatedAt: 30)
        #expect(harness.model.quantity == 8)
    }

    @Test("a connection failure says so and plays the error haptic")
    func offline() async {
        let harness = Harness(items: EntitiesFakeItems(updates: [.failure(HouseholdHttpError(status: 0, code: "offline"))]))
        harness.model.setQuantity(6)
        await harness.settle()
        #expect(harness.model.errorKind == .offline)
        #expect(harness.model.error == L10n.Quantity.notSavedOffline)
        #expect(harness.haptics.played == [.error])
        #expect(harness.invalidations.count == 0)
    }

    @Test("a household 404 thrown by the write reads as gone, refreshes and plays the error haptic")
    func thrownNotFound() async {
        let harness = Harness(items: EntitiesFakeItems(updates: [.failure(HouseholdHttpError(status: 404, code: "not_found"))]))
        harness.model.setQuantity(6)
        await harness.settle()
        #expect(harness.model.errorKind == .gone)
        #expect(harness.invalidations.count == 1)
        #expect(harness.haptics.played == [.error])
    }

    @Test("RN quirk: a gone exit after a conflict leaves the retry count, so the next run retries less")
    func retryQuirk() async {
        let items = EntitiesFakeItems(updates: [Self.conflict], reads: [.value(nil)])
        let harness = Harness(items: items)
        harness.model.setQuantity(6)
        await harness.settle()
        #expect(harness.model.errorKind == .gone)

        await items.script(updates: [Self.conflict, Self.conflict, Self.conflict], reads: [Self.fresh(5, 20), Self.fresh(5, 21)])
        harness.model.setQuantity(7)
        #expect(harness.model.errorKind == nil)
        await harness.settle()
        // One retry was used up by the first run: two re-reads, then the third conflict fails.
        #expect(await items.updates.count == 4)
        #expect(await items.reads.count == 3)
        #expect(harness.model.errorKind == .other)
        #expect(harness.haptics.played == [.error])
    }

    @Test("the screen's reads are taken only while nothing is pending or being written")
    func externalUpdates() async {
        let items = EntitiesFakeItems(updates: [Self.saved(6, 11)])
        await items.setHoldUpdates(true)
        let harness = Harness(items: items)
        harness.model.itemDidChange(quantity: 7, updatedAt: 9)
        #expect(harness.model.quantity == 7)

        harness.model.setQuantity(6)
        await EntitiesFakeItems.waitForHeld(items, count: 1)
        harness.model.itemDidChange(quantity: 3, updatedAt: 50)
        #expect(harness.model.quantity == 6)
        await items.releaseNextUpdate()
        await harness.settle()
        // The write went over the stamp the model had adopted.
        #expect(await items.stamps == [9])
        harness.model.itemDidChange(quantity: 3, updatedAt: 50)
        #expect(harness.model.quantity == 3)
    }

    @Test("counts are clamped to 0…9999 before they are shown or written")
    func clamps() async {
        let items = EntitiesFakeItems(updates: [Self.saved(9999, 11), Self.saved(0, 12)])
        let harness = Harness(items: items)
        harness.model.setQuantity(12_000)
        #expect(harness.model.quantity == 9999)
        await harness.settle()
        harness.model.setQuantity(-3)
        #expect(harness.model.quantity == 0)
        await harness.settle()
        #expect(await items.updates.map(\.input.quantity) == [9999, 0])
    }

    @Test("the compact stepper's sentence names the item, or says it needs a name")
    func compactMessage() {
        #expect(SavedQuantityModel.notSavedMessage(itemName: "Wood screws", kind: .other)
            == L10n.Quantity.notSavedNamed(name: "Wood screws", offline: false))
        #expect(SavedQuantityModel.notSavedMessage(itemName: "  ", kind: .offline)
            == L10n.Quantity.notSavedNamed(name: L10n.Entities.unnamedItem, offline: true))
        #expect(SavedQuantityModel.labelName("  ") == nil)
        #expect(SavedQuantityModel.labelName(" Drill") == " Drill")
    }

    @Test("\"None left right now\" shows at zero unless an error does")
    func noneRightNow() async {
        let harness = Harness(items: EntitiesFakeItems(updates: [.value(nil)]), quantity: 0)
        #expect(harness.model.showsNoneRightNow)
        harness.model.setQuantity(1)
        await harness.settle()
        #expect(harness.model.quantity == 0)
        #expect(!harness.model.showsNoneRightNow)
    }
}

/// Records the failures a model reports.
@MainActor
final class EntitiesFailureLog {
    var kinds: [SavedQuantityModel.ErrorKind] = []
}
