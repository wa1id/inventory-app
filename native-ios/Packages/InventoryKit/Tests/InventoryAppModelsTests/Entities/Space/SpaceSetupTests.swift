import Foundation
import InventoryCore
import Testing
@testable import InventoryAppModels

/// `src/ui/spaces/__tests__/spaceSetup.test.ts`.
@Suite("containerLabel and byContainerLabel (spaceSetup.test.ts)")
struct EntitiesContainerLabelTests {
    struct Row {
        let name: String?
        let shortCode: String
    }

    @Test("reads a container by its name, or by its code when it has none")
    func label() {
        #expect(SpaceSetup.containerLabel(name: "Tool chest", shortCode: "CAB-J92R") == "Tool chest")
        #expect(SpaceSetup.containerLabel(name: nil, shortCode: "CAB-J92R") == "CAB-J92R")
    }

    @Test("sorts by label without regard to case or accents, codes alongside names")
    func sorts() {
        let rows = [
            Row(name: "drawer by the oven", shortCode: "DRW-7K2M"),
            Row(name: nil, shortCode: "BOX-4F2A"),
            Row(name: "Étagère", shortCode: "SHF-2222"),
            Row(name: "Attic box", shortCode: "BOX-9999"),
        ]
        let sorted = SpaceSetup.sortedByLabel(rows, name: \.name, shortCode: \.shortCode)
        #expect(sorted.map { SpaceSetup.containerLabel(name: $0.name, shortCode: $0.shortCode) }
            == ["Attic box", "BOX-4F2A", "drawer by the oven", "Étagère"])
    }
}

@Suite("taken space names (spaceSetup.test.ts)")
struct EntitiesTakenSpaceNamesTests {
    @Test("finds a preset name already used, ignoring case and surrounding spaces")
    func taken() {
        let taken = SpaceSetup.takenSpaceNames([" garage ", "Kitchen"])
        #expect(SpaceSetup.isNameTaken("Garage", taken: taken))
        #expect(SpaceSetup.isNameTaken("KITCHEN", taken: taken))
        #expect(!SpaceSetup.isNameTaken("Loft", taken: taken))
    }
}

@Suite("labelsInSpace (spaceSetup.test.ts)")
struct EntitiesLabelsInSpaceTests {
    @Test("counts linked containers when the impact reports none (paired)")
    func paired() {
        #expect(SpaceSetup.labelsInSpace(impactLabels: 0, qrTokens: ["a", nil, "b"]) == 2)
    }

    @Test("keeps the impact count when it is the larger (local)")
    func local() {
        #expect(SpaceSetup.labelsInSpace(impactLabels: 3, qrTokens: ["a"]) == 3)
    }

    @Test("an empty token is no label, as JS Boolean('') is false")
    func emptyToken() {
        #expect(SpaceSetup.labelsInSpace(impactLabels: 0, qrTokens: ["", "a"]) == 1)
    }
}

@Suite("delete confirm bodies (spaceSetup.test.ts)")
struct EntitiesDeleteBodiesTests {
    @Test("spells out what a space takes with it")
    func space() {
        #expect(SpaceSetup.spaceDeleteBody(containerCount: 3, itemCount: 21, labels: 2)
            == "This also deletes 3 containers and 21 items, and unlinks 2 QR labels. This cannot be undone.")
        #expect(SpaceSetup.spaceDeleteBody(containerCount: 1, itemCount: 1, labels: 0)
            == "This also deletes 1 container and 1 item. This cannot be undone.")
        #expect(SpaceSetup.spaceDeleteBody(containerCount: 1, itemCount: 0, labels: 1)
            == "This also deletes 1 container and 0 items, and unlinks 1 QR label. This cannot be undone.")
    }

    @Test("says so when a space is empty")
    func emptySpace() {
        #expect(SpaceSetup.spaceDeleteBody(containerCount: 0, itemCount: 0, labels: 0) == "This space is empty.")
    }

    @Test("spells out what a container takes with it")
    func container() {
        #expect(SpaceSetup.containerDeleteBody(itemCount: 5, hasQrBinding: true)
            == "This also deletes 5 items and unlinks its QR label. This cannot be undone.")
        #expect(SpaceSetup.containerDeleteBody(itemCount: 1, hasQrBinding: false) == "This also deletes 1 item. This cannot be undone.")
        #expect(SpaceSetup.containerDeleteBody(itemCount: 0, hasQrBinding: true) == "This container is empty. Its QR label will be unlinked.")
        #expect(SpaceSetup.containerDeleteBody(ContainerDeletionImpact(itemCount: 0, photoCount: 0, hasQrBinding: false)) == "This container is empty.")
    }
}

@Suite("spaceValuesChanged (spaceSetup.test.ts)")
struct EntitiesSpaceValuesChangedTests {
    private let initial = SpaceFormValues(name: "Garage", icon: "🚗", color: "#5B8DEF")

    @Test("ignores spaces the repository would trim anyway")
    func ignoresSpaces() {
        #expect(!SpaceSetup.spaceValuesChanged(SpaceFormValues(name: " Garage ", icon: "🚗", color: "#5B8DEF"), initial: initial))
    }

    @Test("notices any real change")
    func notices() {
        #expect(SpaceSetup.spaceValuesChanged(SpaceFormValues(name: "Shed", icon: "🚗", color: "#5B8DEF"), initial: initial))
        #expect(SpaceSetup.spaceValuesChanged(SpaceFormValues(name: "Garage", icon: "🧰", color: "#5B8DEF"), initial: initial))
        #expect(SpaceSetup.spaceValuesChanged(SpaceFormValues(name: "Garage", icon: "🚗", color: "#2E9E4F"), initial: initial))
    }
}

@Suite("containerValuesChanged (spaceSetup.test.ts)")
struct EntitiesContainerValuesChangedTests {
    private let initial = ContainerFormValues(name: "Tool chest", visualType: .cabinet, spaceId: "garage")

    @Test("ignores surrounding spaces in the name")
    func ignoresSpaces() {
        #expect(!SpaceSetup.containerValuesChanged(ContainerFormValues(name: "Tool chest ", visualType: .cabinet, spaceId: "garage"), initial: initial))
    }

    @Test("notices a new name, an emptied name, a new type and a new space")
    func notices() {
        for values in [
            ContainerFormValues(name: "Red chest", visualType: .cabinet, spaceId: "garage"),
            ContainerFormValues(name: "", visualType: .cabinet, spaceId: "garage"),
            ContainerFormValues(name: "Tool chest", visualType: .box, spaceId: "garage"),
            ContainerFormValues(name: "Tool chest", visualType: .cabinet, spaceId: "loft"),
        ] {
            #expect(SpaceSetup.containerValuesChanged(values, initial: initial))
        }
    }
}

/// The space rules against `Fixtures/entities/entities-vectors.json`: Unicode case folding of
/// space names, exact icon and colour comparison, and the stable label sort.
@Suite("space setup parity (Fixtures/entities)")
struct EntitiesSpaceSetupParityTests {
    struct Space: Decodable {
        let name: String
        let icon: String
        let color: String
    }

    struct SpaceChange: Decodable {
        let values: Space
        let initial: Space
        let changed: Bool
    }

    struct ContainerValues: Decodable {
        let name: String
        let visualType: String
        let spaceId: String

        var form: ContainerFormValues { ContainerFormValues(name: name, visualType: ContainerVisualType(visualType), spaceId: spaceId) }
    }

    struct ContainerChange: Decodable {
        let values: ContainerValues
        let initial: ContainerValues
        let changed: Bool
    }

    struct Probe: Decodable {
        let name: String
        let taken: Bool
    }

    struct Taken: Decodable {
        let spaces: [String]
        let keys: [String]
        let probes: [Probe]
    }

    struct Labelled: Decodable {
        let name: String?
        let shortCode: String
    }

    struct SortCase: Decodable {
        let containers: [Labelled]
        let expected: [Int]
    }

    struct Fixture: Decodable {
        let takenNames: Taken
        let spaceValuesChanged: [SpaceChange]
        let containerValuesChanged: [ContainerChange]
        let byContainerLabel: [SortCase]
    }

    private func fixture() throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "entities-vectors", withExtension: "json", subdirectory: "Fixtures/entities"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test("takenSpaceNames and isNameTaken match JS")
    func takenNames() throws {
        let vectors = try fixture().takenNames
        let taken = SpaceSetup.takenSpaceNames(vectors.spaces)
        #expect(Set(taken.keys.map { Array($0.utf16) }) == Set(vectors.keys.map { Array($0.utf16) }))
        for probe in vectors.probes {
            #expect(SpaceSetup.isNameTaken(probe.name, taken: taken) == probe.taken, "\(probe.name)")
        }
    }

    @Test("spaceValuesChanged and containerValuesChanged match JS")
    func changes() throws {
        let fixture = try fixture()
        for vector in fixture.spaceValuesChanged {
            let values = SpaceFormValues(name: vector.values.name, icon: vector.values.icon, color: vector.values.color)
            let initial = SpaceFormValues(name: vector.initial.name, icon: vector.initial.icon, color: vector.initial.color)
            #expect(SpaceSetup.spaceValuesChanged(values, initial: initial) == vector.changed, "\(vector.values)")
        }
        for vector in fixture.containerValuesChanged {
            #expect(SpaceSetup.containerValuesChanged(vector.values.form, initial: vector.initial.form) == vector.changed, "\(vector.values)")
        }
    }

    @Test("byContainerLabel matches JS's stable sort")
    func sort() throws {
        for vector in try fixture().byContainerLabel {
            let indexed = Array(vector.containers.enumerated())
            let sorted = SpaceSetup.sortedByLabel(indexed, name: \.element.name, shortCode: \.element.shortCode).map(\.offset)
            #expect(sorted == vector.expected)
        }
    }
}
