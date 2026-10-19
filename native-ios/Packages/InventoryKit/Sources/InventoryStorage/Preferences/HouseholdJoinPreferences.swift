import Foundation
import InventoryCore

/// What this phone held of its own before it first joined a household, offered for copying in.
public struct ImportOffer: Sendable, Equatable, Hashable {
    /// Spaces, excluding the system drop-zone space.
    public var spaces: Int
    /// All items, drop zone included.
    public var items: Int

    public init(spaces: Int, items: Int) {
        self.spaces = spaces
        self.items = items
    }

    /// `JSON.stringify({spaces, items})`: `{"spaces":n,"items":n}`.
    var jsonString: String { "{\"spaces\":\(spaces),\"items\":\(items)}" }

    /// RN's `readImportOffer` rule: a JSON object whose `spaces` and `items` are both numbers.
    /// RN: src/services/household/importOffer.ts:53-72.
    ///
    /// Deliberate narrowing: a number that is not an integer within `Int`'s range reads as no
    /// offer, where RN would keep it. Only the app writes this key, always with integer counts.
    static func decode(_ stored: String?) -> ImportOffer? {
        guard let stored, !stored.isEmpty,
              case .object(let object)? = JSONValue.parse(stored),
              case .number(let spaces)? = object["spaces"],
              case .number(let items)? = object["items"],
              let spaceCount = Int(exactly: spaces), let itemCount = Int(exactly: items)
        else { return nil }
        return ImportOffer(spaces: spaceCount, items: itemCount)
    }
}

/// The two household preferences the join flow keeps: the one-time import offer and the
/// "joined before" marker that stops it from being made again (04 §11.1).
/// RN: src/services/household/importOffer.ts.
public struct HouseholdJoinPreferences: Sendable {
    private let preferences: any PreferenceStoring

    public init(preferences: any PreferenceStoring) {
        self.preferences = preferences
    }

    /// True once this phone has joined a household (stored exactly "true").
    public var hasJoinedBefore: Bool {
        preferences.storedString(forKey: PreferenceKey.householdJoinedBefore) == "true"
    }

    /// Set after a successful pair and on every start with a session (RN: importOffer.ts:45-51).
    public func markJoinedBefore() {
        preferences.setString("true", forKey: PreferenceKey.householdJoinedBefore)
    }

    /// The pending offer, or nil when there is none or it does not decode.
    public var importOffer: ImportOffer? {
        ImportOffer.decode(preferences.storedString(forKey: PreferenceKey.householdImportOffer))
    }

    /// Removes the offer: after copying, on "Not needed", and on leaving (RN: importOffer.ts:75-81).
    public func clearImportOffer() {
        preferences.removeValue(forKey: PreferenceKey.householdImportOffer)
    }

    /// Records what this phone holds on its own, just before it joins (RN: importOffer.ts:24-42).
    ///
    /// Does nothing on a phone that has joined before. Otherwise counts the local inventory:
    /// nothing at all removes any offer, anything stores `{"spaces":n,"items":n}`. A failed count
    /// writes nothing, because no offer is the safe failure.
    /// - Parameter countLocal: The number of local spaces (`listWithCounts().count`, which leaves
    ///   out the drop-zone space) and local items (`countAll()`).
    public func snapshotBeforeJoin(
        countLocal: @Sendable () async throws -> (spaces: Int, items: Int)
    ) async {
        guard !hasJoinedBefore else { return }
        guard let counts = try? await countLocal() else { return }
        if counts.spaces == 0 && counts.items == 0 {
            clearImportOffer()
        } else {
            let offer = ImportOffer(spaces: counts.spaces, items: counts.items)
            preferences.setString(offer.jsonString, forKey: PreferenceKey.householdImportOffer)
        }
    }
}
