import Foundation
import InventoryCore
import InventoryStrings
import Testing
@testable import InventoryAppModels

/// `src/ui/container/__tests__/containerRules.test.ts`.
private let entitiesToken = String(repeating: "a", count: 32)
private let entitiesOtherToken = String(repeating: "b", count: 32)

private func entitiesContainer(id: String = "c-1", name: String? = "Tool chest", shortCode: String = "CAB-J92R") -> Container {
    Container(id: id, spaceId: "s-1", name: name, visualType: .cabinet, shortCode: shortCode, createdAt: 1, updatedAt: 1)
}

@Suite("labelOf and titleOf (containerRules.test.ts)")
struct EntitiesLabelOfTests {
    @Test("uses the name, or else the code on the label")
    func labelOf() {
        #expect(ContainerRules.labelOf(name: "Tool chest", shortCode: "CAB-J92R") == "Tool chest")
        #expect(ContainerRules.labelOf(name: nil, shortCode: "BOX-7K2M") == "BOX-7K2M")
        #expect(ContainerRules.labelOf(name: "  ", shortCode: "BOX-7K2M") == "BOX-7K2M")
    }

    @Test("titles an unnamed container by its type, as the desk does")
    func titleOf() {
        #expect(ContainerRules.titleOf(name: nil, visualType: .box) == "Unnamed box")
        #expect(ContainerRules.titleOf(name: "", visualType: .drawer) == "Unnamed drawer")
        #expect(ContainerRules.titleOf(name: "Tool chest", visualType: .box) == "Tool chest")
    }

    @Test("reads an unknown stored type as a container")
    func unknownType() {
        #expect(ContainerRules.typeNameOf(.shelf) == "Shelf")
        #expect(ContainerRules.typeNameOf(ContainerVisualType("suitcase")) == "Container")
        #expect(ContainerRules.titleOf(name: nil, visualType: ContainerVisualType("suitcase")) == "Unnamed container")
    }
}

@Suite("sortContents (containerRules.test.ts)")
struct EntitiesSortContentsTests {
    struct Row: Equatable {
        let id: String
        let name: String
        let createdAt: Int64
    }

    private func sorted(_ rows: [Row]) -> [String] {
        ContainerRules.sortContents(rows, name: \.name, createdAt: \.createdAt).map(\.id)
    }

    @Test("sorts by name without case or accents, unnamed last by when they were added")
    func sorts() {
        let rows = [
            Row(id: "u2", name: "", createdAt: 20),
            Row(id: "b", name: "batteries", createdAt: 5),
            Row(id: "e", name: "Éclairs", createdAt: 6),
            Row(id: "u1", name: "  ", createdAt: 10),
            Row(id: "a", name: "Allen keys", createdAt: 7),
            Row(id: "z", name: "Zip ties", createdAt: 1),
        ]
        #expect(sorted(rows) == ["a", "b", "e", "z", "u1", "u2"])
    }

    @Test("keeps two items of the same name in the order they were added")
    func sameName() {
        #expect(sorted([Row(id: "later", name: "Screws", createdAt: 9), Row(id: "first", name: "screws", createdAt: 3)]) == ["first", "later"])
    }

    @Test("does not reorder the list it was given")
    func copies() {
        let rows = [Row(id: "1", name: "b", createdAt: 1), Row(id: "2", name: "a", createdAt: 2)]
        _ = sorted(rows)
        #expect(rows.first?.name == "b")
    }

    @Test("sorts a container's items")
    func items() {
        let items = [EntitiesFixtures.context(id: "z", name: "Zip ties"), EntitiesFixtures.context(id: "a", name: "allen keys")]
        #expect(ContainerRules.sortContents(items).map(\.id) == ["a", "z"])
    }
}

@Suite("isFreshArrival (containerRules.test.ts)")
struct EntitiesFreshArrivalTests {
    @Test("counts the last ten seconds, either side of a slightly different clock")
    func fresh() {
        let window = ContainerRules.freshArrivalMs
        #expect(ContainerRules.isFreshArrival(createdAt: 1_000, now: 1_000))
        #expect(ContainerRules.isFreshArrival(createdAt: 1_000, now: 1_000 + window - 1))
        #expect(!ContainerRules.isFreshArrival(createdAt: 1_000, now: 1_000 + window))
        #expect(ContainerRules.isFreshArrival(createdAt: 5_000, now: 1_000))
        #expect(!ContainerRules.isFreshArrival(createdAt: 1_000 + window * 3, now: 1_000))
    }
}

@Suite("planSticker (containerRules.test.ts)")
struct EntitiesPlanStickerTests {
    private func plan(_ outcome: ScanOutcome, name: String? = "Tool chest", qrToken: String? = nil) -> StickerPlan {
        ContainerRules.planSticker(outcome, targetId: "c-1", targetName: name, targetShortCode: "CAB-J92R", targetQrToken: qrToken)
    }

    @Test("ignores codes that are not ours")
    func invalid() {
        #expect(plan(.invalid(raw: "https://example.com")) == .invalid)
    }

    @Test("links a new sticker straight away when the container has no label")
    func linksNew() {
        #expect(plan(.unknown(token: entitiesToken)) == .link(token: entitiesToken, confirm: nil))
    }

    @Test("asks before replacing the label a container already has")
    func asksBeforeReplacing() {
        #expect(
            plan(.unknown(token: entitiesToken), qrToken: entitiesOtherToken)
                == .link(
                    token: entitiesToken,
                    confirm: ConfirmOptions(
                        title: "Replace the label on Tool chest?",
                        body: "Tool chest already has a label. Its old sticker will stop opening it.",
                        confirmLabel: "Replace"
                    )
                )
        )
    }

    @Test("says so when the sticker already opens this container")
    func already() {
        #expect(plan(.bound(container: entitiesContainer(), token: entitiesToken), qrToken: entitiesToken) == .already)
    }

    @Test("asks before moving a sticker from another container, naming both")
    func asksBeforeMoving() {
        #expect(
            plan(.bound(container: entitiesContainer(id: "c-2", name: "Shelf A"), token: entitiesToken))
                == .link(
                    token: entitiesToken,
                    confirm: ConfirmOptions(
                        title: "Move this sticker to Tool chest?",
                        body: "It opens Shelf A now. After this it opens Tool chest instead.",
                        confirmLabel: "Move sticker"
                    )
                )
        )
    }

    @Test("also says the old sticker stops working when the container had its own")
    func alsoReplacing() {
        let outcome = ScanOutcome.bound(container: entitiesContainer(id: "c-2", name: nil, shortCode: "SHL-4QW8"), token: entitiesToken)
        guard case .link(_, let confirm) = plan(outcome, name: nil, qrToken: entitiesOtherToken) else {
            Issue.record("expected link"); return
        }
        #expect(
            confirm
                == ConfirmOptions(
                    title: "Move this sticker to CAB-J92R?",
                    body: "It opens SHL-4QW8 now. After this it opens CAB-J92R instead. CAB-J92R already has a label. Its old sticker will stop opening it.",
                    confirmLabel: "Move sticker"
                )
        )
    }

    @Test("a container read with counts plans from its own label token")
    func withCounts() {
        let target = ContainerWithCounts(container: entitiesContainer(), itemCount: 2, qrToken: entitiesToken)
        #expect(ContainerRules.planSticker(.bound(container: entitiesContainer(), token: entitiesToken), target: target) == .already)
    }
}

@Suite("settleWrittenLabel (containerRules.test.ts)")
struct EntitiesSettleWrittenLabelTests {
    @Test("has nothing to hold before a write")
    func nothing() {
        #expect(ContainerRules.settleWrittenLabel(nil, loading: true, failed: false) == nil)
    }

    @Test("holds a fresh write until a read starts, then until it comes back")
    func holds() {
        let written = WrittenLabel(token: entitiesToken, reloading: false)
        #expect(ContainerRules.settleWrittenLabel(written, loading: false, failed: false) == written)
        let started = ContainerRules.settleWrittenLabel(written, loading: true, failed: false)
        #expect(started == WrittenLabel(token: entitiesToken, reloading: true))
        #expect(ContainerRules.settleWrittenLabel(started, loading: true, failed: false) == started)
        #expect(ContainerRules.settleWrittenLabel(started, loading: false, failed: false) == nil)
    }

    @Test("keeps showing the write when the read after it fails, until a later one succeeds")
    func failedRead() {
        let removed = WrittenLabel(token: nil, reloading: true)
        let kept = ContainerRules.settleWrittenLabel(removed, loading: false, failed: true)
        #expect(kept == WrittenLabel(token: nil, reloading: false))
        #expect(ContainerRules.settleWrittenLabel(kept, loading: false, failed: true) == kept)
        let retried = ContainerRules.settleWrittenLabel(kept, loading: true, failed: false)
        #expect(retried == WrittenLabel(token: nil, reloading: true))
        #expect(ContainerRules.settleWrittenLabel(retried, loading: false, failed: false) == nil)
    }
}

@Suite("labelFailureMessage (containerRules.test.ts)")
struct EntitiesLabelFailureMessageTests {
    private let offline = HouseholdHttpError(status: 0, code: "offline")
    private let server = HouseholdHttpError(status: 500, code: "http_500")

    @Test("says the old sticker still works when a replace or remove did not happen")
    func stillWorks() {
        #expect(ContainerRules.labelFailureMessage(.replace, cause: offline)
            == "The label was not replaced, so the old sticker still works. Check the connection and try again.")
        #expect(ContainerRules.labelFailureMessage(.remove, cause: server)
            == "The label was not removed, so the sticker still opens this container. Try again.")
        #expect(ContainerRules.labelFailureMessage(.make, cause: EntitiesFailure("SQLITE_BUSY")) == "The label was not made. Try again.")
    }

    @Test("says when the container was deleted elsewhere")
    func gone() {
        #expect(ContainerRules.labelFailureMessage(.make, cause: HouseholdHttpError(status: 404, code: "not_found"))
            == "This container is not in the household any more. Nothing else changed.")
    }

    @Test("never shows a raw code")
    func noRawCode() {
        for action in [QrLabelAction.make, .replace, .remove] {
            let message = ContainerRules.labelFailureMessage(action, cause: HouseholdHttpError(status: 530, code: "http_530"))
            #expect(!message.contains("http_") && !message.contains("offline") && !message.contains("timeout"))
        }
    }
}

@Suite("shareText (containerRules.test.ts)")
struct EntitiesShareTextTests {
    @Test("names the container by label and code, adding the link only where no picture goes")
    func shareText() {
        let payload = formatQrPayload(entitiesToken)
        #expect(ContainerRules.shareText(name: "Tool chest", shortCode: "CAB-J92R", payload: payload, withPayload: false) == "Tool chest (CAB-J92R)")
        #expect(ContainerRules.shareText(name: nil, shortCode: "BOX-7K2M", payload: payload, withPayload: true) == "BOX-7K2M (BOX-7K2M)\n\(payload)")
    }
}

/// The container rules and the sorts against `Fixtures/entities/entities-vectors.json`.
@Suite("container rules parity (Fixtures/entities)")
struct EntitiesContainerRulesParityTests {
    struct RuleCase: Decodable {
        let name: String?
        let labelOf: String
        let titleOf: String
        let shareText: String
    }

    struct TypeCase: Decodable {
        let type: String
        let typeName: String
        let title: String
    }

    struct Content: Decodable {
        let id: String
        let name: String
        let createdAt: Int64
    }

    struct SortCase: Decodable {
        let items: [Content]
        let expected: [String]
    }

    struct Pair: Decodable {
        let a: String
        let b: String
        let sign: Int
    }

    struct Fixture: Decodable {
        let containerRules: [RuleCase]
        let typeNames: [TypeCase]
        let sortContents: [SortCase]
        let localeCompare: [Pair]
    }

    private func fixture() throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "entities-vectors", withExtension: "json", subdirectory: "Fixtures/entities"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test("labelOf, titleOf, typeNameOf and shareText match JS")
    func rules() throws {
        let fixture = try fixture()
        let payload = formatQrPayload(entitiesToken)
        for vector in fixture.containerRules {
            #expect(EntitiesUnits.of(ContainerRules.labelOf(name: vector.name, shortCode: "BOX-7K2M")) == EntitiesUnits.of(vector.labelOf))
            #expect(ContainerRules.titleOf(name: vector.name, visualType: .drawer).utf16.elementsEqual(vector.titleOf.utf16))
            #expect(ContainerRules.shareText(name: vector.name, shortCode: "BOX-7K2M", payload: payload, withPayload: true)
                .utf16.elementsEqual(vector.shareText.utf16))
        }
        for vector in fixture.typeNames {
            #expect(ContainerRules.typeNameOf(ContainerVisualType(vector.type)) == vector.typeName, "\(vector.type)")
            #expect(ContainerRules.titleOf(name: nil, visualType: ContainerVisualType(vector.type)) == vector.title, "\(vector.type)")
        }
    }

    @Test("sortContents matches JS")
    func sortContents() throws {
        for vector in try fixture().sortContents {
            let sorted = ContainerRules.sortContents(vector.items, name: \.name, createdAt: \.createdAt).map(\.id)
            #expect(sorted == vector.expected)
        }
    }

    @Test("base-strength comparison orders pairs as localeCompare('en', {sensitivity: 'base'}) does")
    func localeCompare() throws {
        var mismatches: [String] = []
        for pair in try fixture().localeCompare {
            let sign = switch EntityText.localeCompareBase(pair.a, pair.b) {
            case .orderedAscending: -1
            case .orderedSame: 0
            case .orderedDescending: 1
            }
            if sign != pair.sign {
                mismatches.append("\(pair.a.unicodeScalars.map { String($0.value, radix: 16) }) vs \(pair.b.unicodeScalars.map { String($0.value, radix: 16) }): JS \(pair.sign), Swift \(sign)")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches:\n\(mismatches.joined(separator: "\n"))")
    }
}
