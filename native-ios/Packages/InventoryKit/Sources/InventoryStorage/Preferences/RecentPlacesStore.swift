import Foundation
import InventoryCore

/// Containers this phone last added to, moved to, filed in or bound a label to, most recent
/// first (01 §8.2). A preference, not inventory. RN: src/services/places/recentPlaces.ts.
///
/// Reads are synchronous, so there is no "not read yet" state. A picker takes ``read()`` once
/// when it is presented and keeps that list while it is open, so the row just tapped stays put
/// while the sheet closes (RN: src/hooks/useRecentPlaces.ts); the next picker sees the new order.
public struct RecentPlacesStore: Sendable {
    /// How many recent containers are kept; pickers show fewer. RN: recentPlaces.ts:8.
    public static let maxCount = 6

    /// The drop zone is never a recent place. RN: src/db/constants.ts:26.
    static let dropZoneContainerId = "drop-zone"

    private let preferences: any PreferenceStoring

    public init(preferences: any PreferenceStoring) {
        self.preferences = preferences
    }

    /// `id` moved to the front of `list`, without duplicates and never the drop zone, capped at
    /// `max`. Other duplicates already in `list` stay. RN: `mergeRecent`, recentPlaces.ts:16-23.
    public static func merge(_ list: [String], _ id: String, max: Int = maxCount) -> [String] {
        let idKey = JS.Key(id)
        let dropZone = JS.Key(dropZoneContainerId)
        let rest = list.filter { JS.Key($0) != idKey && JS.Key($0) != dropZone }
        let merged = idKey == dropZone ? rest : [id] + rest
        // `slice(0, max)`: a negative end counts back from the end.
        let end = max >= 0 ? Swift.min(max, merged.count) : Swift.max(merged.count + max, 0)
        return Array(merged.prefix(end))
    }

    /// RN's read rule: parse; anything but an array is empty; keep only the strings, without
    /// de-duplicating; first six. Unparsable text is empty too (RN: recentPlaces.ts:40-54).
    static func decode(_ stored: String?) -> [String] {
        guard let stored, !stored.isEmpty, case .array(let values)? = JSONValue.parse(stored) else {
            return []
        }
        let ids = values.compactMap { value -> String? in
            if case .string(let id) = value { return id }
            return nil
        }
        return Array(ids.prefix(maxCount))
    }

    /// The stored list, most recent first.
    public func read() -> [String] {
        Self.decode(preferences.storedString(forKey: PreferenceKey.recentPlaces))
    }

    /// Call after a successful Add, Move, File, label bind or new-container pick.
    /// The drop zone is ignored (RN: recentPlaces.ts:57-66).
    public func remember(_ containerId: String) {
        guard JS.Key(containerId) != JS.Key(Self.dropZoneContainerId) else { return }
        let next = Self.merge(read(), containerId)
        preferences.setString(JSONValue.array(next.map(JSONValue.string)).jsonText, forKey: PreferenceKey.recentPlaces)
    }
}
