import InventoryCore

/// What the review screen can honestly say about a Quick Snap session (RN `FastSessionSummary`).
///
/// `pending` is derived from the shutter count the camera reported, not from pipeline state: the
/// pipeline keeps running after the camera goes away, so rows the review has not seen yet are
/// exactly `expected - saved`.
// RN: src/services/capture/fastReview.ts:3-16
public struct FastSessionSummary: Sendable, Hashable {
    /// Rows of the set on screen.
    public var saved: Int
    /// Rows whose name is not blank (JS trim).
    public var named: Int
    /// `saved - named`.
    public var unnamed: Int
    /// Photos the camera reported that have not landed yet; never negative.
    public var pending: Int

    public init(saved: Int, named: Int, unnamed: Int, pending: Int) {
        self.saved = saved
        self.named = named
        self.unnamed = unnamed
        self.pending = pending
    }
}

/// The session filter and summary behind the Quick Snap review (05 §6.1-6.2).
// RN: src/services/capture/fastReview.ts
public enum FastReview {
    /// The items of one Quick Snap session, in the order they were shot (RN `sessionItems`).
    ///
    /// Keeps `createdAt >= since` and sorts oldest first. `listByContainer` returns newest first,
    /// and JS `sort` is stable, so rows created in the same millisecond keep that input order;
    /// the sort here breaks ties by input position to give the same result.
    // RN: src/services/capture/fastReview.ts:22-24
    public static func sessionItems(_ items: [ItemWithContext], since: Int64) -> [ItemWithContext] {
        items.enumerated()
            .filter { $0.element.createdAt >= since }
            .sorted { lhs, rhs in
                lhs.element.createdAt != rhs.element.createdAt
                    ? lhs.element.createdAt < rhs.element.createdAt
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Splits the set into named and unnamed rows and says how many are still on their way
    /// (RN `summarizeSession`). A whitespace-only name counts as unnamed. `pending` is clamped at
    /// zero: a shot that failed to write after the camera reported it would otherwise push it
    /// negative once later rows land.
    // RN: src/services/capture/fastReview.ts:26-37
    public static func summarize(_ items: [ItemWithContext], expected: Int) -> FastSessionSummary {
        let saved = items.count
        let named = items.filter { !$0.name.jsTrimmed().isEmpty }.count
        return FastSessionSummary(saved: saved, named: named, unnamed: saved - named, pending: max(0, expected - saved))
    }
}
