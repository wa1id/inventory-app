import SwiftUI
import Testing
import UIKit
@testable import Inventory
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// The item area's wiring to the app (07 §3.2-3.5, 05 §13): the screens' factories against a
/// booted preview container and its real router, so Move, the filing run, Edit details, Delete
/// and the viewer reach the routes and repositories they should.
@Suite("Item screens (hosted)", .serialized)
@MainActor
struct ItemScreensWiringTests {
    private func bootedApp(confirms: Bool = false) async -> AppContainer {
        let platform = AppPlatform.silent(confirm: ItemScreensAnswering(confirms))
        let app = AppContainer.preview(platform: platform)
        await app.boot.run()
        return app
    }

    private func itemId(_ app: AppContainer, named name: String) async throws -> String {
        let items = try await app.repositories.items.listRecent(limit: 100)
        return try #require(items.first { $0.name == name }?.id)
    }

    private func loaded(_ model: ItemDetailModel, _ app: AppContainer) async {
        model.focusChanged(true, revision: app.database.revision)
        await ShellTestWait.until("the item's read") { model.stored != nil && model.dropZoneQuery?.isLoading != true }
    }

    @Test("File it… in a run opens the File sheet for a result, and the run replaces the screen with the next waiting item")
    func filingRun() async throws {
        let app = await bootedApp()
        let waiting = try await app.repositories.items.listUnsorted().map(\.id)
        let first = try #require(waiting.first)
        let entry = app.router.push(.item(id: first, filing: true))
        let model = ItemDetailScreen.makeModel(app: app, id: first, filing: true, address: entry.address)
        await loaded(model, app)
        #expect(model.progress == L10n.Item.progress(waiting: waiting.count))

        let filing = Task { await model.moveOrFile() }
        await ShellTestWait.until("the File sheet") { app.router.modals.count == 1 }
        let sheet = try #require(app.router.modals.last)
        guard case .sheet(.move(let itemId, let runStep, let request)) = sheet.route else {
            Issue.record("expected the File sheet, got \(sheet.route)")
            return
        }
        #expect(itemId == first)
        #expect(runStep)
        #expect(request != nil)

        // The sheet files it with a real MoveModel, as MoveSheet does.
        let move = MoveSheet.makeModel(app: app, filing: true, request: request, address: sheet.address)
        let read = InventoryQuery<ItemWithContext?>(key: "item:\(first)") { try await app.repositories.items.getById(first) }
        move.follow(read)
        read.focusChanged(true, revision: app.database.revision)
        await ShellTestWait.until("the sheet's read") { move.item != nil }
        let containers = try await app.repositories.containers.listAllWithSpace()
        let spaces = try await app.repositories.spaces.listWithCounts()
        let target = try #require(joinPlaceOptions(containers, spaces: spaces).first { $0.name == "Tool chest" })
        await move.pick(.container(target))
        await filing.value

        #expect(app.router.modals.isEmpty)
        let next = MoveFlow.nextInRun(before: waiting, currentId: first, waiting: waiting.filter { $0 != first })
        #expect(app.router.path(.home).map(\.route) == [.item(id: try #require(next), filing: true)])
        #expect(app.toasts.current?.options.message == "Filed in Tool chest (Garage).")
        #expect(try await app.repositories.items.getById(first)?.containerId == target.id)
    }

    @Test("Move outside a run leaves the item screen where it is, and the toast offers Undo")
    func moveOutsideRun() async throws {
        let app = await bootedApp()
        let drill = try await itemId(app, named: "Cordless drill")
        let entry = app.router.push(.item(id: drill, filing: false))
        let model = ItemDetailScreen.makeModel(app: app, id: drill, filing: false, address: entry.address)
        await loaded(model, app)

        let moving = Task { await model.moveOrFile() }
        await ShellTestWait.until("the Move sheet") { app.router.modals.count == 1 }
        let sheet = try #require(app.router.modals.last)
        guard case .sheet(.move(_, let runStep, let request)) = sheet.route else {
            Issue.record("expected the Move sheet")
            return
        }
        #expect(!runStep)
        let move = MoveSheet.makeModel(app: app, filing: false, request: request, address: sheet.address)
        move.loaded = try await app.repositories.items.getById(drill)
        let containers = try await app.repositories.containers.listAllWithSpace()
        let spaces = try await app.repositories.spaces.listWithCounts()
        let target = try #require(joinPlaceOptions(containers, spaces: spaces).first { $0.name == "Red bin" })
        await move.pick(.container(target))
        await moving.value

        #expect(app.router.modals.isEmpty)
        #expect(app.router.path(.home).map(\.route) == [.item(id: drill, filing: false)])
        #expect(app.toasts.current?.options.message == "Moved to Red bin (Garage).")
        #expect(app.toasts.current?.options.action?.label == L10n.Common.undo)
    }

    @Test("Delete confirms, goes back off the item screen, and the item is gone")
    func deletes() async throws {
        let app = await bootedApp(confirms: true)
        let keys = try await itemId(app, named: "Spare keys")
        let entry = app.router.push(.item(id: keys, filing: false))
        let model = ItemDetailScreen.makeModel(app: app, id: keys, filing: false, address: entry.address)
        await loaded(model, app)

        await model.delete()

        #expect(app.router.path(.home).isEmpty)
        #expect(try await app.repositories.items.getById(keys) == nil)
        #expect(app.toasts.current?.options.message == "“Spare keys” was deleted.")
    }

    @Test("Edit details saves over its seed, closes the sheet and says so")
    func editSaves() async throws {
        let app = await bootedApp()
        let drill = try await itemId(app, named: "Cordless drill")
        let sheet = app.router.present(.sheet(.itemEdit(id: drill)))
        let model = ItemEditSheet.makeModel(app: app, id: drill, address: sheet.address)
        model.focusChanged(true, revision: app.database.revision)
        await ShellTestWait.until("the seeded form") { model.seed != nil }
        #expect(model.values.notes == "Charger is in the red bin.")
        model.values.notes = "Charger is in the drawer."
        #expect(model.dirtyGuard.interactiveDismissDisabled)

        await model.save()

        #expect(app.router.modals.isEmpty)
        #expect(try await app.repositories.items.getById(drill)?.notes == "Charger is in the drawer.")
        #expect(app.toasts.current?.options.message == L10n.EditItem.saved)
    }

    @Test("the edit sheet's Cancel asks before discarding changes, through the router's close guard")
    func editGuard() async throws {
        let app = await bootedApp(confirms: false)
        let drill = try await itemId(app, named: "Cordless drill")
        let sheet = app.router.present(.sheet(.itemEdit(id: drill)))
        let model = ItemEditSheet.makeModel(app: app, id: drill, address: sheet.address)
        app.router.setCloseGuard(for: sheet.address) { await model.attemptClose() }
        model.focusChanged(true, revision: app.database.revision)
        await ShellTestWait.until("the seeded form") { model.seed != nil }
        model.values.tags = "power tools, cordless"

        await app.router.requestClose(sheet.address)
        // "Keep editing": the sheet stays.
        #expect(app.router.modals.count == 1)
        model.values.tags = "power tools"
        await app.router.requestClose(sheet.address)
        #expect(app.router.modals.isEmpty)
    }

    @Test("the photo opens as a cover over everything")
    func photoCover() async throws {
        let app = await bootedApp()
        let drill = try await itemId(app, named: "Cordless drill")
        let entry = app.router.push(.item(id: drill, filing: false))
        let model = ItemDetailScreen.makeModel(app: app, id: drill, filing: false, address: entry.address)
        await loaded(model, app)
        #expect(model.photoUri != nil)
        model.openPhoto()
        #expect(app.router.modals.map(\.route) == [.cover(.photo(itemId: drill))])
    }

    @Test("an unnamed item draws What is it? with its field")
    func rendersNameField() async throws {
        let app = await bootedApp()
        let unnamed = try #require(try await app.repositories.items.listUnsorted().first { $0.name.isEmpty }?.id)
        let host = try ShellTestWindow(
            NavigationStack { ItemDetailScreen(id: unnamed, filing: false) }
                .shellEnvironment(app)
        )
        defer { host.close() }
        await ShellTestWait.until("the name field") {
            host.window.shellDescendants.contains { ($0 as? UITextField)?.placeholder == L10n.Item.NameIt.placeholder }
        }
    }
}

/// Confirmations that always answer the same; action sheets run nothing.
@MainActor
final class ItemScreensAnswering: ConfirmPresenting, ShellActionSheetPresenting {
    private let answer: Bool

    init(_ answer: Bool) {
        self.answer = answer
    }

    func confirm(_ options: ConfirmOptions) async -> Bool { answer }

    func showActionSheet(_ sheet: ShellActionSheet) {}
}
