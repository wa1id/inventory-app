import Foundation
import InventoryCore
import InventoryServices
import InventoryStorage
import InventoryStrings
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// The Add sheet's camera and navigation on the app's router (06 §3.2 Add sheet rows, 05 §3
/// rows 5-8, UI-KIT §1.7).
@MainActor
@Suite("Add sheet routing on the router")
struct AddSheetRoutingTests {
    private static let photo = StoredImage(uri: "file:///p.webp", thumbUri: "file:///p-thumb.webp", width: 1400, height: 1050, byteSize: 2048)

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("condition never held")
    }

    @Test("the camera button opens the single-mode camera over the sheet for a result, and the photo comes back")
    func takePhotoForAResult() async throws {
        let router = Router()
        let sheet = router.present(.sheet(.addItem(AddParams())))
        let routing = AddSheetModel.Routing.router(router, address: sheet.address)
        #expect(routing.isFocused())

        let taking = Task { await routing.takePhoto("chest") }
        await until { router.modals.count == 2 }
        let cover = try #require(router.modals.last)
        guard case .cover(.capture(let capture, let request)) = cover.route else {
            Issue.record("expected the camera, got \(cover.route)")
            return
        }
        #expect(capture == CaptureRoute(containerId: "chest", mode: .single))
        #expect(request != nil)
        #expect(!routing.isFocused(), "the sheet is under the camera")

        // The camera delivers and closes itself in one step.
        #expect(router.results.deliver(request, Self.photo))
        router.close(cover.address)
        #expect(await taking.value == Self.photo)
        #expect(routing.isFocused())
        #expect(router.modals.map(\.id) == [sheet.id])
    }

    @Test("a camera closed without a photo answers nothing")
    func cameraClosedWithoutPhoto() async throws {
        let router = Router()
        let sheet = router.present(.sheet(.addItem(AddParams())))
        let routing = AddSheetModel.Routing.router(router, address: sheet.address)
        let taking = Task { await routing.takePhoto(DropZone.containerId) }
        await until { router.modals.count == 2 }
        let cover = try #require(router.modals.last)
        router.close(cover.address)
        #expect(await taking.value == nil)
    }

    @Test("Snap several replaces the sheet with Quick Snap; Save and add another with a photo, with the single camera and nobody waiting")
    func replacesWithTheCamera() throws {
        let router = Router()
        let sheet = router.present(.sheet(.addItem(AddParams(containerId: "chest"))))
        let routing = AddSheetModel.Routing.router(router, address: sheet.address)
        routing.replaceWithCapture("chest", true)
        #expect(router.modals.map(\.route) == [.cover(.capture(CaptureRoute(containerId: "chest", mode: .fast), request: nil))])

        let again = router.present(.sheet(.addItem(AddParams())))
        let next = AddSheetModel.Routing.router(router, address: again.address)
        next.replaceWithCapture("bin", false)
        #expect(router.modals.last?.route == .cover(.capture(CaptureRoute(containerId: "bin", mode: .single), request: nil)))
        #expect(router.modals.count == 2, "the replacement takes the sheet's place")
    }

    @Test("Snap several from a sheet that is no longer on top replaces nothing")
    func replaceOnlyFromTheTop() {
        let router = Router()
        let sheet = router.present(.sheet(.addItem(AddParams())))
        let over = router.present(.sheet(.containerNew(spaceId: "garage", request: nil)))
        AddSheetModel.Routing.router(router, address: sheet.address).replaceWithCapture("chest", true)
        #expect(router.modals.map(\.id) == [sheet.id, over.id])
    }

    @Test("close dismisses the sheet and whatever is over it, never the tab underneath")
    func closes() {
        let router = Router()
        router.selectTab(.spaces)
        let sheet = router.present(.sheet(.addItem(AddParams())))
        _ = router.present(.sheet(.spaceNew(request: nil)))
        AddSheetModel.Routing.router(router, address: sheet.address).close()
        #expect(router.modals.isEmpty)
        #expect(router.selectedTab == .spaces)
    }

    @Test("outside the shell (a preview) the sheet is in front and navigates nowhere")
    func withoutAnAddress() async {
        let router = Router()
        let routing = AddSheetModel.Routing.router(router, address: nil)
        #expect(routing.isFocused())
        routing.close()
        routing.replaceWithCapture("chest", true)
        #expect(router.modals.isEmpty)
    }
}

/// `AppContainer.makeAddSheetModel(params:address:)`: the sheet's model on the app's own
/// stores, end to end through the in-memory database.
@MainActor
@Suite("Add sheet on the app (makeAddSheetModel)")
struct AddSheetAppWiringTests {
    private struct Fixture {
        let directory: TemporaryDirectory
        let app: AppContainer
        let confirm: SharedSeamsConfirmScript
        let haptics: SharedSeamsHapticRecorder
    }

    private func fixture(confirm answers: [Bool] = []) async throws -> Fixture {
        let directory = try TemporaryDirectory(prefix: "add-wiring")
        let confirm = SharedSeamsConfirmScript(answers: answers)
        let haptics = SharedSeamsHapticRecorder()
        var platform = AppPlatform.silent(confirm: confirm)
        platform.haptics = haptics.player
        let app = AppContainer.test(
            resolver: PhotoPathResolver(documents: directory.documents, caches: directory.caches),
            platform: platform
        )
        await app.boot.run()
        return Fixture(directory: directory, app: app, confirm: confirm, haptics: haptics)
    }

    private func toolChest(_ app: AppContainer) async throws -> Container {
        let garage = try await app.repositories.spaces.create(CreateSpaceInput(name: "Garage", icon: "🧰", color: "#5B8DEF"))
        return try await app.repositories.containers.create(CreateContainerInput(spaceId: garage.id, name: "Tool chest", visualType: .cabinet))
    }

    @Test("Save writes the item where it was chosen, remembers the place and the category, closes and says where it went")
    func savesThroughTheApp() async throws {
        let fixture = try await fixture()
        let app = fixture.app
        let chest = try await toolChest(app)
        let sheet = app.router.present(.sheet(.addItem(AddParams(containerId: chest.id))))
        let model = app.makeAddSheetModel(params: AddParams(containerId: chest.id), address: sheet.address)
        model.start()
        await model.loadPlaces()
        #expect(model.title == L10n.Add.titleTo(container: "Tool chest"))
        #expect(model.entries.map(\.whereIdentifier) == ["item-where-\(chest.id)", "item-where-drop-zone"])

        model.name = "Cordless drill"
        model.category = "Power tools"
        let revision = app.database.revision
        await model.save(andAnother: false)

        let saved = try await app.repositories.items.listByContainer(chest.id)
        #expect(saved.map(\.name) == ["Cordless drill"])
        #expect(saved.first?.category == "Power tools")
        #expect(app.database.revision > revision)
        #expect(app.recentPlaces.read() == [chest.id])
        #expect(app.categories.suggestions(for: "Po") == ["Power tools"])
        #expect(app.router.modals.isEmpty)
        #expect(fixture.haptics.played == [.success])
        let toast = try #require(app.toasts.current)
        #expect(toast.message == L10n.Add.savedIn(container: "Tool chest", space: "Garage"))
        #expect(toast.action?.label == L10n.Common.undo)
        #expect(toast.action?.accessibilityLabel == L10n.Add.undoA11y(name: "Cordless drill"))
    }

    @Test("a sheet swiped away keeps its draft in the app's one store, and the next plain open restores it")
    func draftAcrossSheets() async throws {
        let fixture = try await fixture()
        let app = fixture.app
        let first = app.router.present(.sheet(.addItem(AddParams())))
        let model = app.makeAddSheetModel(params: AddParams(), address: first.address)
        model.start()
        app.router.onRemoval(of: first.address) { model.sheetClosed() }
        model.name = "Torch"
        app.router.modalDismissedBySystem(first.id)

        let second = app.router.present(.sheet(.addItem(AddParams())))
        let next = app.makeAddSheetModel(params: AddParams(), address: second.address)
        next.start()
        #expect(next.restored)
        #expect(next.name == "Torch")
    }

    @Test("Cancel goes through the sheet's close guard: Keep editing stays, Discard closes and forgets the draft")
    func cancelThroughTheGuard() async throws {
        let fixture = try await fixture(confirm: [false, true])
        let app = fixture.app
        let sheet = app.router.present(.sheet(.addItem(AddParams())))
        let model = app.makeAddSheetModel(params: AddParams(), address: sheet.address)
        model.start()
        app.router.setCloseGuard(for: sheet.address) { await model.confirmCancel() }
        model.name = "Torch"

        await app.router.requestClose(sheet.address)
        #expect(fixture.confirm.asked.map(\.title) == [L10n.Add.discardTitle])
        #expect(app.router.modals.map(\.id) == [sheet.id])

        await app.router.requestClose(sheet.address)
        #expect(app.router.modals.isEmpty)
        #expect(app.drafts.restorableDraft(now: app.now()) == nil)
    }

    @Test("Snap several leaves the typing in the draft and puts Quick Snap where the sheet was")
    func snapSeveralKeepsTheDraft() async throws {
        let fixture = try await fixture()
        let app = fixture.app
        let sheet = app.router.present(.sheet(.addItem(AddParams())))
        let model = app.makeAddSheetModel(params: AddParams(), address: sheet.address)
        model.start()
        model.name = "Torch"
        model.snapSeveral()
        #expect(app.router.modals.map(\.route) == [.cover(.capture(CaptureRoute(containerId: DropZone.containerId, mode: .fast), request: nil))])
        #expect(app.drafts.restorableDraft(now: app.now())?.state.values.name == "Torch")
    }

    @Test("without a recognition endpoint a photo's banner says suggestions are not set up, with no retry")
    func notConfigured() async throws {
        let fixture = try await fixture()
        let app = fixture.app
        let params = AddParams(photoUri: "file:///nowhere.webp")
        let sheet = app.router.present(.sheet(.addItem(params)))
        let model = app.makeAddSheetModel(params: params, address: sheet.address)
        model.start()
        await model.recognitionTask?.value
        #expect(model.suggestionBanner == .failed(.notConfigured))
        #expect(model.suggestionBanner?.bannerCopy?.action == nil)
    }
}
