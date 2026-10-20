#if DEBUG
import Foundation
import InventoryAppModels
import InventoryCore

/// DEBUG demo hooks for the item area: the item screen, its edit sheet, Move and File, and the photo viewer.
///
/// They let every state be screenshotted without tapping:
/// `mac.sh run out.png -demo YES -demoArea item -demoState <state> -demoRoute <spec>`. Most states
/// need only a route on the seeded inventory (`docs/UI-KIT.md` §5.3):
///
/// | State | Launch arguments |
/// |---|---|
/// | an item with a photo, tags and notes | `-demoRoute item:Cordless_drill` |
/// | an item without a photo | `-demoRoute item:Screwdriver_set` |
/// | none left | `-demoRoute item:Printer_ink` |
/// | in the drop zone (File it…) | `-demoRoute item:HDMI_cable` |
/// | unnamed, a filing run (field focused, "4 waiting") | `-demoRoute itemFiling:` |
/// | Edit details | `-demoRoute 'item:Cordless_drill>itemEdit:Cordless_drill'` |
/// | Move / File | `-demoRoute move:Cordless_drill`, `-demoRoute file:HDMI_cable` |
/// | the viewer; a photo that is missing | `-demoRoute photo:Cordless_drill`, `-demoRoute photo:Screwdriver_set` |
///
/// The states below act once the screen has read its item (`-demoArea item -demoState <state>`):
///
/// | State | With | Shows |
/// |---|---|---|
/// | `nameMeanwhile` | `itemFiling:` | a name typed, then recognition's name met on save: the notice and "Use “AA batteries”" |
/// | `deleteConfirm` | `item:<name>` | the delete confirmation |
/// | `fileRun` | `itemFiling:<name>` | File it… picks the first container: the run goes on to the next item |
/// | `editDirty` | `itemEdit:<name>` | the form with changes (notes and tags) |
/// | `editDiscard` | `itemEdit:<name>` | changes, then Cancel: "Discard your changes?" |
/// | `editConflict` | `itemEdit:Cordless_drill` | a change made elsewhere meanwhile: the conflict banner, theirs filled in |
/// | `editNameError` | `itemEdit:<name>` | the name cleared and saved: "Give it a name." |
/// | `moveGone` | `move:<name>` | the item deleted elsewhere, then a pick: the notice with Close |
/// | `moveElsewhere` | `move:<name>` | the item moved elsewhere first, then a pick: where it is now |
enum ItemDemo {
    /// `-demoState` once the shell runs this area's hook.
    @MainActor private static var state = ""
    /// Each state acts once per launch.
    @MainActor private static var acted: Set<String> = []

    /// The container to run on for `state`, or nil for the default demo container (the seeded
    /// inventory in memory, or an empty one with `-demoSeed empty`).
    @MainActor
    static func container(state: String, platform: AppPlatform) -> AppContainer? {
        nil
    }

    /// Runs once the main shell shows, after `-demoTab` and before `-demoRoute`: remembers the
    /// state for the screens' hooks below.
    @MainActor
    static func run(state: String, app: AppContainer) async {
        self.state = state
    }

    /// Whether `name` is the state asked for and has not acted yet.
    @MainActor
    private static func takes(_ name: String) -> Bool {
        guard state == name, !acted.contains(name) else { return false }
        acted.insert(name)
        return true
    }

    /// The item screen has read its item.
    @MainActor
    static func itemLoaded(_ model: ItemDetailModel, app: AppContainer) async {
        if takes("nameMeanwhile"), let field = model.nameField, let stored = model.stored {
            field.value = "Batteries"
            // Recognition names it between the read and the save.
            _ = try? await app.repositories.items.update(stored.id, UpdateItemInput(name: "AA batteries"))
            await field.save()
        } else if takes("fileRun") {
            try? await Task.sleep(for: .milliseconds(800))
            model.startMoveOrFile()
        } else if takes("deleteConfirm") {
            try? await Task.sleep(for: .milliseconds(600))
            model.startDelete()
        }
    }

    /// The edit sheet has seeded its form.
    @MainActor
    static func editSeeded(_ model: EditDetailsModel, app: AppContainer, address: ScreenAddress?) async {
        if takes("editDirty") {
            model.values.notes = "Charger is in the red bin. The spare battery is in the drawer."
            model.values.tags += ", cordless"
        } else if takes("editDiscard") {
            model.values.notes += " Lent to Sam."
            try? await Task.sleep(for: .milliseconds(600))
            if let address { await app.router.requestClose(address) }
        } else if takes("editConflict"), let stored = model.stored {
            model.values.category = "Power tools"
            // Another phone changes the notes after the sheet was filled.
            _ = try? await app.repositories.items.update(stored.id, UpdateItemInput(notes: FieldUpdate("Lent to Sam until Friday.")))
            await model.save()
        } else if takes("editNameError") {
            model.values.name = ""
            await model.save()
        }
    }

    /// The Move sheet has read its item.
    @MainActor
    static func moveLoaded(_ move: MoveModel, app: AppContainer) async {
        guard let item = move.item else { return }
        if state == "fileRun", !acted.contains("fileRun-move") {
            acted.insert("fileRun-move")
            try? await Task.sleep(for: .milliseconds(800))
            if let target = await target(for: item, app: app) { await move.pick(.container(target)) }
        } else if takes("moveGone") {
            _ = try? await app.repositories.items.delete(item.id)
            if let target = await target(for: item, app: app) { await move.pick(.container(target)) }
        } else if takes("moveElsewhere") {
            guard let elsewhere = await target(for: item, app: app, skipping: 1) else { return }
            _ = try? await app.repositories.items.update(item.id, UpdateItemInput(containerId: elsewhere.id))
            if let target = await target(for: item, app: app) { await move.pick(.container(target)) }
        }
    }

    /// A container the item is not in, as the picker offers it.
    @MainActor
    private static func target(for item: ItemWithContext, app: AppContainer, skipping: Int = 0) async -> PlaceOption? {
        let containers = (try? await app.repositories.containers.listAllWithSpace()) ?? []
        let spaces = (try? await app.repositories.spaces.listWithCounts()) ?? []
        let options = joinPlaceOptions(containers, spaces: spaces).filter { $0.id != item.containerId }
        return options.dropFirst(skipping).first
    }
}
#endif
