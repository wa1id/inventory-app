import Foundation
import Testing
@testable import InventoryStorage

/// `src/services/places/__tests__/recentPlaces.test.ts` and
/// `src/hooks/__tests__/useRecentPlaces.test.tsx`.
@Suite("RecentPlacesStore (recentPlaces.test.ts)")
struct RecentPlacesStoreTests {
    @Test("mergeRecent puts the place first")
    func putsThePlaceFirst() {
        #expect(RecentPlacesStore.merge(["a", "b"], "c") == ["c", "a", "b"])
    }

    @Test("mergeRecent moves a place already in the list to the front instead of repeating it")
    func movesToFront() {
        #expect(RecentPlacesStore.merge(["a", "b", "c"], "b") == ["b", "a", "c"])
    }

    @Test("mergeRecent keeps at most six")
    func keepsAtMostSix() {
        let full = ["a", "b", "c", "d", "e", "f"]
        #expect(RecentPlacesStore.maxCount == 6)
        #expect(RecentPlacesStore.merge(full, "g") == ["g", "a", "b", "c", "d", "e"])
        #expect(RecentPlacesStore.merge(full, "g", max: 3) == ["g", "a", "b"])
    }

    @Test("mergeRecent never stores the drop zone")
    func neverStoresDropZone() {
        #expect(RecentPlacesStore.merge(["a"], "drop-zone") == ["a"])
        #expect(RecentPlacesStore.merge(["drop-zone", "a"], "b") == ["b", "a"])
    }

    @Test("rememberPlace persists the merged list and reads it back")
    func persistsAndReadsBack() {
        let preferences = InMemoryPreferences()
        let store = RecentPlacesStore(preferences: preferences)
        store.remember("a")
        store.remember("b")
        store.remember("drop-zone")
        store.remember("a")
        #expect(store.read() == ["a", "b"])
        #expect(preferences.values[PreferenceKey.recentPlaces] == #"["a","b"]"#)
    }

    @Test("useRecentPlaces takes the stored list, then holds it while the screen stays open")
    func holdsWhileOpen() {
        let store = RecentPlacesStore(preferences: InMemoryPreferences([PreferenceKey.recentPlaces: #"["a","b","c"]"#]))
        // A picker takes the list once when it is presented.
        let open = store.read()
        #expect(open == ["a", "b", "c"])
        // The pick that remembers "b" is the one that closes this screen.
        store.remember("b")
        #expect(open == ["a", "b", "c"])
        // The next picker sees the new order.
        #expect(store.read() == ["b", "a", "c"])
    }

    @Test("reads like readRecentPlaces() (TS vectors)")
    func vectors() throws {
        for vector in try AdoptionFixtures.decode([StringVector<[String]>].self, from: "recent-places-vectors.json") {
            let store = RecentPlacesStore(preferences: InMemoryPreferences([PreferenceKey.recentPlaces: vector.input]))
            #expect(store.read() == vector.expected, "\(vector.input)")
        }
    }

    @Test("02 §11.2 #4 cases", arguments: [
        (#"[1,"a"]"#, ["a"]),
        (#"["1","2","3","4","5","6","7"]"#, ["1", "2", "3", "4", "5", "6"]),
        (#"{"a":1}"#, []),
    ])
    func specCases(stored: String, expected: [String]) {
        let store = RecentPlacesStore(preferences: InMemoryPreferences([PreferenceKey.recentPlaces: stored]))
        #expect(store.read() == expected)
    }

    @Test("nothing stored reads as empty; remembering the drop zone writes nothing")
    func emptyAndDropZone() {
        let preferences = InMemoryPreferences()
        let store = RecentPlacesStore(preferences: preferences)
        #expect(store.read().isEmpty)
        store.remember("drop-zone")
        #expect(preferences.values.isEmpty)
    }
}
