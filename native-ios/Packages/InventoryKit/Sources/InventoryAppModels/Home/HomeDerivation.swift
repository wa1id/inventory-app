import InventoryCore

/// The decisions Home's screen makes from its reads, as pure functions (RN app/(tabs)/index.tsx
/// :69-78, :324-406; 06 §5.2, §5.5, §5.7). ``HomeModel`` applies them; tests check them alone.
public enum HomeDerivation {
    /// A failure the screen does not need to explain itself: the removed-phone layer covers a
    /// revoked phone, and the connection banner covers an unreachable home server, but only
    /// while the connection state says so (a blip that recovered leaves no banner, so the
    /// screen offers its own Try again).
    ///
    /// - Parameters:
    ///   - cause: a read's failure.
    ///   - connectionIsOnline: the connection state is exactly `online` (false when local).
    public static func explainedElsewhere(_ cause: any Error, connectionIsOnline: Bool) -> Bool {
        let kind = describeError(cause).kind
        return kind == .revoked || (kind == .offline && !connectionIsOnline)
    }

    /// What stands below the notice and the card with nothing typed (RN `idleBody`).
    ///
    /// - Parameters:
    ///   - recentRows: the recent rows on screen (see `HomeModel.recentRows`), nil before any.
    ///   - recentFailed: the recent read has a cause.
    ///   - dropZoneCount: items waiting in the drop zone.
    ///   - paired: joined to a household.
    ///   - spacesLoaded: the spaces read has data.
    ///   - spacesFailed: the spaces read has a cause.
    ///   - recentLimit: how many recent items were asked for.
    public static func idleBody(
        recentRows: [ItemWithContext]?,
        recentFailed: Bool,
        dropZoneCount: Int,
        paired: Bool,
        spacesLoaded: Bool,
        spacesFailed: Bool,
        recentLimit: Int
    ) -> HomeList.IdleBody {
        guard let recentRows else {
            return .status(recentFailed ? .error : .loading)
        }
        if recentRows.isEmpty && dropZoneCount == 0 {
            // Not joined: whether there are spaces decides the next step.
            if !paired && !spacesLoaded {
                return .status(spacesFailed ? .error : .loading)
            }
            return .status(.empty)
        }
        return .list(
            recent: recentRows,
            canShowMore: recentLimit == HomeList.recentFirst && recentRows.count == HomeList.recentFirst
        )
    }

    /// The empty household offers to join or to start with a space, rather than to add an item:
    /// not joined, nothing stored and no space yet.
    public static func startHere(_ body: HomeList.IdleBody, paired: Bool, spaces: [SpaceWithCounts]?) -> Bool {
        body == .status(.empty) && !paired && (spaces?.isEmpty ?? true)
    }

    /// The stale-data banner above the idle list: anything on screen that its last read could
    /// not refresh, for a reason the connection banner and the removed-phone layer do not
    /// already explain. Home passes the spaces (shown when it has data), the recent rows (shown
    /// when there are any) and the drop zone (shown when it has items).
    public static func idleRefreshFailed(
        _ reads: [(cause: (any Error)?, shown: Bool)],
        connectionIsOnline: Bool
    ) -> Bool {
        reads.contains { read in
            guard let cause = read.cause, read.shown else { return false }
            return !explainedElsewhere(cause, connectionIsOnline: connectionIsOnline)
        }
    }

    /// Older results stay on screen while a new query runs (dimmed, out of reach), when there
    /// are any to keep.
    public static func showingOlder(pending: Bool, results: SearchResults?) -> Bool {
        guard pending, let results else { return false }
        return results.items.count + results.locations.count > 0
    }

    /// What starts the 200 ms search-skeleton wait when there are no older results to keep: it
    /// counts from when the search starts (after the debounce), so a quick search never
    /// flashes one.
    public static func searchStartedActive(searching: Bool, showingOlder: Bool, pending: Bool, hasResults: Bool) -> Bool {
        searching && !showingOlder && (pending || !hasResults)
    }

    /// The list below the field while something is typed (RN `searchBody`).
    ///
    /// - Parameters:
    ///   - pending, results, correction, cause: the search model's.
    ///   - dim: older results are still shown (`showingOlder` and not yet past 600 ms).
    ///   - mountSkeleton: past 420 ms, the skeleton goes in above the older results, ready to
    ///     take over at 600 ms with no gap (it has its own 180 ms appear delay).
    ///   - connectionIsOnline: the connection state is exactly `online`.
    public static func searchBody(
        pending: Bool,
        results: SearchResults?,
        correction: SearchModel.Correction? = nil,
        cause: (any Error)?,
        dim: Bool,
        mountSkeleton: Bool,
        connectionIsOnline: Bool
    ) -> [HomeList.Entry] {
        if pending {
            if dim, let results {
                let older = HomeList.resultEntries(results, refreshFailed: false, correction: correction)
                return mountSkeleton ? [.status(.searching)] + older : older
            }
            return [.status(.searching)]
        }
        guard let results else {
            return [.status(cause != nil ? .searchFailed : .searching)]
        }
        let refreshFailed = cause.map { !explainedElsewhere($0, connectionIsOnline: connectionIsOnline) } ?? false
        return HomeList.resultEntries(results, refreshFailed: refreshFailed, correction: correction)
    }

    /// The household summary's counts, or nil while they would be wrong: no spaces yet, the
    /// drop zone still loading, or the drop zone failed before it ever answered.
    public static func householdCounts(
        spaces: [SpaceWithCounts]?,
        dropZoneLoading: Bool,
        dropZoneFailed: Bool,
        dropZoneCount: Int
    ) -> HomeList.HouseholdCounts? {
        guard let spaces, !dropZoneLoading, !(dropZoneFailed && dropZoneCount == 0) else { return nil }
        return HomeList.householdCounts(spaces: spaces, dropZoneCount: dropZoneCount)
    }
}
