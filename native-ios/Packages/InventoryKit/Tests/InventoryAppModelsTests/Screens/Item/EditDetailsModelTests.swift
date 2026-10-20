import Foundation
import InventoryCore
import InventoryStorage
import InventoryStrings
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// Edit details (app/item/[id]/edit.tsx; 07 §3.4) as a model, with `useDirtyGuard`
/// (07 §4.16). RN has no tests for the screen; `attemptDetails`, `detailsDirty` and
/// `rebaseDetails` are tested in ItemDetailsTests.
@MainActor
@Suite("EditDetailsModel (app/item/[id]/edit.tsx)")
struct ItemScreensEditDetailsModelTests {
    @MainActor
    final class Harness {
        let items: EntitiesFakeItems
        let log = ItemScreensEventLog()
        let toasts = SharedSeamsToastRecorder()
        let confirms: SharedSeamsConfirmScript
        let haptics = SharedSeamsHapticRecorder()
        let telemetry = RecordingTelemetry()
        var focused = true
        private(set) var recorded: [String?] = []
        private(set) var model: EditDetailsModel!

        init(items: EntitiesFakeItems, confirms: [Bool] = []) {
            self.items = items
            self.confirms = SharedSeamsConfirmScript(answers: confirms)
            let log = log
            model = EditDetailsModel(
                id: "item-1",
                items: items,
                invalidator: log,
                toasts: toasts,
                confirm: self.confirms,
                haptics: haptics.player,
                telemetry: TelemetryReporter(sink: telemetry),
                categories: EditDetailsModel.Categories(
                    suggest: { prefix in CategoryMemory.suggest(["Tools", "Toys", "Food"], prefix: prefix) },
                    record: { [unowned self] in recorded.append($0) }
                ),
                routing: EditDetailsModel.Routing(isFocused: { [unowned self] in focused }, close: { log.entries.append("close") })
            )
        }

        func load() async {
            model.focusChanged(true, revision: 0)
            await model.query.readTask?.value
        }
    }

    private static let drill = EntitiesFixtures.context(name: "Cordless drill", category: "Tools", tags: ["garage", "power"], quantity: 2, updatedAt: 10)

    @Test("loading, a failed read, gone, then the form seeded from the item")
    func phases() async {
        let failing = Harness(items: EntitiesFakeItems(reads: [.failure(EntitiesFailure())]))
        guard case .loading = failing.model.phase else {
            Issue.record("expected loading")
            return
        }
        await failing.load()
        guard case .failed = failing.model.phase else {
            Issue.record("expected the failure")
            return
        }

        let gone = Harness(items: EntitiesFakeItems(lastRead: .value(nil)))
        await gone.load()
        guard case .gone = gone.model.phase else {
            Issue.record("expected gone")
            return
        }

        let form = Harness(items: EntitiesFakeItems(lastRead: .value(Self.drill)))
        await form.load()
        guard case .form = form.model.phase else {
            Issue.record("expected the form")
            return
        }
        #expect(form.model.values == ItemFormValues(name: "Cordless drill", category: "Tools", tags: "garage, power", quantity: "2", notes: ""))
        #expect(form.model.seed?.base.updatedAt == 10)
        #expect(!form.model.isDirty)
        #expect(!form.model.nameIsOptional)
    }

    @Test("seeded once per item: a background re-read never overwrites typing")
    func seedsOnce() async {
        var renamed = Self.drill
        renamed.item.name = "Drill"
        renamed.item.updatedAt = 20
        let harness = Harness(items: EntitiesFakeItems(reads: [.value(Self.drill)], lastRead: .value(renamed)))
        await harness.load()
        harness.model.values.notes = "In the red bin"
        harness.model.retry()
        await harness.model.query.readTask?.value
        #expect(harness.model.values.name == "Cordless drill")
        #expect(harness.model.values.notes == "In the red bin")
        #expect(harness.model.seed?.base.updatedAt == 10)
    }

    @Test("the guard asks only about real changes, holds the sheet while saving, and never asks while revoked")
    func dirtyGuard() async {
        let harness = Harness(items: EntitiesFakeItems(lastRead: .value(Self.drill)), confirms: [false, true])
        await harness.load()
        harness.model.values.name = " Cordless drill "
        harness.model.values.tags = "garage,power "
        #expect(!harness.model.isDirty)
        #expect(!harness.model.dirtyGuard.interactiveDismissDisabled)
        #expect(await harness.model.attemptClose())
        #expect(harness.confirms.asked.isEmpty)

        harness.model.values.notes = "Charger in the red bin"
        #expect(harness.model.isDirty)
        #expect(harness.model.dirtyGuard.interactiveDismissDisabled)
        // Keep editing, then Discard.
        #expect(await harness.model.attemptClose() == false)
        #expect(await harness.model.attemptClose())
        #expect(harness.confirms.asked.first?.title == L10n.Forms.discardTitle)
        #expect(harness.confirms.asked.first?.confirmLabel == L10n.Forms.discard)
        #expect(harness.confirms.asked.first?.cancelLabel == L10n.Forms.keepEditing)

        harness.model.setRevoked(true)
        #expect(await harness.model.attemptClose())
        #expect(harness.confirms.asked.count == 2)
    }

    @Test("a save closes the sheet, refreshes, says so and remembers the category; it stays saving")
    func saves() async {
        let items = EntitiesFakeItems(updates: [.value(EntitiesFixtures.item(updatedAt: 11))], lastRead: .value(Self.drill))
        let harness = Harness(items: items)
        await harness.load()
        harness.model.values.category = " Power tools "
        harness.model.values.notes = "Charger in the red bin"

        await harness.model.save()

        let call = await items.updates.first
        #expect(call?.input == UpdateItemInput(
            name: "Cordless drill",
            category: FieldUpdate("Power tools"),
            notes: FieldUpdate("Charger in the red bin"),
            tags: ["garage", "power"],
            expectedUpdatedAt: 10
        ))
        #expect(harness.log.entries == ["close", "invalidate"])
        #expect(harness.toasts.messages == [L10n.EditItem.saved])
        #expect(harness.recorded == ["Power tools"])
        #expect(harness.telemetry.names == ["item_updated"])
        #expect(harness.model.saving)
        #expect(!harness.model.dirtyGuard.guarded)
        // A second tap saves nothing more.
        await harness.model.save()
        #expect(await items.updates.count == 1)
        // Saved: Cancel closes without asking.
        #expect(await harness.model.attemptClose())
        #expect(harness.confirms.asked.isEmpty)
    }

    @Test("while a save writes, Cancel does nothing (RN disables it); once saved it closes, even when the sheet was not in front")
    func cancelWhileSaving() async {
        let items = EntitiesFakeItems(updates: [.value(EntitiesFixtures.item(updatedAt: 11))], lastRead: .value(Self.drill))
        let harness = Harness(items: items)
        await harness.load()
        harness.model.values.notes = "Charger in the red bin"
        await items.setHoldUpdates(true)
        harness.model.startSave()
        for _ in 0..<1000 where await items.heldCount == 0 { await Task.yield() }
        #expect(harness.model.saving)
        #expect(await harness.model.attemptClose() == false)
        #expect(harness.confirms.asked.isEmpty)

        // A link opened over the sheet mid-save: the save does not close it...
        harness.focused = false
        await items.releaseNextUpdate()
        await harness.model.saveTask?.value
        #expect(harness.log.entries == ["invalidate"])
        #expect(harness.model.saved)
        // ...and back in front, Cancel still can.
        #expect(await harness.model.attemptClose())
        #expect(harness.confirms.asked.isEmpty)
    }

    @Test("closed some other way mid-save, the sheet is not closed again; the toast still shows")
    func savesWhenClosed() async {
        let harness = Harness(items: EntitiesFakeItems(updates: [.value(EntitiesFixtures.item(updatedAt: 11))], lastRead: .value(Self.drill)))
        await harness.load()
        harness.focused = false
        await harness.model.save()
        #expect(harness.log.entries == ["invalidate"])
        #expect(harness.toasts.messages == [L10n.EditItem.saved])
    }

    @Test("an unnamed item may stay unnamed: the name is left out of the write")
    func staysUnnamed() async {
        let unnamed = EntitiesFixtures.context(name: "", updatedAt: 10)
        let items = EntitiesFakeItems(updates: [.value(EntitiesFixtures.item(name: "", updatedAt: 11))], lastRead: .value(unnamed))
        let harness = Harness(items: items)
        await harness.load()
        #expect(harness.model.nameIsOptional)
        harness.model.values.name = "  "
        harness.model.values.category = "Keys"
        await harness.model.save()
        #expect(await items.updates.first?.input.name == nil)
        #expect(harness.model.nameError == nil)
    }

    @Test("a cleared name is refused with its error and a focus request; typing clears the error")
    func requiresName() async {
        let harness = Harness(items: EntitiesFakeItems(lastRead: .value(Self.drill)))
        await harness.load()
        harness.model.values.name = "   "
        await harness.model.save()
        #expect(harness.model.nameError == L10n.Forms.itemNameRequired)
        #expect(harness.model.nameFocusRequests == 1)
        #expect(await harness.items.updates.isEmpty)
        #expect(!harness.model.saving)
        harness.model.values.notes = "x"
        #expect(harness.model.nameError == L10n.Forms.itemNameRequired)
        harness.model.values.name = "D"
        #expect(harness.model.nameError == nil)
    }

    @Test("deleted meanwhile: the error haptic and the gone state, with nothing to guard")
    func goneOnSave() async {
        let harness = Harness(items: EntitiesFakeItems(updates: [.value(nil)], lastRead: .value(Self.drill)))
        await harness.load()
        harness.model.values.notes = "x"
        await harness.model.save()
        #expect(harness.haptics.played == [.error])
        #expect(harness.model.gone)
        guard case .gone = harness.model.phase else {
            Issue.record("expected gone")
            return
        }
        #expect(!harness.model.dirtyGuard.guarded)
        #expect(!harness.model.saving)
    }

    @Test("a conflict keeps what was typed, fills in theirs, warns, and the next save goes over theirs")
    func conflict() async {
        var theirs = Self.drill
        theirs.item.notes = "Lent to Sam"
        theirs.item.updatedAt = 20
        let items = EntitiesFakeItems(
            updates: [.failure(ConflictError(updatedAt: 20)), .value(EntitiesFixtures.item(updatedAt: 21))],
            reads: [.value(Self.drill), .value(theirs)],
            lastRead: .value(theirs)
        )
        let harness = Harness(items: items)
        await harness.load()
        harness.model.values.category = "Power tools"

        await harness.model.save()
        #expect(harness.model.values.category == "Power tools")
        #expect(harness.model.values.notes == "Lent to Sam")
        #expect(harness.model.seed?.base.updatedAt == 20)
        #expect(harness.model.seed?.values.notes == "Lent to Sam")
        #expect(harness.haptics.played == [.warning])
        #expect(harness.model.notice == EditDetailsModel.Notice(title: nil, message: L10n.EditItem.conflict))
        #expect(!harness.model.saving)
        #expect(harness.model.isDirty)

        await harness.model.save()
        #expect(await items.stamps == [10, 20])
        #expect(harness.model.notice == nil)
        #expect(harness.toasts.messages == [L10n.EditItem.saved])
    }

    @Test("a failed save keeps the form: the connection's words when offline, else not saved")
    func failed() async {
        let offline = Harness(items: EntitiesFakeItems(updates: [.failure(HouseholdHttpError(status: 0, code: "offline"))], lastRead: .value(Self.drill)))
        await offline.load()
        offline.model.values.notes = "x"
        await offline.model.save()
        let described = describeError(HouseholdHttpError(status: 0, code: "offline"), context: .save, subject: .item)
        #expect(offline.model.notice == EditDetailsModel.Notice(title: described.title, message: described.body))
        #expect(offline.haptics.played == [.error])
        #expect(offline.telemetry.errors.map(\.name) == ["item_update_failed"])
        #expect(offline.model.values.notes == "x")
        #expect(offline.model.dirtyGuard.guarded)

        let local = Harness(items: EntitiesFakeItems(updates: [.failure(EntitiesFailure())], lastRead: .value(Self.drill)))
        await local.load()
        local.model.values.notes = "x"
        await local.model.save()
        #expect(local.model.notice == EditDetailsModel.Notice(title: nil, message: L10n.EditItem.notSaved))
    }

    @Test("the photo beside the name is the thumbnail, else the full photo; suggestions follow Category")
    func photoAndSuggestions() async {
        var item = Self.drill
        item.photoUri = "file:///full.webp"
        let harness = Harness(items: EntitiesFakeItems(lastRead: .value(item)))
        await harness.load()
        #expect(harness.model.photoUri == "file:///full.webp")
        harness.model.values.category = "To"
        #expect(harness.model.categorySuggestions == ["Tools", "Toys"])
    }
}
