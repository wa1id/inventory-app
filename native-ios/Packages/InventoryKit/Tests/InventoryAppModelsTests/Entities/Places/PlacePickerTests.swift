import Foundation
import InventoryCore
import InventoryStorage
import InventoryStrings
import Testing
@testable import InventoryAppModels

/// The place picker's sections (src/ui/components/PlacePicker.tsx:139-205; 07 §4.1). RN has no
/// tests for the picker; these pin the rules the spec lists.
@Suite("PlacePicker sections (PlacePicker.tsx)")
struct EntitiesPlacePickerTests {
    private static func space(_ id: String, _ name: String, color: String = "#5B8DEF") -> SpaceWithCounts {
        SpaceWithCounts(space: Space(id: id, name: name, icon: "🏠", color: color, createdAt: 1, updatedAt: 1), containerCount: 0, itemCount: 0)
    }

    private let spaces = [space("garage", "Garage"), space("kitchen", "Kitchen", color: "#2E9E4F")]
    private let options = [
        EntitiesFixtures.option("chest", name: "Tool chest", shortCode: "CAB-J92R", visualType: .cabinet, spaceId: "garage", spaceName: "Garage"),
        EntitiesFixtures.option("anvil", name: "anvil box", shortCode: "BOX-2222", spaceId: "garage", spaceName: "Garage"),
        EntitiesFixtures.option("drawer", name: "Drawer by the oven", shortCode: "DRW-7K2M", visualType: .drawer, spaceId: "kitchen", spaceName: "Kitchen"),
        EntitiesFixtures.option("unnamed", name: .some(nil), shortCode: "BIN-4F2A", visualType: .bin, spaceId: "kitchen", spaceName: "Kitchen"),
    ]

    private func describe(_ sections: [PlacePickerSection]) -> [String] {
        sections.map { section in
            let rows = section.entries.map { entry -> String in
                switch entry {
                case .dropZone: "drop"
                case .option(let option, let recent): recent ? "recent:\(option.id)" : option.id
                case .newContainer(let spaceId, _, let color): color == nil ? "new:\(spaceId)" : "new*:\(spaceId)"
                }
            }
            return "\(section.id)[\(rows.joined(separator: ","))]"
        }
    }

    @Test("choose with the drop zone: drop zone first, recent places, then each space sorted by label with New container")
    func chooseSections() {
        let sections = PlacePickerRules.sections(
            mode: .choose, query: "", options: options, spaces: spaces, recentIds: ["drawer", "gone", "chest"], showDropZone: true)
        #expect(describe(sections) == [
            "top[drop]",
            "recent[recent:drawer,recent:chest]",
            "garage[anvil,chest,new:garage]",
            "kitchen[unnamed,drawer,new:kitchen]",
        ])
        #expect(sections[1].title == L10n.Picker.recent)
        #expect(sections[2].title == "Garage")
        #expect(sections[3].color == "#2E9E4F")
    }

    @Test("recent places stop at four and keep the current container")
    func recentCap() {
        let sections = PlacePickerRules.sections(
            mode: .move, query: "", options: options, spaces: spaces, recentIds: ["unnamed", "drawer", "anvil", "chest", "x"])
        #expect(describe(sections).first == "recent[recent:unnamed,recent:drawer,recent:anvil,recent:chest]")
        #expect(!describe(sections).contains { $0.hasPrefix("top") })
    }

    @Test("filtering matches name, code and space; spaces with no match drop out and offer no New container")
    func filtering() {
        let sections = PlacePickerRules.sections(mode: .move, query: "drw7k", options: options, spaces: spaces, recentIds: ["chest"])
        #expect(describe(sections) == ["kitchen[drawer,new:kitchen]"])
        #expect(PlacePickerRules.noMatchMessage(query: "drw7k", options: options, sections: sections) == nil)
    }

    @Test("nothing matching offers one list of spaces to make a container in")
    func nothingMatches() {
        let sections = PlacePickerRules.sections(mode: .choose, query: "  zzz ", options: options, spaces: spaces, recentIds: [])
        #expect(describe(sections) == ["new[new*:garage,new*:kitchen]"])
        #expect(sections.first?.title == L10n.Picker.newContainerTitle)
        #expect(PlacePickerRules.noMatchMessage(query: "  zzz ", options: options, sections: sections) == L10n.Picker.noMatch(query: "zzz"))
    }

    @Test("open mode offers no New container, so nothing matching shows nothing")
    func openMode() {
        #expect(PlacePickerRules.sections(mode: .open, query: "zzz", options: options, spaces: spaces, recentIds: []).isEmpty)
        let sections = PlacePickerRules.sections(mode: .open, query: "", options: options, spaces: spaces, recentIds: [])
        #expect(describe(sections) == ["garage[anvil,chest]", "kitchen[unnamed,drawer]"])
        #expect(PlacePickerMode.open.autoFocusesFilter)
        #expect(!PlacePickerMode.choose.autoFocusesFilter)
    }

    @Test("a space known only from a container (just made) still shows, after the listed ones")
    func unlistedSpace() {
        let extra = EntitiesFixtures.option("box", name: "New box", spaceId: "loft", spaceName: "Loft", spaceColor: "")
        let sections = PlacePickerRules.sections(mode: .bind, query: "", options: options + [extra], spaces: spaces, recentIds: [])
        #expect(describe(sections).last == "loft[box,new:loft]")
        #expect(sections.last?.title == "Loft")
    }

    @Test("an empty space still offers New container unless filtering")
    func emptySpace() {
        let withEmpty = spaces + [Self.space("cellar", "Cellar")]
        #expect(describe(PlacePickerRules.sections(mode: .choose, query: "", options: [], spaces: withEmpty, recentIds: []))
            == ["garage[new:garage]", "kitchen[new:kitchen]", "cellar[new:cellar]"])
    }

    @Test("rows: here now, selection, labels and spoken labels")
    func rows() {
        let chest = options[0]
        let unnamed = options[3]
        #expect(PlacePickerRules.isHereNow(chest, mode: .move, currentContainerId: "chest"))
        #expect(PlacePickerRules.isHereNow(chest, mode: .file, currentContainerId: "chest"))
        #expect(!PlacePickerRules.isHereNow(chest, mode: .choose, currentContainerId: "chest"))
        #expect(PlacePickerRules.isSelected(chest, mode: .choose, selectedContainerId: "chest"))
        #expect(!PlacePickerRules.isSelected(chest, mode: .move, selectedContainerId: "chest"))
        #expect(PlacePickerRules.isDropZoneSelected(selectedContainerId: nil))
        #expect(PlacePickerRules.isDropZoneSelected(selectedContainerId: DropZone.containerId))
        #expect(!PlacePickerRules.isDropZoneSelected(selectedContainerId: "chest"))
        #expect(PlacePickerRules.optionLabel(unnamed) == "Unnamed bin")
        #expect(PlacePickerRules.optionAccessibilityLabel(chest, mode: .move, currentContainerId: "chest") == L10n.Picker.hereNowA11y(label: "Tool chest"))
        #expect(PlacePickerRules.optionAccessibilityLabel(unnamed, mode: .choose, currentContainerId: nil)
            == L10n.Picker.optionA11y(label: "Unnamed bin", space: "Kitchen", spelled: "B I N, 4 F 2 A"))
    }

    @Test("row keys follow RN's entryKey, so a recent container and the same one under its space differ")
    func rowKeys() {
        let sections = PlacePickerRules.sections(
            mode: .choose, query: "", options: options, spaces: spaces, recentIds: ["chest"], showDropZone: true)
        #expect(sections.map { $0.entries.map(\.id) } == [
            [DropZone.containerId],
            ["recent-chest"],
            ["space-anvil", "space-chest", "new-garage"],
            ["space-unnamed", "space-drawer", "new-kitchen"],
        ])
    }

    @Test("nothing at all: no containers and no way to make one")
    func nothingAtAll() {
        #expect(PlacePickerRules.isNothingAtAll(loading: false, options: [], spaces: [], allowNewContainer: true))
        #expect(!PlacePickerRules.isNothingAtAll(loading: false, options: [], spaces: spaces, allowNewContainer: true))
        #expect(PlacePickerRules.isNothingAtAll(loading: false, options: [], spaces: spaces, allowNewContainer: false))
        #expect(!PlacePickerRules.isNothingAtAll(loading: true, options: [], spaces: [], allowNewContainer: true))
    }

    @Test("a container made from the picker is picked as it came back, with its space when known")
    func newContainerOption() {
        let created = NewContainerResult(containerId: "c9", name: nil, shortCode: "BOX-9999", visualType: .box, spaceId: "kitchen")
        let option = PlacePickerRules.option(for: created, spaces: spaces, spaceName: "Fallback")
        #expect(option == PlaceOption(
            id: "c9", name: nil, shortCode: "BOX-9999", visualType: .box, spaceId: "kitchen", spaceName: "Kitchen",
            spaceColor: "#2E9E4F", spaceIcon: "🏠", itemCount: 0))
        let unknownSpace = PlacePickerRules.option(for: NewContainerResult(containerId: "c8", name: "Crate", shortCode: "CRT-2222", visualType: .crate, spaceId: "new"), spaces: spaces, spaceName: "Just made")
        #expect(unknownSpace.spaceName == "Just made")
        #expect(unknownSpace.spaceColor == "")
        #expect(unknownSpace.spaceIcon == "")
    }
}

/// `src/hooks/__tests__/useRecentPlaces.test.tsx`.
@MainActor
@Suite("RecentPlacesModel (useRecentPlaces.test.tsx)")
struct EntitiesRecentPlacesModelTests {
    @Test("takes the stored list, then holds it while the screen stays open")
    func holds() {
        let store = RecentPlacesStore(preferences: InMemoryPreferences([PreferenceKey.recentPlaces: #"["a","b","c"]"#]))
        let open = RecentPlacesModel(store: store)
        #expect(open.ids == ["a", "b", "c"])
        // The pick that remembers "b" is the one that closes this screen.
        open.remember("b")
        #expect(open.ids == ["a", "b", "c"])
        // The next screen sees the new order.
        #expect(RecentPlacesModel(store: store).ids == ["b", "a", "c"])
    }
}
