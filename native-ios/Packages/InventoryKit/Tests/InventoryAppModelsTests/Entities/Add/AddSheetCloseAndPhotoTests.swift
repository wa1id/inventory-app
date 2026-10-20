import Foundation
import InventoryCore
import InventoryServices
import InventoryStrings
import Testing
@testable import InventoryAppModels

/// The Add sheet's close guard (its own Cancel through `.sheetCloseGuard`, RN `cancel`,
/// app/item/new.tsx:438-454) and the thumbnail's photo options (RN `photoOptions`, :407-421;
/// 07 §0.8). No RN tests exist for these; they pin the RN behaviour.
@MainActor
@Suite("Add sheet close guard and photo options (app/item/new.tsx)")
struct AddSheetCloseAndPhotoTests {
    typealias Harness = EntitiesAddSheetModelTests.Harness

    private static let photoParams = AddParams(photoUri: "file:///p.webp", photoThumbUri: "file:///t.webp")

    @Test("with nothing typed the sheet may close at once, and nothing is asked")
    func closesWhenEmpty() async {
        let harness = Harness()
        let model = harness.makeModel()
        model.start()
        #expect(await model.confirmCancel())
        #expect(harness.confirm.asked.isEmpty)
        #expect(harness.screen.closes == 0, "the guard answers; the router closes")
    }

    @Test("Keep editing keeps the sheet, its photo and its draft; Discard deletes the photo and forgets the draft")
    func asksBeforeDiscarding() async {
        let harness = Harness(confirm: SharedSeamsConfirmScript(answers: [false, true]))
        let model = harness.makeModel(Self.photoParams)
        model.start()
        model.name = "Drill"

        #expect(await model.confirmCancel() == false)
        #expect(harness.confirm.asked == [
            ConfirmOptions(title: L10n.Add.discardTitle, body: L10n.Add.discardBody, confirmLabel: L10n.Forms.discard, cancelLabel: L10n.Forms.keepEditing),
        ])
        #expect(harness.photos.deleted.isEmpty)
        #expect(harness.drafts.restorableDraft(now: harness.now)?.state.values.name == "Drill")

        #expect(await model.confirmCancel())
        #expect(harness.photos.deleted == [["file:///p.webp", "file:///t.webp"]])
        #expect(harness.drafts.restorableDraft(now: harness.now) == nil)
        // Gone: a late edit writes no draft.
        model.name = "Drill press"
        #expect(harness.drafts.restorableDraft(now: harness.now) == nil)
    }

    @Test("while saving the guard keeps the sheet and asks nothing")
    func keepsWhileSaving() async {
        let items = EntitiesFakeItems()
        await items.setHoldCreates(true)
        let harness = Harness(items: items, confirm: SharedSeamsConfirmScript(answers: [true]))
        let model = harness.makeModel()
        model.name = "Drill"
        let saving = Task { await model.save(andAnother: false) }
        await EntitiesFakeItems.waitForHeld(items, count: 1)

        #expect(await model.confirmCancel() == false)
        #expect(harness.confirm.asked.isEmpty)

        await items.releaseNextUpdate()
        await saving.value
    }

    @Test("the thumbnail offers Retake and Remove photo, the second destructive; nothing without a photo or while saving")
    func photoOptions() async throws {
        let harness = Harness()
        #expect(harness.makeModel().photoOptionsSheet() == nil)

        let model = harness.makeModel(Self.photoParams)
        let sheet = try #require(model.photoOptionsSheet())
        #expect(sheet.options.map(\.label) == [L10n.Add.retake, L10n.Add.removePhoto])
        #expect(sheet.options.map(\.destructive) == [false, true])
        #expect(sheet.title == nil)
        #expect(sheet.cancelLabel == nil, "the system Cancel")

        let items = EntitiesFakeItems()
        await items.setHoldCreates(true)
        let busy = Harness(items: items)
        let saving = busy.makeModel(Self.photoParams)
        saving.name = "Drill"
        let save = Task { await saving.save(andAnother: false) }
        await EntitiesFakeItems.waitForHeld(items, count: 1)
        #expect(saving.photoOptionsSheet() == nil)
        await items.releaseNextUpdate()
        await save.value
    }

    @Test("Remove photo deletes both files and hides the banner; Retake drops the photo, then opens the camera")
    func photoOptionHandlers() async throws {
        let harness = Harness()
        harness.camera.photos = [StoredImage(uri: "file:///new.webp", thumbUri: "file:///new-thumb.webp", width: 800, height: 600, byteSize: nil)]
        let model = harness.makeModel(AddParams(containerId: "chest", photoUri: "file:///p.webp", photoThumbUri: "file:///t.webp"))
        model.start()

        let sheet = try #require(model.photoOptionsSheet())
        sheet.options[0].handler()
        await waitUntil { model.photo?.uri == "file:///new.webp" }
        #expect(harness.photos.deleted.first == ["file:///p.webp", "file:///t.webp"])
        #expect(harness.camera.opened == ["chest"])

        let again = try #require(model.photoOptionsSheet())
        again.options[1].handler()
        #expect(model.photo == nil)
        #expect(model.suggestionBanner == nil)
        #expect(harness.photos.deleted.last == ["file:///new.webp", "file:///new-thumb.webp"])
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("condition never held")
    }
}
