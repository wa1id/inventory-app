import SwiftUI
import Testing
import UIKit
@testable import Inventory
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// `PlacePickerHost`'s wiring to the app (07 §4.1 "Create inline", §0.9): the forms open through
/// the router for a result, and what they make reaches the screen's `onPick`.
@Suite("Place picker host (hosted)", .serialized)
@MainActor
struct FoundationPlacePickerHostTests {
    private func bootedApp(seed: Bool = true) async -> AppContainer {
        let app = AppContainer.preview(seed: seed)
        await app.boot.run()
        return app
    }

    private func loadedModel(_ app: AppContainer, mode: PlacePickerMode, onPick: @escaping @MainActor (PickedPlace) -> Void) async -> PlacePickerModel {
        let model = PlacePickerHost<EmptyView>.makeModel(app: app, mode: mode, onPick: onPick)
        model.focusChanged(true, revision: app.database.revision)
        await ShellTestWait.until("the picker's lists") { !model.isLoading }
        return model
    }

    @Test("New container in a space opens the form for a result and hands the created container to onPick")
    func inlineCreateContainer() async throws {
        let app = await bootedApp()
        var picked: [PickedPlace] = []
        let model = await loadedModel(app, mode: .move) { picked.append($0) }
        let garage = try #require(model.spaces.data?.first { $0.name == "Garage" })

        let creating = Task { await model.newContainer(in: garage.id, spaceName: garage.name) }
        await ShellTestWait.until("the new-container form") { app.router.modals.count == 1 }
        guard case .sheet(.containerNew(let spaceId, let request))? = app.router.modals.last?.route else {
            Issue.record("expected the new-container form, got \(String(describing: app.router.modals.last?.route))")
            return
        }
        #expect(spaceId == garage.id)
        #expect(request != nil)

        // The form saves and answers, as ContainerNewSheet will.
        let created = try await app.repositories.containers.create(CreateContainerInput(spaceId: garage.id, name: "Paint shelf", visualType: .shelf))
        #expect(app.router.results.deliver(request, NewContainerResult(created)))
        await creating.value

        #expect(picked.count == 1)
        guard case .container(let option)? = picked.first else {
            Issue.record("expected a container pick")
            return
        }
        #expect(option.id == created.id)
        #expect(option.name == "Paint shelf")
        #expect(option.shortCode == created.shortCode)
        #expect(option.spaceName == "Garage")
        #expect(option.spaceColor == garage.color)
        #expect(option.itemCount == 0)
    }

    @Test("with no containers at all, New space waits for the space, then the container form, and picks that")
    func inlineCreateSpaceThenContainer() async throws {
        let app = await bootedApp(seed: false)
        var picked: [PickedPlace] = []
        let model = await loadedModel(app, mode: .file) { picked.append($0) }
        #expect(model.isNothingAtAll)

        let creating = Task { await model.newSpace() }
        await ShellTestWait.until("the new-space form") { app.router.modals.count == 1 }
        let spaceForm = try #require(app.router.modals.last)
        guard case .sheet(.spaceNew(let spaceRequest)) = spaceForm.route else {
            Issue.record("expected the new-space form")
            return
        }
        let space = try await app.repositories.spaces.create(CreateSpaceInput(name: "Hall", icon: "🚪", color: "#E07A5F"))
        // The form answers and closes itself in one step, as SpaceNewSheet will; the picker
        // resumes after that.
        #expect(app.router.results.deliver(spaceRequest, NewSpaceResult(space)))
        app.router.close(spaceForm.address)

        await ShellTestWait.until("the new-container form") {
            if case .sheet(.containerNew)? = app.router.modals.last?.route { return true }
            return false
        }
        guard case .sheet(.containerNew(let spaceId, let containerRequest))? = app.router.modals.last?.route else { return }
        #expect(spaceId == space.id)
        let created = try await app.repositories.containers.create(CreateContainerInput(spaceId: space.id, name: nil, visualType: .box))
        #expect(app.router.results.deliver(containerRequest, NewContainerResult(created)))
        await creating.value

        guard case .container(let option)? = picked.first else {
            Issue.record("expected a container pick")
            return
        }
        #expect(option.id == created.id)
        #expect(option.spaceName == "Hall")
    }

    @Test("a form closed without answering picks nothing, and the next tap opens a form again")
    func abandonedForm() async throws {
        let app = await bootedApp()
        var picked: [PickedPlace] = []
        let model = await loadedModel(app, mode: .choose) { picked.append($0) }
        let garage = try #require(model.spaces.data?.first)

        let first = Task { await model.newContainer(in: garage.id, spaceName: garage.name) }
        await ShellTestWait.until("the form") { app.router.modals.count == 1 }
        let entry = try #require(app.router.modals.last)
        app.router.close(entry.address)
        await first.value
        #expect(picked.isEmpty)

        let second = Task { await model.newContainer(in: garage.id, spaceName: garage.name) }
        await ShellTestWait.until("the form again") { app.router.modals.count == 1 }
        app.router.dismissAll()
        await second.value
        #expect(picked.isEmpty)
    }

    @Test("open mode's New space opens the form without waiting")
    func openModeNewSpace() async {
        let app = await bootedApp(seed: false)
        let model = await loadedModel(app, mode: .open) { _ in }
        await model.newSpace()
        #expect(app.router.modals.map(\.route) == [.sheet(.spaceNew(request: nil))])
    }

    @Test("the host draws the picker in a navigation stack with the stock search field")
    func hostRenders() async throws {
        let app = await bootedApp()
        let host = try ShellTestWindow(
            NavigationStack { PlacePickerHost(mode: .choose, showsDropZone: true) { _ in } }
                .shellEnvironment(app)
        )
        defer { host.close() }
        await ShellTestWait.until("the search field") {
            host.window.shellDescendants.contains { $0 is UISearchTextField }
        }
        let field = host.window.shellDescendants.compactMap { $0 as? UISearchTextField }.first
        #expect(field?.placeholder == L10n.Picker.filter)
    }
}
