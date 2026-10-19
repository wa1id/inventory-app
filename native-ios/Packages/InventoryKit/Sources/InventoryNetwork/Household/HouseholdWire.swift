import Foundation
import InventoryCore

// JSON shapes of the home-server API (04 §3.5-3.7) that InventoryCore's domain
// types do not already cover. Responses decode into the domain types wherever
// one exists (`Space`, `ItemWithContext`, …).

extension KeyedEncodingContainer {
    /// One tri-state field of a PATCH body: `.unchanged` leaves the key out (RN `undefined`),
    /// `.clear` sends JSON `null`, `.set` sends the value.
    ///
    /// The home server tells a missing key from a `null` one: `category: null`
    /// clears an item's category while a missing `category` leaves it alone (04 §3.7).
    /// Synthesized `Encodable` cannot express that, so patch bodies encode this by hand.
    mutating func encode<Value: Encodable>(_ field: FieldUpdate<Value>, forKey key: Key) throws {
        switch field {
        case .unchanged: break
        case .clear: try encodeNil(forKey: key)
        case .set(let value): try encode(value, forKey: key)
        }
    }
}

/// Request bodies for the household endpoints, as the RN client builds them:
/// RN `undefined` keys are omitted, `null` is sent only where the server tells
/// it apart from a missing key.
public enum HouseholdBody {
    /// `POST /v1/spaces` (RN `CreateSpaceInput`). The server trims `name`; all three must be non-empty.
    public struct NewSpace: Encodable, Sendable, Hashable {
        public var name: String
        public var icon: String
        public var color: String

        public init(name: String, icon: String, color: String) {
            self.name = name
            self.icon = icon
            self.color = color
        }
    }

    /// `PATCH /v1/spaces/:id` (RN `UpdateSpaceInput`). The server ignores `null`, so nil is simply omitted.
    public struct SpacePatch: Encodable, Sendable, Hashable {
        public var name: String?
        public var icon: String?
        public var color: String?

        public init(name: String? = nil, icon: String? = nil, color: String? = nil) {
            self.name = name
            self.icon = icon
            self.color = color
        }
    }

    /// `POST /v1/containers` (RN `{spaceId, visualType, name}`). A missing name and
    /// a `null` one are the same to the server: no name.
    public struct NewContainer: Encodable, Sendable, Hashable {
        public var spaceId: String
        public var visualType: ContainerVisualType
        public var name: String?

        public init(spaceId: String, visualType: ContainerVisualType, name: String? = nil) {
            self.spaceId = spaceId
            self.visualType = visualType
            self.name = name
        }
    }

    /// `PATCH /v1/containers/:id` (RN `UpdateContainerInput`). `name` clears with `null`.
    public struct ContainerPatch: Encodable, Sendable, Hashable {
        public var name: FieldUpdate<String>
        public var visualType: ContainerVisualType?
        public var spaceId: String?

        public init(name: FieldUpdate<String> = .unchanged, visualType: ContainerVisualType? = nil, spaceId: String? = nil) {
            self.name = name
            self.visualType = visualType
            self.spaceId = spaceId
        }

        private enum CodingKeys: String, CodingKey { case name, visualType, spaceId }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(visualType, forKey: .visualType)
            try container.encodeIfPresent(spaceId, forKey: .spaceId)
        }
    }

    /// The photo reference in `POST /v1/items`, taken from the `PUT /v1/photos/:id` answer.
    public struct PhotoReference: Encodable, Sendable, Hashable {
        public var id: String
        public var uri: String
        public var thumbUri: String?
        public var width: Int?
        public var height: Int?
        public var byteSize: Int?

        public init(id: String, uri: String, thumbUri: String? = nil, width: Int? = nil, height: Int? = nil, byteSize: Int? = nil) {
            self.id = id
            self.uri = uri
            self.thumbUri = thumbUri
            self.width = width
            self.height = height
            self.byteSize = byteSize
        }
    }

    /// `POST /v1/items` as JSON (RN `{containerId, name, category, quantity, notes, tags, photo?}`).
    ///
    /// Leave `name` nil for an item captured before it has a name; an explicitly
    /// blank name is refused by the server ("Item name is required."). A missing
    /// `category` or `notes` and a `null` one are the same to the server.
    public struct NewItem: Encodable, Sendable, Hashable {
        public var containerId: String
        public var name: String?
        public var category: String?
        public var quantity: Int?
        public var notes: String?
        public var tags: [String]?
        public var photo: PhotoReference?

        public init(
            containerId: String,
            name: String? = nil,
            category: String? = nil,
            quantity: Int? = nil,
            notes: String? = nil,
            tags: [String]? = nil,
            photo: PhotoReference? = nil
        ) {
            self.containerId = containerId
            self.name = name
            self.category = category
            self.quantity = quantity
            self.notes = notes
            self.tags = tags
            self.photo = photo
        }
    }

    /// `PATCH /v1/items/:id` (RN `UpdateItemInput`). `category` and `notes` clear
    /// with `null`; `name: null` would be ignored by the server, so `name` is a plain optional.
    public struct ItemPatch: Encodable, Sendable, Hashable {
        public var containerId: String?
        public var name: String?
        public var category: FieldUpdate<String>
        public var quantity: Int?
        public var notes: FieldUpdate<String>
        public var tags: [String]?
        /// The optimistic lock, sent as `updatedAt`: a stale value is answered 409.
        public var expectedUpdatedAt: Int64?

        public init(
            containerId: String? = nil,
            name: String? = nil,
            category: FieldUpdate<String> = .unchanged,
            quantity: Int? = nil,
            notes: FieldUpdate<String> = .unchanged,
            tags: [String]? = nil,
            expectedUpdatedAt: Int64? = nil
        ) {
            self.containerId = containerId
            self.name = name
            self.category = category
            self.quantity = quantity
            self.notes = notes
            self.tags = tags
            self.expectedUpdatedAt = expectedUpdatedAt
        }

        private enum CodingKeys: String, CodingKey {
            case containerId, name, category, quantity, notes, tags
            case expectedUpdatedAt = "updatedAt"
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(containerId, forKey: .containerId)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encode(category, forKey: .category)
            try container.encodeIfPresent(quantity, forKey: .quantity)
            try container.encode(notes, forKey: .notes)
            try container.encodeIfPresent(tags, forKey: .tags)
            try container.encodeIfPresent(expectedUpdatedAt, forKey: .expectedUpdatedAt)
        }
    }

    struct Pair: Encodable, Sendable {
        let bootstrapSecret: String
        let deviceName: String
    }

    struct BindLabel: Encodable, Sendable {
        let token: String
        let containerId: String
    }

    struct Scan: Encodable, Sendable {
        let raw: String
    }
}

/// A successful `POST /v1/pair`: what the phone keeps as its household session.
///
/// Persist it as InventoryStorage's `StoredHouseholdSession` (same five fields, same order).
public struct HouseholdPairing: Sendable, Hashable {
    /// The origin the server says to use from now on, trailing slashes stripped.
    public var origin: String
    /// The device bearer token, 64 hex characters.
    public var token: String
    public var deviceId: String
    /// The name the user typed, JS-trimmed.
    public var deviceName: String
    public var householdName: String

    public init(origin: String, token: String, deviceId: String, deviceName: String, householdName: String) {
        self.origin = origin
        self.token = token
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.householdName = householdName
    }
}

extension HouseholdPairing: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Leaves the token out of logs and `dump`.
    public var description: String {
        "HouseholdPairing(origin: \(origin), deviceId: \(deviceId), householdName: \(householdName))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["origin": origin, "deviceId": deviceId, "deviceName": deviceName, "householdName": householdName])
    }
}

/// A phone joined to the household (RN `HouseholdDevice`, src/services/household/devices.ts).
public struct HouseholdDevice: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Epoch milliseconds; 0 when the server sent something unreadable.
    public var createdAt: Int64
    /// When it last made a request; nil for a phone that never came back.
    public var lastSeenAt: Int64?

    public init(id: String, name: String, createdAt: Int64, lastSeenAt: Int64?) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }

    /// RN `toDevice`: skip entries without string `id` and `name`; coerce the
    /// timestamps with JS `Number()`, unreadable `createdAt` → 0, `lastSeenAt` → nil.
    init?(wire value: JSONValue) {
        guard let record = value.objectValue,
              let id = record["id"]?.stringValue,
              let name = record["name"]?.stringValue
        else { return nil }
        self.id = id
        self.name = name
        // A missing key is JS `undefined`: Number(undefined) is NaN.
        createdAt = record["createdAt"]?.jsNumber?.truncatedInt64 ?? 0
        if record["lastSeenAt"] == .null {
            lastSeenAt = nil
        } else {
            lastSeenAt = record["lastSeenAt"]?.jsNumber?.truncatedInt64
        }
    }
}

/// What a `DELETE` of a space, container or item came to (RN `{deleted, orphanedPhotoUris}`).
public struct HouseholdDeleteResult: Sendable, Hashable {
    /// False when the server answered 404: it was already gone.
    public var deleted: Bool
    /// The deleted rows' photo URIs (`r2:` strings from the server); local files only are deleted.
    public var orphanedPhotoUris: [String]

    public init(deleted: Bool, orphanedPhotoUris: [String]) {
        self.deleted = deleted
        self.orphanedPhotoUris = orphanedPhotoUris
    }

    /// RN's mapping of a 404.
    public static let alreadyGone = HouseholdDeleteResult(deleted: false, orphanedPhotoUris: [])
}

/// The answer to `PUT /v1/photos/:id` during an item create (RN `uploadHouseholdPhoto`):
/// `id` and `uri` are required, the rest is kept only when well typed.
public struct HouseholdUploadedPhoto: Sendable, Hashable {
    public var id: String
    /// `r2:household/primary/photos/<id>.webp`.
    public var uri: String
    public var thumbUri: String?
    public var width: Int?
    public var height: Int?
    public var byteSize: Int?

    public init(id: String, uri: String, thumbUri: String?, width: Int?, height: Int?, byteSize: Int?) {
        self.id = id
        self.uri = uri
        self.thumbUri = thumbUri
        self.width = width
        self.height = height
        self.byteSize = byteSize
    }

    init?(wire value: JSONValue) {
        guard let record = value.objectValue,
              let id = record["id"]?.stringValue,
              let uri = record["uri"]?.stringValue
        else { return nil }
        self.id = id
        self.uri = uri
        thumbUri = record["thumbUri"]?.stringValue
        width = record["width"]?.numberValue.flatMap { Int(exactly: $0) }
        height = record["height"]?.numberValue.flatMap { Int(exactly: $0) }
        byteSize = record["byteSize"]?.numberValue.flatMap { Int(exactly: $0) }
    }

    /// The `photo` object for ``HouseholdBody/NewItem``.
    public var reference: HouseholdBody.PhotoReference {
        HouseholdBody.PhotoReference(id: id, uri: uri, thumbUri: thumbUri, width: width, height: height, byteSize: byteSize)
    }
}

/// The answer to `POST /v1/import`: counts of the arrays sent, not of rows applied.
/// Each count is nil when the server did not send a number.
public struct HouseholdImportSummary: Sendable, Hashable {
    public var spaces: Int?
    public var containers: Int?
    public var items: Int?
    public var photos: Int?

    public init(spaces: Int?, containers: Int?, items: Int?, photos: Int?) {
        self.spaces = spaces
        self.containers = containers
        self.items = items
        self.photos = photos
    }

    init(wire value: JSONValue) {
        let record = value.objectValue ?? [:]
        func count(_ key: String) -> Int? { record[key]?.numberValue.flatMap { Int(exactly: $0) } }
        self.init(spaces: count("spaces"), containers: count("containers"), items: count("items"), photos: count("photos"))
    }
}

/// `GET /v1/health`: exactly `{ ok, contractVersion }`.
public struct HouseholdHealth: Sendable, Hashable, Decodable {
    public var ok: Bool
    public var contractVersion: Int

    public init(ok: Bool, contractVersion: Int) {
        self.ok = ok
        self.contractVersion = contractVersion
    }
}

// MARK: - Response wrappers
//
// RN casts list bodies without checking them and falls back to `[]` when the key
// is missing (`body.spaces ?? []`). Here a missing or `null` list reads as empty
// and anything else must decode, or the call fails with `invalid_response` (04 §4).

struct SpacesBody: Decodable {
    let spaces: [SpaceWithCounts]?
}

struct ContainersBody<Element: Decodable>: Decodable {
    let containers: [Element]?
}

struct ItemsBody: Decodable {
    let items: [ItemWithContext]?
}

/// `DELETE` answers: `orphanedPhotoUris ?? []`. RN reports `deleted: true` for any 2xx.
struct DeleteBody: Decodable {
    let orphanedPhotoUris: [String]?
}

/// `GET /v1/search`: RN keeps `items` only when it is an array (`[]` otherwise) and
/// passes `terms` and `locations` through; here missing ones read as empty.
struct SearchBody: Decodable {
    let results: SearchResults

    private enum CodingKeys: String, CodingKey { case terms, locations, items }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let terms = try container.decodeIfPresent([String].self, forKey: .terms) ?? []
        let locations = try container.decodeIfPresent([LocationSearchResult].self, forKey: .locations) ?? []
        var items: [ItemSearchResult] = []
        if (try? container.nestedUnkeyedContainer(forKey: .items)) != nil {
            items = try container.decode([ItemSearchResult].self, forKey: .items)
        }
        results = SearchResults(terms: terms, locations: locations, items: items)
    }
}

/// `POST /v1/qr/scan` (RN `ScanOutcome`): `{kind: "bound", container, token}`,
/// `{kind: "unknown", token}` or `{kind: "invalid", raw}`.
struct ScanBody: Decodable {
    let outcome: ScanOutcome

    private enum CodingKeys: String, CodingKey { case kind, container, token, raw }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(String.self, forKey: .kind)
        switch kind {
        case "bound":
            outcome = .bound(
                container: try values.decode(Container.self, forKey: .container),
                token: try values.decode(String.self, forKey: .token)
            )
        case "unknown":
            outcome = .unknown(token: try values.decode(String.self, forKey: .token))
        case "invalid":
            outcome = .invalid(raw: try values.decode(String.self, forKey: .raw))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: values, debugDescription: "unknown scan outcome")
        }
    }
}

/// A body whose content does not matter (a 2xx is all the caller needs).
struct IgnoredBody: Decodable {
    init(from decoder: any Decoder) throws {}
}
