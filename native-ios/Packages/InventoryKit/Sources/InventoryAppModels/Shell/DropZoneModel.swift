import InventoryCore
import Observation

/// The one read of the drop zone shared by the tab badge, Home's card and the Drop zone list
/// (RN `DropZoneProvider`, src/providers/DropZoneProvider.tsx; 06 §7.1, 09 §4.8).
///
/// One `items.listUnsorted()` read under the key `drop-zone`, newest first, instead of a count
/// query per screen: when paired, counting downloaded the whole list anyway. It lives with the
/// tab shell, so its "focused" means the tab shell is in front (whichever tab is selected):
/// the shell reports that through ``focusChanged(_:revision:)``, writes reach it through
/// ``revisionChanged(_:)``, and it re-reads like any screen's query.
@MainActor
@Observable
public final class DropZoneModel {
    /// RN's query key.
    public nonisolated static let queryKey = "drop-zone"

    /// The underlying read, for anything the derived values below do not cover.
    public let query: InventoryQuery<[ItemWithContext]>

    /// - Parameters:
    ///   - revision: the global revision now.
    ///   - read: `repositories.items.listUnsorted()`, local or household.
    public init(revision: Int = 0, read: @escaping @Sendable () async throws -> [ItemWithContext]) {
        query = InventoryQuery(key: Self.queryKey, revision: revision, read: read)
    }

    /// Reads through `repositories.items.listUnsorted()`.
    public convenience init<Repositories: InventoryRepositories>(repositories: Repositories, revision: Int = 0) {
        self.init(revision: revision, read: Self.read(from: repositories))
    }

    /// The read for a set of repositories.
    public nonisolated static func read<Repositories: InventoryRepositories>(
        from repositories: Repositories
    ) -> @Sendable () async throws -> [ItemWithContext] {
        { try await repositories.items.listUnsorted() }
    }

    // MARK: Outputs (RN DropZoneContextValue)

    /// Waiting items, newest first; empty until the first read finishes.
    public var items: [ItemWithContext] { query.data ?? [] }

    /// How many items are waiting (0 until the first read finishes).
    public var count: Int { query.data?.count ?? 0 }

    /// No answer yet: badges and cards stay hidden rather than showing 0.
    public var loading: Bool { query.isLoading && query.data == nil }

    /// Why the newest read failed, once it has.
    public var cause: (any Error)? { query.cause }

    /// A refresh failed while earlier items are still shown (the Drop zone's banner).
    public var refreshFailed: Bool { query.refreshFailed }

    /// A read is in flight, first or not (the Drop zone's pull-to-refresh spinner).
    public var reading: Bool { query.isLoading }

    // MARK: Inputs

    /// The tab shell came into view or went behind a pushed screen or sheet.
    public func focusChanged(_ focused: Bool, revision: Int? = nil) {
        query.focusChanged(focused, revision: revision)
    }

    /// The global revision changed.
    public func revisionChanged(_ revision: Int) {
        query.revisionChanged(revision)
    }

    /// Reads again.
    public func reload() {
        query.reload()
    }

    /// Reads again and returns once the read has settled.
    public func refresh() async {
        await query.refresh()
    }

    /// The repositories changed (joined or left the household). Does not read by itself: the
    /// caller invalidates, as RN's callers did.
    public func setRead(_ read: @escaping @Sendable () async throws -> [ItemWithContext]) {
        query.setRead(read)
    }
}
