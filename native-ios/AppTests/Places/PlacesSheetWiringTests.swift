import SwiftUI
import Testing
@testable import Inventory
import InventoryAppModels
import InventoryCore

/// The space and container sheets' wiring to the router (07 §3.6, §3.8, §3.11, §3.13; UI-KIT
/// §5.1): built through the screens' own factories on a booted preview container, so the
/// navigation each model asks for lands where RN's did.
@Suite("Places sheets' wiring (hosted)", .serialized)
@MainActor
struct PlacesSheetWiringTests {
    private func bootedApp(seed: Bool = true, confirm: PlacesAppConfirm = PlacesAppConfirm(answer: false)) async -> AppContainer {
        let app = AppContainer.preview(platform: .silent(confirm: confirm), seed: seed)
        await app.boot.run()
        return app
    }

    private func space(_ app: AppContainer, named name: String) async throws -> SpaceWithCounts {
        try #require(try await app.repositories.spaces.listWithCounts().first { $0.name == name })
    }

    private func container(_ app: AppContainer, named name: String) async throws -> ContainerWithSpace {
        try #require(try await app.repositories.containers.listAllWithSpace().first { $0.name == name })
    }

    @Test("New container from the picker hands the container back and closes in the same step")
    func newContainerFromThePicker() async throws {
        let app = await bootedApp()
        var picked: [PickedPlace] = []
        let picker = PlacePickerHost<EmptyView>.makeModel(app: app, mode: .move) { picked.append($0) }
        picker.focusChanged(true, revision: app.database.revision)
        await ShellTestWait.until("the picker's lists") { !picker.isLoading }
        let garage = try #require(picker.spaces.data?.first { $0.name == "Garage" })

        let creating = Task { await picker.newContainer(in: garage.id, spaceName: garage.name) }
        await ShellTestWait.until("the new-container form") { app.router.modals.count == 1 }
        let modal = try #require(app.router.modals.last)
        guard case .sheet(.containerNew(let spaceId, let request)) = modal.route else {
            Issue.record("expected the new-container form, got \(modal.route)")
            return
        }
        let form = ContainerNewSheet.makeModel(app: app, spaceId: spaceId, request: request, address: modal.address)
        form.setVisualType(.shelf)
        form.setName("Paint shelf")

        await form.save()
        // Closed as it delivered, before the picker resumed; nothing was pushed.
        #expect(app.router.modals.isEmpty)
        #expect(app.router.path(app.router.selectedTab).isEmpty)
        await creating.value

        guard case .container(let option)? = picked.first else {
            Issue.record("expected the new container to be picked")
            return
        }
        #expect(option.name == "Paint shelf")
        #expect(option.visualType == .shelf)
        #expect(option.spaceName == "Garage")
    }

    @Test("with nothing waiting, New container opens the container in place of the sheet")
    func newContainerOpensIt() async throws {
        let app = await bootedApp()
        let garage = try await space(app, named: "Garage")
        app.router.selectTab(.spaces)
        app.router.push(.space(id: garage.id))
        let modal = app.router.present(.sheet(.containerNew(spaceId: garage.id, request: nil)))

        let form = ContainerNewSheet.makeModel(app: app, spaceId: garage.id, request: nil, address: modal.address)
        await form.save()

        #expect(app.router.modals.isEmpty)
        let made = try #require(try await app.repositories.containers.listBySpace(garage.id).first { $0.name == nil && $0.visualType == .box && $0.shortCode != "BOX-7K2M" })
        #expect(app.router.path(.spaces).map(\.route) == [.space(id: garage.id), .container(id: made.id)])
    }

    @Test("New space with nothing waiting opens the space in place of the sheet")
    func newSpaceOpensIt() async throws {
        let app = await bootedApp()
        app.router.selectTab(.spaces)
        let modal = app.router.present(.sheet(.spaceNew(request: nil)))
        let form = SpaceNewSheet.makeModel(app: app, request: nil, address: modal.address)
        let loft = try #require(SpacePalette.presets.first { $0.name == "Loft" })

        await form.pickPreset(loft)

        #expect(app.router.modals.isEmpty)
        let made = try await space(app, named: "Loft")
        #expect(app.router.path(.spaces).map(\.route) == [.space(id: made.id)])
    }

    @Test("from an empty picker: New space answers, then the container form opens in it, and its container is picked")
    func newSpaceThenContainerFromThePicker() async throws {
        let app = await bootedApp(seed: false)
        var picked: [PickedPlace] = []
        let picker = PlacePickerHost<EmptyView>.makeModel(app: app, mode: .file) { picked.append($0) }
        picker.focusChanged(true, revision: app.database.revision)
        await ShellTestWait.until("the picker's lists") { !picker.isLoading }
        #expect(picker.isNothingAtAll)

        let creating = Task { await picker.newSpace() }
        await ShellTestWait.until("the new-space form") { app.router.modals.count == 1 }
        let spaceModal = try #require(app.router.modals.last)
        guard case .sheet(.spaceNew(let spaceRequest)) = spaceModal.route else {
            Issue.record("expected the new-space form")
            return
        }
        let spaceForm = SpaceNewSheet.makeModel(app: app, request: spaceRequest, address: spaceModal.address)
        spaceForm.change(SpaceFormValues(name: "Hall", icon: "🚪", color: "#E0A800"))
        await spaceForm.createCustom()
        #expect(app.router.modals.isEmpty)

        await ShellTestWait.until("the new-container form") {
            if case .sheet(.containerNew)? = app.router.modals.last?.route { return true }
            return false
        }
        let containerModal = try #require(app.router.modals.last)
        guard case .sheet(.containerNew(let spaceId, let containerRequest)) = containerModal.route else { return }
        let hall = try await space(app, named: "Hall")
        #expect(spaceId == hall.id)
        let containerForm = ContainerNewSheet.makeModel(app: app, spaceId: spaceId, request: containerRequest, address: containerModal.address)
        await containerForm.save()
        await creating.value

        #expect(app.router.modals.isEmpty)
        guard case .container(let option)? = picked.first else {
            Issue.record("expected a container pick")
            return
        }
        #expect(option.spaceName == "Hall")
        #expect(app.router.path(app.router.selectedTab).isEmpty)
    }

    @Test("deleting a container closes everything and opens the space it was stored in")
    func deleteContainerOpensItsSpace() async throws {
        let confirm = PlacesAppConfirm(answer: true)
        let app = await bootedApp(confirm: confirm)
        let chest = try await container(app, named: "Tool chest")
        // Opened from search on Home, never through its space.
        app.router.push(.container(id: chest.id))
        let modal = app.router.present(.sheet(.containerEdit(id: chest.id)))
        let form = ContainerEditSheet.makeModel(app: app, id: chest.id, address: modal.address)
        form.focusChanged(true, revision: app.database.revision)
        await ShellTestWait.until("the stored container") { form.stored != nil }

        await form.delete()

        #expect(confirm.asked.first?.title == "Delete Tool chest?")
        #expect(app.router.modals.isEmpty)
        #expect(app.router.selectedTab == .home)
        #expect(app.router.path(.home).map(\.route) == [.space(id: chest.spaceId)])
        #expect(try await app.repositories.containers.getById(chest.id) == nil)
    }

    @Test("deleting a space goes to the Spaces tab with everything closed")
    func deleteSpaceGoesToSpaces() async throws {
        let app = await bootedApp(confirm: PlacesAppConfirm(answer: true))
        let attic = try await space(app, named: "Attic")
        app.router.selectTab(.spaces)
        app.router.push(.space(id: attic.id))
        let modal = app.router.present(.sheet(.spaceEdit(id: attic.id)))
        let form = SpaceEditSheet.makeModel(app: app, id: attic.id, address: modal.address)
        form.focusChanged(true, revision: app.database.revision)
        await ShellTestWait.until("the stored space") { form.stored != nil }

        await form.delete()

        #expect(app.router.modals.isEmpty)
        #expect(app.router.selectedTab == .spaces)
        #expect(app.router.path(.spaces).isEmpty)
        #expect(try await app.repositories.spaces.getById(attic.id) == nil)
    }

    @Test("saving an edit closes only its sheet; the screen under it reads the change")
    func saveClosesTheSheet() async throws {
        let app = await bootedApp()
        let chest = try await container(app, named: "Tool chest")
        app.router.selectTab(.spaces)
        app.router.push(.container(id: chest.id))
        let modal = app.router.present(.sheet(.containerEdit(id: chest.id)))
        let form = ContainerEditSheet.makeModel(app: app, id: chest.id, address: modal.address)
        form.focusChanged(true, revision: app.database.revision)
        await ShellTestWait.until("the stored container") { form.stored != nil }
        let revision = app.database.revision

        form.setName("Red tool chest")
        await form.save()

        #expect(app.router.modals.isEmpty)
        #expect(app.router.path(.spaces).map(\.route) == [.container(id: chest.id)])
        #expect(app.database.revision > revision)
        #expect(try await app.repositories.containers.getById(chest.id)?.name == "Red tool chest")
    }

    @Test("a dirty form's Cancel asks first, and Keep editing keeps the sheet")
    func cancelAsksFirst() async throws {
        let confirm = PlacesAppConfirm(answer: false)
        let app = await bootedApp(confirm: confirm)
        let garage = try await space(app, named: "Garage")
        let modal = app.router.present(.sheet(.containerNew(spaceId: garage.id, request: nil)))
        let form = ContainerNewSheet.makeModel(app: app, spaceId: garage.id, request: nil, address: modal.address)
        app.router.setCloseGuard(for: modal.address) { await form.dirtyGuard.attemptClose() }

        form.setName("Paint")
        await app.router.requestClose(modal.address)
        #expect(confirm.asked.map(\.title) == ["Discard your changes?"])
        #expect(app.router.modals.count == 1)

        confirm.answer = true
        await app.router.requestClose(modal.address)
        #expect(app.router.modals.isEmpty)
    }
}

/// Answers the app's confirmations the same way every time, and records what was asked.
@MainActor
final class PlacesAppConfirm: ConfirmPresenting {
    var answer: Bool
    private(set) var asked: [ConfirmOptions] = []

    init(answer: Bool) {
        self.answer = answer
    }

    func confirm(_ options: ConfirmOptions) async -> Bool {
        asked.append(options)
        return answer
    }
}
