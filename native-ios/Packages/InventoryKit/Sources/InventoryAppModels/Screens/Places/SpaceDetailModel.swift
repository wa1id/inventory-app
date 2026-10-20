import InventoryCore
import InventoryStrings
import Observation

/// One space and its containers, sorted by label (RN app/space/[id]/index.tsx; 07 §3.12).
///
/// There are no peeks at each container's contents: that would be one list call per row over
/// the network. A failed read of the containers is never shown as "no containers yet". Drive it
/// with ``focusChanged(_:revision:)`` and ``revisionChanged(_:)`` (the screen's focus and the
/// database revision), like any query.
@MainActor
@Observable
public final class SpaceDetailModel {
    /// What the screen shows instead of the space while there is none.
    public enum Blocking: Sendable {
        case failed(any Error)
        case loading
        /// Read fine, but nothing there: deleted, probably on another phone.
        case gone
    }

    /// What goes under the head.
    public enum Contents: Sendable {
        case rows([ContainerWithCounts])
        /// No containers yet: the empty state offering the first one.
        case empty
        /// The containers could not be read (never "empty").
        case failed(any Error)
        case loading
    }

    public let id: String
    /// `spaces.getById(id)` (key `space:<id>`).
    public let space: InventoryQuery<Space?>
    /// `containers.listBySpace(id)` (key `containers-of:<id>`), newest first.
    public let containers: InventoryQuery<[ContainerWithCounts]>

    public init(id: String, spaces: any SpacesRepository, containers containersRepository: any ContainersRepository, revision: Int = 0) {
        self.id = id
        space = InventoryQuery(key: PlacesReads.spaceKey(id), revision: revision, read: PlacesReads.space(spaces, id: id))
        containers = InventoryQuery(key: PlacesReads.containersOfKey(id), revision: revision) {
            try await containersRepository.listBySpace(id)
        }
    }

    // MARK: Outputs

    /// The space, once read.
    public var spaceData: Space? { space.data ?? nil }

    /// Instead of the screen: the space read failed, is loading, or found nothing.
    public var blocking: Blocking? {
        guard spaceData == nil else { return nil }
        if let cause = space.cause { return .failed(cause) }
        return space.isLoading ? .loading : .gone
    }

    /// The containers by label, repository order kept on ties (a room is scanned by name).
    public var sorted: [ContainerWithCounts] {
        SpaceSetup.sortedByLabel(containers.data ?? [])
    }

    /// Everything in the space's containers.
    public var itemTotal: Int {
        (containers.data ?? []).reduce(0) { $0 + $1.itemCount }
    }

    /// "2 containers and 5 items" under the name; nil over "No containers in Shed yet".
    public var meta: String? {
        let sorted = sorted
        return sorted.isEmpty ? nil : L10n.Entities.spaceCounts(containers: sorted.count, items: itemTotal)
    }

    public var contents: Contents {
        guard containers.data != nil else {
            if let cause = containers.cause { return .failed(cause) }
            return .loading
        }
        let sorted = sorted
        return sorted.isEmpty ? .empty : .rows(sorted)
    }

    /// A refresh failed while the earlier rows stay (not for offline or revoked, which have
    /// their own banner and layer).
    public var showsRefreshBanner: Bool {
        needsRefreshBanner(space.refreshFailed, cause: space.cause)
            || needsRefreshBanner(containers.refreshFailed, cause: containers.cause)
    }

    /// The bottom bar's New container, only with containers (the empty state offers it otherwise).
    public var hasBottomBar: Bool { !sorted.isEmpty }

    /// "Edit Garage", once the space is known.
    public var editLabel: String? { spaceData.map { L10n.Spaces.edit(name: $0.name) } }

    /// "No containers in Garage yet".
    public var emptyTitle: String { L10n.Spaces.NoContainers.title(name: spaceData?.name ?? "") }

    // MARK: Inputs

    /// Try again over a failed space, and the refresh banner's Try again.
    public func reloadAll() {
        space.reload()
        containers.reload()
    }

    /// Pull to refresh: both reads, returning once both have settled.
    public func refresh() async {
        await PlacesReads.refresh([space, containers])
    }

    public func focusChanged(_ focused: Bool, revision: Int?) {
        space.focusChanged(focused, revision: revision)
        containers.focusChanged(focused, revision: revision)
    }

    public func revisionChanged(_ revision: Int) {
        space.revisionChanged(revision)
        containers.revisionChanged(revision)
    }
}
