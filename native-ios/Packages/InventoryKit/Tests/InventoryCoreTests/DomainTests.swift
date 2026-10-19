import Foundation
import Testing
@testable import InventoryCore

// Domain types: stored raw values round-trip, flat household JSON, constants,
// ConflictError, QR payloads (RN src/repositories/qr.ts:29-46; the parsing cases
// of persistence.test.ts:473-492) and splitTagNames.

private let space = Space(id: "s1", name: "Garage", icon: "🚗", color: "#5B8DEF", createdAt: 1, updatedAt: 2)
private let container = Container(
    id: "c1", spaceId: "s1", name: nil, visualType: "drawer", shortCode: "DRW-7K2M", createdAt: 3, updatedAt: 4
)
private let item = Item(
    id: "i1", containerId: "c1", name: "", category: "Tools", quantity: 12_000, notes: nil, createdAt: 5, updatedAt: 6
)

private func json(_ value: some Encodable) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite("stored values")
struct StoredValueTests {
    @Test("visual types keep unknown raw values")
    func visualTypesKeepUnknownValues() throws {
        #expect(ContainerVisualType.allKnown.map(\.rawValue) == ["box", "drawer", "shelf", "cabinet", "bin", "bag", "crate", "other"])
        let unknown = ContainerVisualType("Box")
        #expect(!unknown.isKnown)
        #expect(unknown != .box)
        let decoded = try JSONDecoder().decode([ContainerVisualType].self, from: Data(#"["box","Crate","tub"]"#.utf8))
        #expect(decoded == [.box, "Crate", "tub"])
        #expect(String(data: try JSONEncoder().encode(decoded), encoding: .utf8) == #"["box","Crate","tub"]"#)
    }

    @Test("record kinds use the stored strings")
    func recordKinds() {
        #expect(RecordKind.normal.rawValue == "normal")
        #expect(RecordKind.system.rawValue == "system")
        #expect(RecordKind(rawValue: "archived").rawValue == "archived")
    }

    @Test("drop-zone ids and the tag delimiter")
    func constants() {
        #expect(DropZone.containerId == "drop-zone")
        #expect(DropZone.spaceId == "drop-zone-space")
        #expect(tagDelimiter.value == 0x1F)
    }

    @Test("splitTagNames splits on U+001F and drops empty pieces")
    func splitTagNamesBehaviour() {
        #expect(splitTagNames(nil) == [])
        #expect(splitTagNames("") == [])
        #expect(splitTagNames("dewalt") == ["dewalt"])
        #expect(splitTagNames("dewalt\u{1F}18v") == ["dewalt", "18v"])
        #expect(splitTagNames("\u{1F}a\u{1F}\u{1F}b\u{1F}") == ["a", "b"])
        #expect(splitTagNames("power tool, red") == ["power tool, red"])
    }

    @Test("epochMillis floors to whole milliseconds")
    func epochMillisFloors() {
        #expect(epochMillis(Date(timeIntervalSince1970: 1.9999)) == 1999)
        #expect(epochMillis(Date(timeIntervalSince1970: 1_790_000_000)) == 1_790_000_000_000)
    }
}

@Suite("entities")
struct EntityTests {
    @Test("entities encode with the TS field names")
    func entityKeys() throws {
        #expect(try json(space).keys.sorted() == ["color", "createdAt", "icon", "id", "name", "updatedAt"])
        #expect(try json(container)["visualType"] as? String == "drawer")
        #expect(try json(container)["name"] == nil)
        let photo = ItemPhoto(
            id: "p1", itemId: "i1", uri: "file:///x.webp", thumbUri: nil, width: 1, height: 2, byteSize: 3, createdAt: 7
        )
        #expect(try json(photo).keys.sorted() == ["byteSize", "createdAt", "height", "id", "itemId", "uri", "width"])
        let tag = Tag(id: "t1", name: "DeWalt", normalizedName: "dewalt", createdAt: 8)
        #expect(try json(tag)["normalizedName"] as? String == "dewalt")
        let binding = QrBinding(id: "q1", token: String(repeating: "a", count: 32), containerId: "c1", createdAt: 9, updatedAt: 9)
        #expect(try json(binding)["containerId"] as? String == "c1")
    }

    @Test("enriched types forward the entity's fields")
    func dynamicMembers() {
        var counted = ContainerWithCounts(container: container, itemCount: 2, qrToken: nil)
        #expect(counted.shortCode == "DRW-7K2M")
        #expect(counted.id == "c1")
        counted.name = "Cutlery"
        #expect(counted.container.name == "Cutlery")

        let withCounts = SpaceWithCounts(space: space, containerCount: 1, itemCount: 2)
        #expect(withCounts.name == "Garage")

        let context = ItemWithContext(
            item: item, photoId: nil, photoUri: nil, photoThumbUri: nil, tags: ["a"], spaceId: "s1",
            spaceName: "Garage", spaceIcon: "🚗", spaceColor: "#5B8DEF", containerName: nil, containerShortCode: "DRW-7K2M"
        )
        let result = ItemSearchResult(item: context, matchKind: .location)
        #expect(result.quantity == 12_000)
        #expect(result.containerShortCode == "DRW-7K2M")
        #expect(result.item.item == item)
    }

    @Test("enriched types are flat in JSON and round-trip")
    func flatJSON() throws {
        let context = ItemWithContext(
            item: item, photoId: "p1", photoUri: "r2:p1", photoThumbUri: nil, tags: ["dewalt", "18v"], spaceId: "s1",
            spaceName: "Garage", spaceIcon: "🚗", spaceColor: "#5B8DEF", containerName: "Tool box", containerShortCode: "BOX-1"
        )
        let result = ItemSearchResult(item: context, matchKind: .direct)
        let object = try json(result)
        #expect(object["name"] as? String == "")
        #expect(object["quantity"] as? Int == 12_000)
        #expect(object["matchKind"] as? String == "direct")
        #expect(object["tags"] as? [String] == ["dewalt", "18v"])
        #expect(object["photoThumbUri"] == nil)

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        #expect(try decoder.decode(ItemSearchResult.self, from: encoder.encode(result)) == result)

        let counted = ContainerWithCounts(container: container, itemCount: 2, qrToken: "ab")
        #expect(try json(counted)["qrToken"] as? String == "ab")
        #expect(try decoder.decode(ContainerWithCounts.self, from: encoder.encode(counted)) == counted)

        let withCounts = SpaceWithCounts(space: space, containerCount: 1, itemCount: 2)
        #expect(try json(withCounts)["containerCount"] as? Int == 1)
        #expect(try decoder.decode(SpaceWithCounts.self, from: encoder.encode(withCounts)) == withCounts)

        let withSpace = ContainerWithSpace(container: container, spaceName: "Garage", itemCount: 0)
        #expect(try decoder.decode(ContainerWithSpace.self, from: encoder.encode(withSpace)) == withSpace)

        let results = SearchResults(
            terms: ["drill"],
            locations: [LocationSearchResult(kind: .space, id: "s1", title: "Garage", subtitle: "1 container · 2 items", spaceId: "s1", itemCount: 2)],
            items: [result]
        )
        #expect(try decoder.decode(SearchResults.self, from: encoder.encode(results)) == results)
        #expect(SearchResults.empty.terms.isEmpty && SearchResults.empty.items.isEmpty && SearchResults.empty.locations.isEmpty)
    }

    @Test("decodes household JSON with null optionals")
    func decodesNulls() throws {
        let body = #"""
        {"id":"c1","spaceId":"s1","name":null,"visualType":"tub","shortCode":"CTR-1","createdAt":1,"updatedAt":2,
         "itemCount":0,"qrToken":null}
        """#
        let decoded = try JSONDecoder().decode(ContainerWithCounts.self, from: Data(body.utf8))
        #expect(decoded.name == nil)
        #expect(decoded.visualType == "tub")
        #expect(decoded.qrToken == nil)
    }
}

@Suite("ConflictError")
struct ConflictErrorTests {
    @Test("carries 409, conflict and the current updatedAt")
    func fields() {
        let error = ConflictError(updatedAt: 150)
        #expect(error.status == 409)
        #expect(error.code == "conflict")
        #expect(error.description == "conflict")
        #expect(error.updatedAt == 150)
        #expect(ConflictError().updatedAt == nil)
    }

    @Test("is thrown and caught as a type")
    func throwsAsAType() {
        #expect(throws: ConflictError(updatedAt: 1)) { throw ConflictError(updatedAt: 1) }
    }
}

@Suite("QR payloads")
struct QrPayloadTests {
    let token = String(repeating: "a", count: 32)

    @Test("formats the deep-link form")
    func formats() {
        #expect(formatQrPayload(token) == "inventory://c/" + token)
    }

    @Test("parses the deep-link form and a bare token, lowercased")
    func parses() {
        #expect(parseQrPayload("inventory://c/" + token) == token)
        #expect(parseQrPayload("  " + token.uppercased() + "\n") == token)
        #expect(parseQrPayload("inventory://c/" + token.uppercased()) == token)
    }

    @Test("rejects anything that is not 32 hex characters")
    func rejects() {
        #expect(parseQrPayload("https://example.com") == nil)
        #expect(parseQrPayload("") == nil)
        #expect(parseQrPayload("INVENTORY://c/" + token) == nil)
        #expect(parseQrPayload(String(token.dropLast())) == nil)
        #expect(parseQrPayload(token + "a") == nil)
        #expect(parseQrPayload(String(repeating: "g", count: 32)) == nil)
        #expect(parseQrPayload(String(repeating: "０", count: 32)) == nil)
    }

    @Test("matches JS over the corpus")
    func corpus() throws {
        let entries: [FoldingEntry] = try loadFixture("folding")
        for entry in entries {
            #expect(parseQrPayload(entry.input) == entry.qr, "\(scalarDump(entry.input))")
        }
        let token = newQrToken()
        #expect(parseQrPayload(formatQrPayload(token)) == token)
    }
}
