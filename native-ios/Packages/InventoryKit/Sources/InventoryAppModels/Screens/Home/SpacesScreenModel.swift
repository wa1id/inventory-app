import InventoryCore
import InventoryStrings
import Observation

/// The Spaces tab: the house, room by room, and where the owner sets it up (RN
/// app/(tabs)/spaces.tsx; 06 §6).
///
/// One read, `spaces.listWithCounts()` under the key `spaces` (by name, the drop zone's system
/// space left out), followed by focus and the revision like any screen's query. The view draws
/// ``spaces`` with a "New space" row at the end, or ``placeholder`` in their place.
@MainActor
@Observable
public final class SpacesScreenModel {
    /// What stands in for the list while it has no spaces to show.
    public enum Placeholder {
        /// The first read is running: a skeleton.
        case loading
        /// The first read failed: never "no spaces yet" (RN issue #12).
        case failed(any Error)
        /// There are none yet: "Start with a space", and "Join your household instead" for a
        /// phone that has not joined (its household may already have spaces).
        case start(offersJoin: Bool)
    }

    public let query: InventoryQuery<[SpaceWithCounts]>
    @ObservationIgnored private let isPaired: @MainActor () -> Bool

    /// - Parameters:
    ///   - revision: the global revision now.
    ///   - read: `spaces.listWithCounts()`, local or household.
    ///   - isPaired: whether this phone has joined a household (the session is set).
    public init(
        revision: Int = 0,
        read: @escaping @Sendable () async throws -> [SpaceWithCounts],
        isPaired: @escaping @MainActor () -> Bool
    ) {
        query = InventoryQuery(key: "spaces", revision: revision, read: read)
        self.isPaired = isPaired
    }

    /// Reads through `repositories.spaces.listWithCounts()`.
    public convenience init<Repositories: InventoryRepositories>(
        repositories: Repositories,
        revision: Int = 0,
        isPaired: @escaping @MainActor () -> Bool
    ) {
        self.init(revision: revision, read: { try await repositories.spaces.listWithCounts() }, isPaired: isPaired)
    }

    // MARK: Outputs

    /// The spaces on screen, by name; empty until the first read answers.
    public var spaces: [SpaceWithCounts] { query.data ?? [] }

    /// "3 spaces" under the title, only when there are some: no "0 spaces" over the empty
    /// state, which says as much.
    public var subtitle: String? {
        guard let data = query.data, !data.isEmpty else { return nil }
        return L10n.Spaces.count(spaces: data.count)
    }

    /// "Could not be refreshed" over the old list, unless the connection banner or the
    /// removed-phone layer already explains it (RN `needsRefreshBanner`).
    public var showsRefreshBanner: Bool {
        needsRefreshBanner(query.refreshFailed, cause: query.cause)
    }

    /// "New space" closes the list, only under at least one space (the empty state offers it).
    public var showsNewSpaceRow: Bool { !spaces.isEmpty }

    /// The state in place of the list, or nil when there are spaces to show.
    public var placeholder: Placeholder? {
        guard let data = query.data else {
            if let cause = query.cause { return .failed(cause) }
            return .loading
        }
        guard data.isEmpty else { return nil }
        return .start(offersJoin: !isPaired())
    }

    // MARK: Inputs

    /// Try again, on the banner or the error state.
    public func retry() {
        query.reload()
    }

    /// Pull to refresh: returns once the read has answered.
    public func refresh() async {
        await query.refresh()
    }
}
