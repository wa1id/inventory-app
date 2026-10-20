import InventoryCore
import InventoryStrings
import Testing
@testable import InventoryAppModels

/// "Where it goes" rows as `src/ui/add/WhereList.tsx` draws and names them (06 §10.5, 07 §4.2).
@Suite("WhereList rows (WhereList.tsx)")
struct AddWhereRowsTests {
    private static func option(_ id: String, name: String?, code: String, type: ContainerVisualType = .drawer, space: String = "Kitchen") -> PlaceOption {
        PlaceOption(id: id, name: name, shortCode: code, visualType: type, spaceId: "s-\(space)", spaceName: space, spaceColor: "#E07A5F", spaceIcon: "🍳", itemCount: 2)
    }

    @Test("each row keeps RN's test id: the drop zone, recent places, and the rest by container id")
    func identifiers() {
        let drawer = Self.option("drawer", name: "Drawer by the oven", code: "DRW-7K2M")
        #expect(WhereEntry.dropZone.whereIdentifier == "item-where-drop-zone")
        #expect(WhereEntry.container(drawer, source: .recent).whereIdentifier == "item-where-recent-drawer")
        #expect(WhereEntry.container(drawer, source: .param).whereIdentifier == "item-where-drawer")
        #expect(WhereEntry.container(drawer, source: .picked).whereIdentifier == "item-where-drawer")
    }

    @Test("the drop zone reads with its hint; a container as the picker reads it, unnamed by its type")
    func spokenLabels() {
        #expect(WhereEntry.dropZone.whereAccessibilityLabel == "Drop zone, Sort it later")
        let drawer = Self.option("drawer", name: "Drawer by the oven", code: "DRW-7K2M")
        #expect(WhereEntry.container(drawer, source: .recent).whereAccessibilityLabel == "Drawer by the oven, in Kitchen, label D R W, 7 K 2 M")
        let box = Self.option("box", name: nil, code: "BOX-7K2M", type: .box, space: "Garage")
        #expect(WhereEntry.container(box, source: .param).whereAccessibilityLabel == "Unnamed box, in Garage, label B O X, 7 K 2 M")
    }

    @Test("a container row draws its location; the drop zone draws its tray instead")
    func locations() {
        #expect(WhereEntry.dropZone.wherePlace == nil)
        #expect(WhereEntry.dropZone.whereVisualType == nil)
        let bin = Self.option("bin", name: nil, code: "BIN-4F2A", type: .bin, space: "Loft")
        let place = WhereEntry.container(bin, source: .picked).wherePlace
        #expect(place == RowPlace(containerId: "bin", containerName: nil, containerShortCode: "BIN-4F2A", spaceId: "s-Loft", spaceName: "Loft", spaceColor: "#E07A5F"))
        #expect(WhereEntry.container(bin, source: .picked).whereVisualType == .bin)
    }
}
