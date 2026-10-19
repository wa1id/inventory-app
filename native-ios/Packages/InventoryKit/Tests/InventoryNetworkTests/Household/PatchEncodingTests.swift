import Foundation
import InventoryCore
import Testing
@testable import InventoryNetwork

/// The PATCH bodies byte for byte.
///
/// These literals were recorded while the tri-state fields were still InventoryNetwork's own
/// `PatchField`; they pin that moving to InventoryCore's `FieldUpdate` changed no byte:
/// `.unchanged` leaves the key out, `.clear` sends `null`, `.set` sends the value.
///
/// `JSONEncoder` orders object keys by a hash seeded per process, so the same body comes out
/// in a different key order from one run to the next (the servers parse JSON, so that never
/// mattered). The bytes are compared with sorted keys, which removes exactly that freedom
/// and nothing else; the body the client really sends is checked to parse to the same value.
@Suite("PATCH body encoding")
struct PatchEncodingTests {
    private static func sortedBytes(_ value: some Encodable) throws -> String {
        let encoder = wireJSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func sent(_ value: some Encodable) throws -> JSONValue? {
        guard case .json(let data) = try HouseholdRequest.Body.encodedJSON(value) else { return nil }
        return JSONValue.parse(data)
    }

    @Test("item patches", arguments: [
        (HouseholdBody.ItemPatch(category: .clear, notes: .unchanged), #"{"category":null}"#),
        (HouseholdBody.ItemPatch(), "{}"),
        (HouseholdBody.ItemPatch(notes: .set("Left shelf / top")), #"{"notes":"Left shelf / top"}"#),
        (
            HouseholdBody.ItemPatch(
                containerId: "c", name: "Drill", category: .set("Tools/Hand"), quantity: 0,
                notes: .clear, tags: ["a", "b"], expectedUpdatedAt: 7
            ),
            #"{"category":"Tools/Hand","containerId":"c","name":"Drill","notes":null,"quantity":0,"tags":["a","b"],"updatedAt":7}"#
        ),
    ])
    func itemPatches(patch: HouseholdBody.ItemPatch, expected: String) throws {
        let actual = try Self.sortedBytes(patch)
        #expect(actual == expected)
        #expect(try Self.sent(patch) == JSONValue.parse(expected))
    }

    @Test("container patches", arguments: [
        (HouseholdBody.ContainerPatch(name: .clear), #"{"name":null}"#),
        (HouseholdBody.ContainerPatch(spaceId: "s2"), #"{"spaceId":"s2"}"#),
        (HouseholdBody.ContainerPatch(name: .set("Bits"), visualType: .bin, spaceId: "s2"), #"{"name":"Bits","spaceId":"s2","visualType":"bin"}"#),
        (HouseholdBody.ContainerPatch(), "{}"),
    ])
    func containerPatches(patch: HouseholdBody.ContainerPatch, expected: String) throws {
        let actual = try Self.sortedBytes(patch)
        #expect(actual == expected)
        #expect(try Self.sent(patch) == JSONValue.parse(expected))
    }
}
