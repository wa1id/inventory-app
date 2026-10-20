import Foundation
import InventoryCore
import InventoryStorage
import InventoryStrings
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// `AppContainer.makeRowQuantityModels()`: the rows' write-through quantity, wired like RN's
/// `useSavedQuantity` in ItemRow and SavedQuantityStepper (07 §4.8).
@Suite("Row quantity factory (useSavedQuantity wiring)")
@MainActor
struct CompositionRowQuantityTests {
    private struct Fixture {
        let directory: TemporaryDirectory
        let app: AppContainer
        let haptics: SharedSeamsHapticRecorder
    }

    private func fixture() async throws -> Fixture {
        let directory = try TemporaryDirectory(prefix: "composition-quantity")
        let haptics = SharedSeamsHapticRecorder()
        var platform = AppPlatform.silent()
        platform.haptics = haptics.player
        let app = AppContainer.test(
            resolver: PhotoPathResolver(documents: directory.documents, caches: directory.caches),
            platform: platform
        )
        await app.boot.run()
        return Fixture(directory: directory, app: app, haptics: haptics)
    }

    private func item(_ app: AppContainer, name: String?, quantity: Int) async throws -> ItemWithContext {
        let created = try await app.repositories.items.create(ItemDraft(containerId: DropZone.containerId, name: name, quantity: quantity))
        return try #require(try await app.repositories.items.getById(created.id))
    }

    @Test("a change writes through the current repositories and invalidates; one model per item")
    func writesThrough() async throws {
        let fixture = try await fixture()
        let app = fixture.app
        let screws = try await item(app, name: "Wood screws", quantity: 3)
        let models = app.makeRowQuantityModels()
        let model = models.model(for: screws)
        #expect(models.model(for: screws) === model)
        #expect(model.quantity == 3)

        let revision = app.database.revision
        model.setQuantity(4)
        await model.flushTask?.value
        #expect(try await app.repositories.items.getById(screws.id)?.quantity == 4)
        #expect(app.database.revision > revision)
        #expect(app.toasts.current == nil)
        #expect(fixture.haptics.played.isEmpty, "a step's haptic is the stepper's, not the write's")

        models.keep(only: [String]())
        #expect(models.count == 0)
    }

    @Test("a quantity that did not save shows the error toast naming the item", arguments: [
        ("Wood screws" as String?, "Wood screws"),
        (nil as String?, L10n.Entities.unnamedItem),
    ])
    func errorToast(name: String?, shown: String) async throws {
        let fixture = try await fixture()
        let app = fixture.app
        let gone = try await item(app, name: name, quantity: 2)
        let model = app.makeRowQuantityModels().model(for: gone)
        _ = try await app.repositories.items.delete(gone.id)

        model.setQuantity(5)
        await model.flushTask?.value
        #expect(model.errorKind == .gone)
        #expect(model.quantity == 2)
        let toast = try #require(app.toasts.current)
        #expect(toast.message == L10n.Quantity.notSavedNamed(name: shown, offline: false))
        #expect(toast.message == SavedQuantityModel.notSavedMessage(itemName: gone.name, kind: .gone))
        #expect(toast.tone == .error)
    }

    @Test("the error toast names the item as its row shows it now, after a rename")
    func errorToastAfterRename() async throws {
        let fixture = try await fixture()
        let app = fixture.app
        let screws = try await item(app, name: "Wood screws", quantity: 2)
        let models = app.makeRowQuantityModels()
        let model = models.model(for: screws)

        // The list re-read after a rename: the row asks for its model with the new name.
        _ = try await app.repositories.items.update(screws.id, UpdateItemInput(name: "Deck screws"))
        let renamed = try #require(try await app.repositories.items.getById(screws.id))
        #expect(models.model(for: renamed) === model)
        #expect(models.latestName(of: screws.id) == "Deck screws")

        _ = try await app.repositories.items.delete(screws.id)
        model.setQuantity(5)
        await model.flushTask?.value
        let toast = try #require(app.toasts.current)
        #expect(toast.message == L10n.Quantity.notSavedNamed(name: "Deck screws", offline: false))

        models.keep(only: [String]())
        #expect(models.latestName(of: screws.id) == nil)
    }
}
