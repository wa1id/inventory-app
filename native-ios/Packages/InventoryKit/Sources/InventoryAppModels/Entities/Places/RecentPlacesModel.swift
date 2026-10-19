import InventoryStorage
import Observation

/// The containers this phone used last, as one screen sees them (RN `useRecentPlaces`,
/// src/hooks/useRecentPlaces.ts; 01 §8.2).
///
/// The list is read once, when the screen's model is made, and held for the screen's life: a
/// place remembered by the pick that closes a picker does not reorder that picker's rows (the
/// tapped row stays under the finger while the sheet slides away); the next screen sees the
/// new order. Callers filter the ids to containers that still exist.
@MainActor
@Observable
public final class RecentPlacesModel {
    /// Most recent first, as stored when the screen opened (at most six; never the drop zone).
    public let ids: [String]

    @ObservationIgnored private let store: RecentPlacesStore

    public init(store: RecentPlacesStore) {
        self.store = store
        ids = store.read()
    }

    /// Records a successful Add, Move or File into `containerId` (RN `rememberPlace`); the drop
    /// zone is ignored. ``ids`` does not change.
    public func remember(_ containerId: String) {
        store.remember(containerId)
    }
}
