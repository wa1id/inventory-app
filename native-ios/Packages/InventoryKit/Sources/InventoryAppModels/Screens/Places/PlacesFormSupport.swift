import InventoryCore
import InventoryStrings

// What the space and container forms share (RN app/space/new.tsx, app/space/[id]/edit.tsx,
// app/container/new.tsx, app/container/[id]/edit.tsx; 07 §3.6, §3.8, §3.11, §3.13).

/// A save that did not happen (RN `failure: { cause }`): what it threw, or nil when the record
/// turned out to be gone (the repository answered nil, a household's 404), which is never shown
/// as a success.
public struct PlacesSaveFailure: Sendable {
    /// What the save threw; nil when the record is gone.
    public let cause: (any Error)?

    public init(cause: (any Error)?) {
        self.cause = cause
    }

    /// The record was deleted elsewhere: Save and Delete stay off, and the notice offers the
    /// way out (RN `gone = failure !== null && failure.cause === null`).
    public var isGone: Bool { cause == nil }

    /// The banner's words (RN `SaveNotice`).
    public func notice(subject: ErrorSubject) -> SaveNoticeCopy {
        SaveNoticeCopy(cause: cause, subject: subject)
    }
}

/// What an edit form is busy with (RN `busy: 'save' | 'delete' | null`).
public enum PlacesFormBusy: Sendable, Hashable {
    case save
    case delete
}

/// The reads the space and container screens make, with RN's query keys (07 §3.6-§3.13).
enum PlacesReads {
    static func spaceKey(_ id: String) -> String { "space:\(id)" }
    static func containerKey(_ id: String) -> String { "container:\(id)" }
    static let spacesKey = "spaces"
    static func containersOfKey(_ spaceId: String) -> String { "containers-of:\(spaceId)" }
    static func itemsOfKey(_ containerId: String) -> String { "items-of:\(containerId)" }

    static func space(_ spaces: any SpacesRepository, id: String) -> @Sendable () async throws -> Space? {
        { try await spaces.getById(id) }
    }

    static func spacesWithCounts(_ spaces: any SpacesRepository) -> @Sendable () async throws -> [SpaceWithCounts] {
        { try await spaces.listWithCounts() }
    }

    /// Reads every query again and returns once all of them have settled (pull to refresh over
    /// a screen's reads; the spinner shows only for the pull, as RN's `usePullToRefresh`).
    @MainActor
    static func refresh(_ queries: [any PlacesRefreshing]) async {
        for query in queries { query.startReload() }
        for query in queries { await query.settled() }
    }
}

/// A query a screen can reload and wait for, whatever its value type.
@MainActor
protocol PlacesRefreshing: AnyObject {
    func startReload()
    func settled() async
}

extension InventoryQuery: PlacesRefreshing {
    func startReload() { reload() }
    func settled() async { await readTask?.value }
}
