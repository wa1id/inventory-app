import Foundation
import Testing
@testable import InventoryCore

// Port of src/ui/__tests__/a11y.test.ts, plus 08 §11 (h) and Fixtures/a11y.json.

/// The English copy from strings.ts the RN tests render with (test scaffolding only).
let englishSpokenCopy = SpokenCopy(
    inDropZone: "In the drop zone, not filed yet",
    inPlace: { space, container, spelled in "In \(space), \(container), label \(spelled)" },
    inSpace: { space, spelled in "In \(space), label \(spelled)" },
    noneLeft: "None left",
    quantity: { count in "Quantity \(count)" }
)

struct TestPlace: PlaceLike, Decodable {
    var containerId: String
    var containerName: String?
    var containerShortCode: String
    var spaceId: String
    var spaceName: String
    var spaceColor: String
}

private let filed = TestPlace(
    containerId: "c1",
    containerName: "Tool chest",
    containerShortCode: "CAB-J92R",
    spaceId: "s1",
    spaceName: "Garage",
    spaceColor: "#5B8DEF"
)

@Suite("spellCode")
struct SpellCodeTests {
    @Test("spaces the characters and pauses between groups")
    func spacesCharactersAndPausesBetweenGroups() {
        #expect(spellCode("DRW-7K2M") == "D R W, 7 K 2 M")
    }

    @Test("copes with a code without groups and with stray hyphens")
    func copesWithoutGroupsAndStrayHyphens() {
        #expect(spellCode("BOX1") == "B O X 1")
        #expect(spellCode("-AB--C-") == "A B, C")
    }
}

@Suite("whereSpoken")
struct WhereSpokenTests {
    @Test("names the space, the container and the spelled label")
    func namesSpaceContainerAndLabel() {
        #expect(whereSpoken(filed, copy: englishSpokenCopy) == "In Garage, Tool chest, label C A B, J 9 2 R")
    }

    @Test("leaves out an unnamed container")
    func leavesOutAnUnnamedContainer() {
        var place = filed
        place.containerName = nil
        #expect(whereSpoken(place, copy: englishSpokenCopy) == "In Garage, label C A B, J 9 2 R")
    }

    @Test("never reads the drop zone’s internal code")
    func neverReadsTheDropZoneCode() {
        var place = filed
        place.containerId = DropZone.containerId
        place.containerName = "Drop zone"
        place.containerShortCode = "DROP-ZONE"
        place.spaceId = DropZone.spaceId
        place.spaceName = "Drop zone"
        #expect(whereSpoken(place, copy: englishSpokenCopy) == "In the drop zone, not filed yet")
    }

    // 08 §11 (h): JS truthiness, no trimming.
    @Test("an empty name reads as unnamed, a blank one as named")
    func emptyVersusBlankName() {
        var place = filed
        place.containerName = ""
        #expect(whereSpoken(place, copy: englishSpokenCopy) == "In Garage, label C A B, J 9 2 R")
        place.containerName = " "
        #expect(whereSpoken(place, copy: englishSpokenCopy) == "In Garage,  , label C A B, J 9 2 R")
    }

    @Test("an ItemWithContext is a place")
    func itemWithContextIsAPlace() {
        let item = ItemWithContext(
            item: Item(
                id: "i1", containerId: "c1", name: "Drill", category: nil, quantity: 1, notes: nil, createdAt: 0, updatedAt: 0
            ),
            photoId: nil, photoUri: nil, photoThumbUri: nil, tags: [], spaceId: "s1", spaceName: "Garage",
            spaceIcon: "🚗", spaceColor: "#5B8DEF", containerName: "Tool chest", containerShortCode: "CAB-J92R"
        )
        #expect(whereSpoken(item, copy: englishSpokenCopy) == "In Garage, Tool chest, label C A B, J 9 2 R")
    }
}

@Suite("quantitySpoken")
struct QuantitySpokenTests {
    @Test("says \"None left\" at zero")
    func saysNoneLeftAtZero() {
        #expect(quantitySpoken(0, copy: englishSpokenCopy) == "None left")
        #expect(quantitySpoken(12, copy: englishSpokenCopy) == "Quantity 12")
    }
}

@Suite("a11y parity (Fixtures/a11y.json, folding.json)")
struct A11yParityTests {
    struct Copy: Decodable { let inDropZone: String; let noneLeft: String; let inPlace: String; let inSpace: String }
    struct WhereEntry: Decodable { let place: TestPlace; let spoken: String }
    struct QuantityEntry: Decodable { let quantity: Int; let spoken: String }
    struct SpellEntry: Decodable { let input: String; let spelled: String }
    struct File: Decodable {
        let copy: Copy
        let `where`: [WhereEntry]
        let quantities: [QuantityEntry]
        let spell: [SpellEntry]
    }

    @Test("the scaffolding copy is the strings.ts copy")
    func copyMatchesStrings() throws {
        let copy = try loadFixture("a11y", as: File.self).copy
        #expect(copy.inDropZone == englishSpokenCopy.inDropZone)
        #expect(copy.noneLeft == englishSpokenCopy.noneLeft)
        #expect(copy.inPlace == englishSpokenCopy.inPlace("%1$@", "%2$@", "%3$@"))
        #expect(copy.inSpace == englishSpokenCopy.inSpace("%1$@", "%2$@"))
    }

    @Test("whereSpoken, quantitySpoken and spellCode match JS")
    func matchesJS() throws {
        let file = try loadFixture("a11y", as: File.self)
        for entry in file.where {
            #expect(sameScalars(whereSpoken(entry.place, copy: englishSpokenCopy), entry.spoken), "\(entry.spoken)")
        }
        for entry in file.quantities {
            #expect(quantitySpoken(entry.quantity, copy: englishSpokenCopy) == entry.spoken)
        }
        for entry in file.spell {
            #expect(sameScalars(spellCode(entry.input), entry.spelled), "\(scalarDump(entry.input))")
        }
    }

    @Test("spellCode matches JS over the corpus")
    func spellCodeCorpus() throws {
        let entries: [FoldingEntry] = try loadFixture("folding")
        for entry in entries {
            let actual = spellCode(entry.input)
            #expect(sameScalars(actual, entry.spellCode), "\(scalarDump(entry.input)): \(scalarDump(actual))")
        }
    }
}
