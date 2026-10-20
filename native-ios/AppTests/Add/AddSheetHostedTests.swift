import SwiftUI
import Testing
import UIKit
@testable import Inventory
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// The Add sheet's view wiring that is easy to get wrong (06 §10, UI-KIT §1.6-§1.7): one model
/// for the sheet's life, the removal hook (a swipe keeps the draft), the close guard behind its
/// own Cancel, the places read following the sheet's focus and the revision, and the place step
/// swapping the picker in and out.
@Suite("Add sheet (hosted)", .serialized)
@MainActor
struct AddSheetHostedTests {
    private struct Fixture {
        let app: AppContainer
        let entry: ModalEntry
        let host: ShellTestWindow
        let model: AddSheetModel
        let confirm: AddHostedConfirmScript
    }

    private func fixture(_ params: AddParams = AddParams(), confirm answers: [Bool] = []) async throws -> Fixture {
        let confirm = AddHostedConfirmScript(answers: answers)
        let app = AppContainer.preview(platform: .silent(confirm: confirm))
        await app.boot.run()
        let entry = app.router.present(.sheet(.addItem(params)))
        let previous = AddDemo.currentModel
        let host = try ShellTestWindow(AddHostedSheet(app: app, entry: entry, params: params))
        await ShellTestWait.until("the sheet's model") { AddDemo.currentModel != nil && AddDemo.currentModel !== previous }
        let model = try #require(AddDemo.currentModel)
        return Fixture(app: app, entry: entry, host: host, model: model, confirm: confirm)
    }

    @Test("the sheet makes one model and starts it; a swipe-down keeps what was typed for the next plain open")
    func removalKeepsTheDraft() async throws {
        let fixture = try await fixture(AddParams(name: "Torch"))
        defer { fixture.host.close() }
        let model = fixture.model
        let app = fixture.app
        #expect(app.drafts.restorableDraft(now: app.now())?.state.values.name == "Torch", "started: the draft follows the form")

        app.router.modalDismissedBySystem(fixture.entry.id)
        // Gone: a late change (an answer, a stray binding write) writes no draft.
        model.name = "Torch, red"
        #expect(app.drafts.restorableDraft(now: app.now())?.state.values.name == "Torch")
        #expect(AddDemo.currentModel === model)
    }

    @Test("its own Cancel asks through the sheet's close guard before throwing typing away")
    func cancelThroughTheGuard() async throws {
        let fixture = try await fixture(confirm: [false, true])
        defer { fixture.host.close() }
        let app = fixture.app
        fixture.model.name = "Torch"

        await app.router.requestClose(fixture.entry.address)
        #expect(fixture.confirm.asked.map(\.title) == [L10n.Add.discardTitle])
        #expect(app.router.modals.map(\.id) == [fixture.entry.id])

        await app.router.requestClose(fixture.entry.address)
        #expect(app.router.modals.isEmpty)
        #expect(app.drafts.restorableDraft(now: app.now()) == nil)
    }

    @Test("the places are read while the sheet is in front, and again when it comes back to the front")
    func placesFollowFocusAndRevision() async throws {
        let fixture = try await fixture()
        defer { fixture.host.close() }
        let app = fixture.app
        let model = fixture.model
        await ShellTestWait.until("the places") { model.places != nil }
        let count = model.places?.count ?? 0
        let garage = try #require(try await app.repositories.spaces.listWithCounts().first { $0.name == "Garage" })

        _ = try await app.repositories.containers.create(CreateContainerInput(spaceId: garage.id, name: "Paint shelf", visualType: .shelf))
        app.database.invalidate()
        await ShellTestWait.until("the new container") { model.places?.count == count + 1 }

        // Under another sheet, the sheet does not read.
        let over = app.router.present(.sheet(.spaceNew(request: nil)))
        _ = try await app.repositories.containers.create(CreateContainerInput(spaceId: garage.id, name: "Glue box", visualType: .box))
        app.database.invalidate()
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.places?.count == count + 1)

        app.router.close(over.address)
        await ShellTestWait.until("the read on coming back") { model.places?.count == count + 2 }
    }

    @Test("Somewhere else swaps in the picker with its search field; a pick brings the form back with the place chosen")
    func placeStep() async throws {
        let fixture = try await fixture()
        defer { fixture.host.close() }
        let model = fixture.model
        let window = fixture.host.window
        await ShellTestWait.until("the places") { model.places != nil }
        #expect(!window.shellDescendants.contains { $0 is UISearchTextField })

        model.showPlaceStep()
        await ShellTestWait.until("the picker's search field") {
            window.shellDescendants.contains { $0 is UISearchTextField }
        }
        let chest = try #require(model.places?.first { $0.name == "Tool chest" })
        model.pickPlace(.container(chest))
        await ShellTestWait.until("the form again") {
            !window.shellDescendants.contains { $0 is UISearchTextField }
        }
        #expect(model.place.id == chest.id)
        #expect(model.entries.first == .container(chest, source: .picked))
    }
}

/// The sheet as the shell presents it: in its own navigation stack, with its address and its
/// focus from the router.
private struct AddHostedSheet: View {
    let app: AppContainer
    let entry: ModalEntry
    let params: AddParams

    var body: some View {
        NavigationStack {
            AddSheet(params: params)
                .environment(\.screenAddress, entry.address)
                .environment(\.isScreenFocused, app.router.isFocused(entry.address))
        }
        .shellEnvironment(app)
    }
}

/// Answers the sheet's confirmations from a script.
@MainActor
final class AddHostedConfirmScript: ConfirmPresenting {
    private(set) var asked: [ConfirmOptions] = []
    private var answers: [Bool]

    init(answers: [Bool]) {
        self.answers = answers
    }

    func confirm(_ options: ConfirmOptions) async -> Bool {
        asked.append(options)
        return answers.isEmpty ? false : answers.removeFirst()
    }
}
