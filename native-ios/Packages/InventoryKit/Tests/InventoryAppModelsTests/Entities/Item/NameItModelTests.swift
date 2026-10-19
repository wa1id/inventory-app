import Foundation
import InventoryCore
import InventoryStrings
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// `NameItInline` (src/ui/item/NameItInline.tsx; 07 §3.3, 05 §12) as a model. RN has no tests
/// for the component; `attemptName` is tested in ItemDetailsTests.
@MainActor
@Suite("NameItModel (NameItInline.tsx)")
struct EntitiesNameItModelTests {
    @MainActor
    final class Harness {
        let items: any ItemsRepository
        let haptics = SharedSeamsHapticRecorder()
        let invalidations = SharedSeamsInvalidationCounter()
        let telemetry = RecordingTelemetry()
        let log = EntitiesNameLog()
        let model: NameItModel

        init(items: any ItemsRepository, updatedAt: Int64 = 10, incomingName: String = "") {
            self.items = items
            let log = log
            model = NameItModel(
                itemId: "item-1",
                updatedAt: updatedAt,
                incomingName: incomingName,
                items: items,
                invalidator: invalidations,
                haptics: haptics.player,
                telemetry: TelemetryReporter(sink: telemetry),
                announce: { log.announced.append($0) },
                onNamed: { log.named.append($0) }
            )
        }
    }

    @Test("an empty name asks for one, announced each time")
    func emptyName() async {
        let harness = Harness(items: EntitiesFakeItems())
        harness.model.value = "   "
        #expect(await harness.model.save() == false)
        #expect(await harness.model.save() == false)
        #expect(harness.model.error == L10n.Forms.itemNameRequired)
        #expect(harness.log.announced == [L10n.Forms.itemNameRequired, L10n.Forms.itemNameRequired])
        #expect(harness.model.accessibilityLabel == "\(L10n.Item.NameIt.a11y), \(L10n.Forms.errorA11y(error: L10n.Forms.itemNameRequired))")
        // Typing clears it.
        harness.model.value = "B"
        #expect(harness.model.error == nil)
    }

    @Test("saving names it with the lock, logs and refreshes; the field is then done")
    func named() async {
        let items = EntitiesFakeItems(updates: [.value(EntitiesFixtures.item(name: "Batteries", updatedAt: 11))])
        let harness = Harness(items: items)
        harness.model.focused = true
        harness.model.value = " Batteries "
        #expect(harness.model.engaged)
        #expect(await harness.model.save())
        #expect(await items.updates == [EntitiesUpdateCall(id: "item-1", input: UpdateItemInput(name: "Batteries", expectedUpdatedAt: 10))])
        #expect(harness.log.named == ["Batteries"])
        #expect(harness.telemetry.names == ["item_updated"])
        #expect(harness.invalidations.count == 1)
        #expect(harness.model.named)
        #expect(!harness.model.engaged)
    }

    @Test("a name given meanwhile is offered, with a warning; saving again goes over its stamp")
    func namedMeanwhile() async {
        let stored = EntitiesLockedStore(name: "", updatedAt: 10)
        await stored.write(name: "AA batteries", updatedAt: 20)
        let harness = Harness(items: stored)
        harness.model.value = "Batteries"

        #expect(await harness.model.save() == false)
        #expect(harness.haptics.played == [.warning])
        #expect(harness.model.meanwhile == NameItModel.Meanwhile(name: "AA batteries", updatedAt: 20))
        #expect(harness.model.theirs == "AA batteries")
        #expect(harness.model.offered == "AA batteries")
        #expect(harness.model.notice == L10n.Item.NameIt.namedMeanwhile(name: "AA batteries"))
        #expect(harness.model.value == "Batteries")
        #expect(harness.invalidations.count == 1)

        #expect(await harness.model.save())
        #expect(await stored.stamps == [10, 20])
        #expect(await stored.name == "Batteries")
        #expect(harness.log.named == ["Batteries"])
    }

    @Test("a name arriving with the screen's read is offered as just named, and can be used without a write")
    func justNamed() async {
        let items = EntitiesFakeItems()
        let harness = Harness(items: items)
        harness.model.value = "Batt"
        harness.model.incomingName = "AA batteries"
        harness.model.itemUpdatedAt = 20
        #expect(harness.model.offered == "AA batteries")
        #expect(harness.model.notice == L10n.Item.NameIt.justNamed(name: "AA batteries"))
        #expect(harness.model.canUseOffered)
        harness.model.useOffered()
        #expect(harness.log.named == ["AA batteries"])
        #expect(await items.updates.isEmpty)
    }

    @Test("their name equal to the typed one is not offered")
    func notOffered() {
        let harness = Harness(items: EntitiesFakeItems(), incomingName: "Batteries")
        harness.model.value = " Batteries "
        #expect(harness.model.offered == nil)
        #expect(harness.model.notice == nil)
    }

    @Test("an older meanwhile gives way to the screen's newer read")
    func theirsFollowsNewest() async {
        let stored = EntitiesLockedStore(name: "", updatedAt: 10)
        await stored.write(name: "AA batteries", updatedAt: 20)
        let harness = Harness(items: stored)
        harness.model.value = "Batteries"
        _ = await harness.model.save()
        harness.model.itemUpdatedAt = 25
        harness.model.incomingName = "Pencils"
        #expect(harness.model.theirs == "Pencils")
        // Still the meanwhile wording: a save ran into another name.
        #expect(harness.model.notice == L10n.Item.NameIt.namedMeanwhile(name: "Pencils"))
    }

    @Test("an item deleted elsewhere refreshes the screen, without a haptic")
    func gone() async {
        let harness = Harness(items: EntitiesFakeItems(updates: [.value(nil)]))
        harness.model.value = "Batteries"
        #expect(await harness.model.save() == false)
        #expect(harness.invalidations.count == 1)
        #expect(harness.haptics.played.isEmpty)
        #expect(harness.model.error == nil)
    }

    @Test("a failure says whether it was the connection")
    func failed() async {
        let harness = Harness(items: EntitiesFakeItems(updates: [.failure(HouseholdHttpError(status: 0, code: "offline"))]))
        harness.model.value = "Batteries"
        #expect(await harness.model.save() == false)
        #expect(harness.model.error == L10n.Item.NameIt.failedOffline)
        #expect(harness.telemetry.errors == [RecordingTelemetry.Entry(level: "error", name: "item_name_failed", payload: ["errorClass": .string("offline")])])
        #expect(harness.haptics.played == [.error])

        let other = Harness(items: EntitiesFakeItems(updates: [.failure(EntitiesFailure("SQLITE_BUSY"))]))
        other.model.value = "Batteries"
        _ = await other.model.save()
        #expect(other.model.error == L10n.Item.NameIt.failed)
    }

    @Test("one save at a time")
    func singleFlight() async {
        let items = EntitiesFakeItems(updates: [.value(EntitiesFixtures.item(updatedAt: 11))])
        await items.setHoldUpdates(true)
        let harness = Harness(items: items)
        harness.model.value = "Batteries"
        let first = Task { await harness.model.save() }
        await EntitiesFakeItems.waitForHeld(items, count: 1)
        #expect(harness.model.saving)
        #expect(!harness.model.canUseOffered)
        #expect(await harness.model.save() == false)
        await items.releaseNextUpdate()
        #expect(await first.value)
        #expect(await items.updates.count == 1)
    }

    @Test("commit: nothing typed is fine, their own name needs no write, anything else is saved")
    func commit() async {
        let empty = Harness(items: EntitiesFakeItems())
        #expect(await empty.model.commit())
        #expect(empty.log.named.isEmpty)

        let same = Harness(items: EntitiesFakeItems(), incomingName: "Batteries")
        same.model.value = " Batteries"
        #expect(await same.model.commit())
        #expect(same.log.named == ["Batteries"])

        let failing = Harness(items: EntitiesFakeItems(updates: [.failure(EntitiesFailure())]))
        failing.model.value = "Batteries"
        #expect(await failing.model.commit() == false)
        #expect(failing.log.named.isEmpty)
    }

    @Test("the field is engaged while focused or holding text")
    func engaged() {
        let harness = Harness(items: EntitiesFakeItems())
        #expect(!harness.model.engaged)
        harness.model.focused = true
        #expect(harness.model.engaged)
        harness.model.focused = false
        harness.model.value = "  "
        #expect(!harness.model.engaged)
        harness.model.value = "B"
        #expect(harness.model.engaged)
    }
}

/// What a name field reported.
@MainActor
final class EntitiesNameLog {
    var announced: [String] = []
    var named: [String] = []
}
