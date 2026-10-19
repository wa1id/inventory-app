/// Something that can tell every screen the inventory changed.
///
/// RN: `invalidate()` from `DatabaseProvider` (src/providers/DatabaseProvider.tsx:68), which
/// bumps the global `revision`; every focused `useInventoryQuery` then reads again and the
/// screens behind catch up when they are focused (09 §4.1, §5). Called after every write
/// (e.g. src/hooks/useMove.ts:93,108), on connection recovery and resume, after a restore,
/// after pairing and after leaving the household.
///
/// `DatabaseModel` conforms; models that write take `any InventoryInvalidating` so they can be
/// tested with a counter instead.
@MainActor
public protocol InventoryInvalidating: AnyObject {
    /// Bumps the global revision (RN `revision + 1`).
    func invalidate()
}
