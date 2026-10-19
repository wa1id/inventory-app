import Testing
@testable import InventoryCore

// Port of src/ui/__tests__/placeMatch.test.ts, plus Fixtures/placeMatch.json
// and 01-data.md §13.8 #11.

/// `strings.entities.typeNames` (English), as the RN tests see it.
let englishTypeNames: [String: String] = [
    "box": "Box", "drawer": "Drawer", "shelf": "Shelf", "cabinet": "Cabinet",
    "bin": "Bin", "bag": "Bag", "crate": "Crate", "other": "Container",
]

struct PlaceFields: PlaceMatchFields {
    var name: String?
    var shortCode: String
    var spaceName: String
    var visualType: ContainerVisualType
}

private func matches(_ option: some PlaceMatchFields, _ terms: [String]) -> Bool {
    matchesPlace(option, terms: terms) { englishTypeNames[$0.rawValue] }
}

private let drawer = PlaceFields(name: "Drawer by the oven", shortCode: "DRW-7K2M", spaceName: "Kitchen", visualType: "drawer")
private let toolChest = PlaceFields(name: "Tool chest", shortCode: "CAB-J92R", spaceName: "Garage", visualType: "cabinet")
private let unnamedBox = PlaceFields(name: nil, shortCode: "BOX-4F2A", spaceName: "Loft", visualType: "box")

@Suite("compact")
struct CompactTests {
    @Test("drops case, spaces and punctuation")
    func dropsCaseSpacesAndPunctuation() {
        #expect(compactAlphanumeric("DRW-7K2M") == "drw7k2m")
        #expect(compactAlphanumeric(" Tool  chest! ") == "toolchest")
    }

    @Test("folds accents and keeps letters of any script, like Home search")
    func foldsAccentsAndKeepsAnyScript() {
        #expect(compactAlphanumeric("Küche") == "kuche")
        #expect(compactAlphanumeric("Кухня") == "кухня")
    }
}

@Suite("placeTerms")
struct PlaceTermsTests {
    @Test("splits on whitespace and drops terms that compact to nothing")
    func splitsOnWhitespace() {
        #expect(placeTerms("  drw-7k  garage - ") == ["drw7k", "garage"])
        #expect(placeTerms("") == [])
    }
}

@Suite("matchesPlace")
struct MatchesPlaceTests {
    @Test("finds a label code typed without its hyphen")
    func findsALabelCodeWithoutItsHyphen() {
        #expect(matches(drawer, placeTerms("drw7k")))
        #expect(matches(drawer, placeTerms("DRW-7K2M")))
    }

    @Test("matches the space name and the type name")
    func matchesSpaceAndTypeName() {
        #expect(matches(toolChest, placeTerms("garage")))
        #expect(matches(toolChest, placeTerms("cabinet")))
        #expect(matches(unnamedBox, placeTerms("loft box")))
    }

    @Test("needs every term to match")
    func needsEveryTerm() {
        #expect(matches(drawer, placeTerms("kitchen oven")))
        #expect(!matches(drawer, placeTerms("kitchen garage")))
    }

    @Test("matches everything when nothing is typed")
    func matchesEverythingWhenNothingIsTyped() {
        #expect(matches(unnamedBox, []))
    }

    // 01 §13.8 #11: NFKD runs after lowercasing, so `™` folds to `TM` and misses `tm`.
    @Test("a typed ™ does not match a container named tm")
    func trademarkDoesNotMatchLowercase() {
        let tm = PlaceFields(name: "tm", shortCode: "BIN-2222", spaceName: "Shed", visualType: "bin")
        #expect(placeTerms("™") == ["TM"])
        #expect(!matches(tm, placeTerms("™")))
        #expect(matches(tm, placeTerms("tm")))
    }

    @Test("an unknown type adds no type name")
    func unknownTypeAddsNothing() {
        let odd = PlaceFields(name: "Odd", shortCode: "CTR-ABCD", spaceName: "Attic", visualType: "Box")
        #expect(!matches(odd, placeTerms("box")))
        #expect(!matches(odd, placeTerms("container")))
    }
}

@Suite("matchesPlace beyond ASCII")
struct MatchesPlaceBeyondASCIITests {
    let kitchen = PlaceFields(name: "Küche", shortCode: "DRW-1K2M", spaceName: "Haus", visualType: "drawer")
    let cyrillic = PlaceFields(name: "Кухня", shortCode: "BOX-4F2A", spaceName: "Дом", visualType: "box")

    @Test("finds an accented name typed with or without the accent")
    func findsAccentedNames() {
        #expect(matches(kitchen, placeTerms("kuche")))
        #expect(matches(kitchen, placeTerms("Küche")))
    }

    @Test("finds a name in another script, and does not match everything")
    func findsOtherScripts() {
        #expect(placeTerms("кухня") != [])
        #expect(matches(cyrillic, placeTerms("кух")))
        #expect(!matches(drawer, placeTerms("кухня")))
    }
}

@Suite("joinPlaceOptions")
struct JoinPlaceOptionsTests {
    @Test("adds each container’s space colour and icon")
    func addsSpaceColourAndIcon() {
        let row = ContainerWithSpace(
            container: Container(
                id: "c1", spaceId: "s1", name: nil, visualType: "drawer", shortCode: "DRW-1", createdAt: 0, updatedAt: 0
            ),
            spaceName: "Kitchen",
            itemCount: 3
        )
        let space = Space(id: "s1", name: "Kitchen", icon: "🍳", color: "#2E9E4F", createdAt: 0, updatedAt: 0)
        let joined = joinPlaceOptions([row], spaces: [space])
        let expected = [
            PlaceOption(
                id: "c1", name: nil, shortCode: "DRW-1", visualType: "drawer", spaceId: "s1", spaceName: "Kitchen",
                spaceColor: "#2E9E4F", spaceIcon: "🍳", itemCount: 3
            ),
        ]
        #expect(joined == expected)
        // The RN callers pass `spaces.listWithCounts()` rows.
        let counted = SpaceWithCounts(space: space, containerCount: 1, itemCount: 3)
        #expect(joinPlaceOptions([row], spaces: [counted]) == expected)
    }
}

@Suite("toPlaceOption")
struct ToPlaceOptionTests {
    @Test("gives no colour or icon for a space not known yet")
    func noColourOrIconForAnUnknownSpace() {
        let row = ContainerWithSpace(
            container: Container(
                id: "c9", spaceId: "s9", name: "Crate", visualType: "crate", shortCode: "CRT-9X", createdAt: 0, updatedAt: 0
            ),
            spaceName: "Shed",
            itemCount: 0
        )
        let option = toPlaceOption(row, space: nil)
        #expect(option.spaceColor == "")
        #expect(option.spaceIcon == "")
        #expect(option.spaceName == "Shed")
    }
}

@Suite("placeMatch parity (Fixtures/placeMatch.json, folding.json)")
struct PlaceMatchParityTests {
    struct Option: Decodable, PlaceMatchFields {
        let name: String?
        let shortCode: String
        let spaceName: String
        let visualType: ContainerVisualType
    }

    struct Result: Decodable { let option: Option; let matches: [Bool] }
    struct File: Decodable { let typeNames: [String: String]; let queries: [String]; let results: [Result] }

    @Test("matchesPlace matches JS")
    func matchesJS() throws {
        let file = try loadFixture("placeMatch", as: File.self)
        #expect(file.typeNames == englishTypeNames)
        for result in file.results {
            for (query, expected) in zip(file.queries, result.matches) {
                let actual = matchesPlace(result.option, terms: placeTerms(query)) { file.typeNames[$0.rawValue] }
                #expect(actual == expected, "\(result.option.shortCode) / \(scalarDump(query))")
            }
        }
    }

    @Test("placeTerms matches JS over the corpus")
    func placeTermsMatchJS() throws {
        let entries: [FoldingEntry] = try loadFixture("folding")
        for entry in entries {
            let actual = placeTerms(entry.input)
            #expect(sameScalars(actual, entry.placeTerms), "\(scalarDump(entry.input)): \(scalarDump(actual))")
        }
    }
}
