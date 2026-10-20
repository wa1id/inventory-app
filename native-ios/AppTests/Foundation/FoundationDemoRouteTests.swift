import Testing
@testable import Inventory
import InventoryAppModels
import InventoryCore

/// `-demoRoute` specs (App/Shell/ShellDemo.swift): parsing, names resolved against the seeded
/// preview inventory, and the routes they open.
@Suite("Demo routes (hosted)", .serialized)
@MainActor
struct FoundationDemoRouteTests {
    private func seeded() async -> (AppContainer, ShellDemoInventory) {
        let app = AppContainer.preview()
        await app.boot.run()
        return (app, await ShellDemoInventory.read(app.repositories))
    }

    @Test("specs split on > and the first colon; empty parts are dropped")
    func parse() {
        #expect(ShellDemoRoute.parse("settings") == [.init(name: "settings", argument: nil)])
        #expect(ShellDemoRoute.parse("container:Tool chest>containerEdit:Tool chest") == [
            .init(name: "container", argument: "Tool chest"),
            .init(name: "containerEdit", argument: "Tool chest"),
        ])
        #expect(ShellDemoRoute.parse(" add > containerNew:Garage >") == [
            .init(name: "add", argument: nil),
            .init(name: "containerNew", argument: "Garage"),
        ])
        #expect(ShellDemoRoute.parse("item:") == [.init(name: "item", argument: "")])
        #expect(ShellDemoRoute.parse("label:a:b") == [.init(name: "label", argument: "a:b")])
    }

    @Test("only a spec that names something reads the inventory (a joined household's reads can be slow)")
    func namesSomething() {
        #expect(!ShellDemoRoute.Step(name: "add", argument: nil).namesSomething)
        #expect(ShellDemoRoute.Step(name: "add", argument: "Tool chest").namesSomething)
        #expect(!ShellDemoRoute.Step(name: "settings", argument: nil).namesSomething)
        #expect(!ShellDemoRoute.Step(name: "label", argument: "abc").namesSomething)
        #expect(ShellDemoRoute.Step(name: "move", argument: "Spare keys").namesSomething)
        #expect(ShellDemoRoute.Step(name: "item", argument: "").namesSomething)
    }

    @Test("the wave-4 -demoOpen values map onto specs")
    func demoOpen() {
        #expect(ShellDemoRoute.demoOpen("settings") == "settings")
        #expect(ShellDemoRoute.demoOpen("addOverSheet") == "add>containerNew:Garage")
        #expect(ShellDemoRoute.demoOpen("move") == "file:HDMI_cable")
        #expect(ShellDemoRoute.demoOpen("nonsense") == nil)
    }

    @Test("names resolve case-insensitively, _ for a space; codes and the drop zone too")
    func names() async {
        let (_, inventory) = await seeded()
        #expect(inventory.space("garage") != nil)
        #expect(inventory.space("Nowhere") == nil)
        let chest = inventory.container("tool_chest")
        #expect(chest != nil)
        #expect(inventory.container("CAB-J92R") == chest)
        #expect(inventory.container("box-7k2m") != nil, "the unnamed box by its code")
        #expect(inventory.container("Drop zone") == DropZone.containerId)
        #expect(inventory.item("Cordless drill") != nil)
        #expect(inventory.item("") != nil, "the unnamed Quick Snap shot")
        #expect(inventory.item("Nothing like it") == nil)
    }

    @Test("each spec opens its route; an unknown name opens nothing")
    func opens() async throws {
        let (app, inventory) = await seeded()
        let router = app.router
        let chest = try #require(inventory.container("Tool chest"))
        let garage = try #require(inventory.space("Garage"))
        let drill = try #require(inventory.item("Cordless drill"))

        #expect(await ShellDemoRoute.open(.init(name: "container", argument: "Tool_chest"), inventory: inventory, app: app))
        #expect(router.path(.home).map(\.route) == [.container(id: chest)])
        #expect(await ShellDemoRoute.open(.init(name: "itemFiling", argument: "cordless drill"), inventory: inventory, app: app))
        #expect(router.path(.home).last?.route == .item(id: drill, filing: true))

        #expect(await ShellDemoRoute.open(.init(name: "containerNew", argument: "Garage"), inventory: inventory, app: app))
        #expect(router.modals.last?.route == .sheet(.containerNew(spaceId: garage, request: nil)))
        #expect(await ShellDemoRoute.open(.init(name: "move", argument: "Cordless_drill"), inventory: inventory, app: app))
        #expect(router.modals.last?.route == .sheet(.move(itemId: drill, filing: false, request: nil)))

        router.dismissAll()
        #expect(await ShellDemoRoute.open(.init(name: "linkSticker", argument: "Tool chest"), inventory: inventory, app: app))
        #expect(router.modals.last?.route == .cover(.linkSticker(containerId: chest)))
        router.dismissAll()
        #expect(await ShellDemoRoute.open(.init(name: "label", argument: nil), inventory: inventory, app: app))
        #expect(router.path(.home).last?.route == .label(token: AppContainerPreviewData.unboundLabelToken))

        let before = router.state
        #expect(!(await ShellDemoRoute.open(.init(name: "space", argument: "Nowhere"), inventory: inventory, app: app)))
        #expect(!(await ShellDemoRoute.open(.init(name: "teleport", argument: nil), inventory: inventory, app: app)))
        #expect(router.state == before)
    }

    @Test("the seed's codes and label are fixed, so docs and UI tests can name them")
    func fixedSeed() async throws {
        let (app, inventory) = await seeded()
        let codes = Dictionary(uniqueKeysWithValues: inventory.containers.map { ($0.container.name ?? "(unnamed)", $0.container.shortCode) })
        #expect(codes == [
            "Tool chest": "CAB-J92R", "Red bin": "BIN-4F2A", "(unnamed)": "BOX-7K2M",
            "Pantry shelf": "SHF-3PQX", "Top drawer": "DRW-8HNC", "Winter clothes": "BAG-5WTD",
        ])
        let label = try await app.repositories.qr.getByToken(AppContainerPreviewData.toolChestLabelToken)
        #expect(label?.containerId == inventory.container("Tool chest"))
        #expect(try await app.repositories.qr.getByToken(AppContainerPreviewData.unboundLabelToken) == nil)
    }
}
