import Testing
@testable import InventoryCore

// The a11y and place-match helpers read the String Catalog by default, as RN read
// `strings` (src/ui/a11y.ts, src/ui/placeMatch.ts). Under `swift test` the catalog
// lookups fall back to the strings.ts English, which is what these compare with.

private let filed = TestPlace(
    containerId: "c1",
    containerName: "Tool chest",
    containerShortCode: "CAB-J92R",
    spaceId: "s1",
    spaceName: "Garage",
    spaceColor: "#5B8DEF"
)

@Suite("SpokenCopy.standard")
struct StandardSpokenCopyTests {
    @Test("is the strings.ts copy")
    func isTheStringsCopy() throws {
        let standard = SpokenCopy.standard
        let fixture = try loadFixture("a11y", as: A11yParityTests.File.self).copy
        #expect(standard.inDropZone == fixture.inDropZone)
        #expect(standard.noneLeft == fixture.noneLeft)
        #expect(standard.inPlace("%1$@", "%2$@", "%3$@") == fixture.inPlace)
        #expect(standard.inSpace("%1$@", "%2$@") == fixture.inSpace)
        #expect(standard.quantity(12) == "Quantity 12")
    }

    @Test("whereSpoken and quantitySpoken use it by default")
    func usedByDefault() {
        #expect(whereSpoken(filed) == "In Garage, Tool chest, label C A B, J 9 2 R")
        var unnamed = filed
        unnamed.containerName = nil
        #expect(whereSpoken(unnamed) == "In Garage, label C A B, J 9 2 R")
        var dropZone = filed
        dropZone.containerId = DropZone.containerId
        #expect(whereSpoken(dropZone) == "In the drop zone, not filed yet")
        #expect(quantitySpoken(0) == "None left")
        #expect(quantitySpoken(9999) == "Quantity 9999")
    }

    @Test("formats counts without grouping, as a JS template literal does")
    func noDigitGrouping() {
        #expect(quantitySpoken(12345) == "Quantity 12345")
    }

    @Test("passes names through untouched")
    func namesUntouched() {
        var place = filed
        place.spaceName = "שלום %@ 100%"
        place.containerName = "Кухня"
        #expect(sameScalars(whereSpoken(place), "In שלום %@ 100%, Кухня, label C A B, J 9 2 R"))
    }

    @Test("matches JS for the generated places")
    func matchesJS() throws {
        let file = try loadFixture("a11y", as: A11yParityTests.File.self)
        for entry in file.where {
            #expect(sameScalars(whereSpoken(entry.place), entry.spoken), "\(entry.spoken)")
        }
        for entry in file.quantities {
            #expect(quantitySpoken(entry.quantity) == entry.spoken)
        }
    }
}

@Suite("matchesPlace default type names")
struct MatchesPlaceDefaultTypeNameTests {
    @Test("finds a container by its type's display name")
    func findsByTypeName() {
        let toolChest = PlaceFields(name: "Tool chest", shortCode: "CAB-J92R", spaceName: "Garage", visualType: "cabinet")
        let unnamedBox = PlaceFields(name: nil, shortCode: "BOX-4F2A", spaceName: "Loft", visualType: "box")
        let other = PlaceFields(name: nil, shortCode: "CTR-ABCD", spaceName: "Loft", visualType: "other")
        #expect(matchesPlace(toolChest, terms: placeTerms("cabinet")))
        #expect(matchesPlace(unnamedBox, terms: placeTerms("loft box")))
        #expect(matchesPlace(other, terms: placeTerms("container")))
        #expect(!matchesPlace(other, terms: placeTerms("other")))
    }

    @Test("an unknown type adds nothing, with no fallback to Container")
    func unknownTypeAddsNothing() {
        let odd = PlaceFields(name: "Odd", shortCode: "CTR-ABCD", spaceName: "Attic", visualType: "Box")
        #expect(!matchesPlace(odd, terms: placeTerms("box")))
        #expect(!matchesPlace(odd, terms: placeTerms("container")))
        #expect(matchesPlace(odd, terms: placeTerms("odd attic")))
    }

    @Test("every known type reads its strings.ts name")
    func everyKnownType() {
        for type in ContainerVisualType.allKnown {
            let option = PlaceFields(name: nil, shortCode: "ABC-1234", spaceName: "Shed", visualType: type)
            let name = englishTypeNames[type.rawValue] ?? ""
            #expect(matchesPlace(option, terms: placeTerms(name)), "\(type)")
        }
    }

    @Test("matches JS for the generated options and queries")
    func matchesJS() throws {
        let file = try loadFixture("placeMatch", as: PlaceMatchParityTests.File.self)
        for result in file.results {
            for (query, expected) in zip(file.queries, result.matches) {
                let actual = matchesPlace(result.option, terms: placeTerms(query))
                #expect(actual == expected, "\(result.option.shortCode) / \(scalarDump(query))")
            }
        }
    }
}
