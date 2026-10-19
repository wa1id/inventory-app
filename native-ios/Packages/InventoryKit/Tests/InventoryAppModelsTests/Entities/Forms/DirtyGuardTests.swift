import Foundation
import InventoryCore
import InventoryStrings
import Testing
@testable import InventoryAppModels

/// `useDirtyGuard` (src/hooks/useDirtyGuard.ts; 07 §4.16). RN has no tests for the hook.
@MainActor
@Suite("DirtyGuard (useDirtyGuard.ts)")
struct EntitiesDirtyGuardTests {
    @Test("a clean form closes without asking")
    func clean() async {
        let confirm = SharedSeamsConfirmScript()
        let guardModel = DirtyGuard(confirm: confirm)
        #expect(await guardModel.attemptClose())
        #expect(confirm.asked.isEmpty)
        #expect(!guardModel.interactiveDismissDisabled)
    }

    @Test("a dirty form asks, keeps editing on Cancel and discards on Discard")
    func dirty() async {
        let confirm = SharedSeamsConfirmScript(answers: [false, true])
        let guardModel = DirtyGuard(confirm: confirm, dirty: true)
        var discarded = 0
        #expect(guardModel.interactiveDismissDisabled)
        let first = await guardModel.attemptClose(onDiscard: { discarded += 1 })
        #expect(!first)
        #expect(discarded == 0)
        let second = await guardModel.attemptClose(onDiscard: { discarded += 1 })
        #expect(second)
        #expect(discarded == 1)
        #expect(confirm.asked == [
            ConfirmOptions(title: L10n.Forms.discardTitle, body: L10n.Forms.discardBody, confirmLabel: L10n.Forms.discard, cancelLabel: L10n.Forms.keepEditing),
            ConfirmOptions(title: L10n.Forms.discardTitle, body: L10n.Forms.discardBody, confirmLabel: L10n.Forms.discard, cancelLabel: L10n.Forms.keepEditing),
        ])
        #expect(confirm.asked.first?.destructive == true)
    }

    @Test("while saving it does not ask, so a save that closes the form never asks; the swipe stays off")
    func saving() async {
        let confirm = SharedSeamsConfirmScript()
        let guardModel = DirtyGuard(confirm: confirm, dirty: true, saving: true)
        #expect(!guardModel.guarded)
        #expect(guardModel.interactiveDismissDisabled)
        #expect(await guardModel.attemptClose())
        #expect(confirm.asked.isEmpty)
        guardModel.dirty = false
        #expect(guardModel.interactiveDismissDisabled)
    }

    @Test("while the phone is removed it never asks")
    func revoked() async {
        let confirm = SharedSeamsConfirmScript()
        let guardModel = DirtyGuard(confirm: confirm, dirty: true)
        guardModel.revoked = true
        #expect(!guardModel.guarded)
        #expect(await guardModel.attemptClose())
        #expect(confirm.asked.isEmpty)
    }

    @Test("a form may ask its own question")
    func customTitle() async {
        let confirm = SharedSeamsConfirmScript(answers: [true])
        let guardModel = DirtyGuard(confirm: confirm, title: "Discard this space?", dirty: true)
        _ = await guardModel.attemptClose()
        #expect(confirm.asked.first?.title == "Discard this space?")
    }
}

/// The form's warning banner (src/ui/spaces/FormLayout.tsx `SaveNotice`).
@Suite("SaveNoticeCopy (FormLayout.tsx)")
struct EntitiesSaveNoticeCopyTests {
    @Test("a local failure has no title; others carry the described title")
    func titles() {
        let local = SaveNoticeCopy(cause: EntitiesFailure("SQLITE_BUSY"), subject: .item)
        #expect(local.title == nil)
        #expect(local.message == L10n.Errors.Local.save)
        let gone = SaveNoticeCopy(cause: nil, subject: .container)
        #expect(gone.title == L10n.Errors.Gone.container)
        #expect(gone.message == L10n.Errors.Gone.body)
        let offline = SaveNoticeCopy(cause: HouseholdHttpError(status: 0, code: "offline"), subject: .space)
        #expect(offline.title == L10n.Errors.Offline.title)
        #expect(offline.message == L10n.Errors.Offline.save)
    }
}
