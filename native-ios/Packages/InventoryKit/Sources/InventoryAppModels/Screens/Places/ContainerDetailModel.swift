import InventoryCore
import InventoryStrings
import Observation

/// "What's in this box?": the answer when a label is scanned, and where things are counted and
/// added (RN app/container/[id]/index.tsx; 07 §3.7).
///
/// Its space is a link above the contents, its code is the big tape from the box, and what is in
/// it reads by name with a stepper on every row. Nothing shows until both the container and its
/// contents have been read, so it never flashes "empty" on the way, and a failed read of the
/// contents is said as such rather than as an empty box. Three reads: the container with its
/// counts, its items, and its space, whose key follows the container (`space:none` until the
/// container is known, as RN's did).
@MainActor
@Observable
public final class ContainerDetailModel {
    /// What the screen shows instead of the container while it cannot show it.
    public enum Blocking: Sendable {
        case failed(any Error)
        /// The container, or its items, are still being read.
        case loading
        /// Read fine, but nothing there: deleted, probably on another phone.
        case gone
    }

    /// What goes under the head once the container is shown.
    public enum Contents: Sendable {
        case rows([ItemWithContext])
        /// Nothing in it: the empty state with Add here and Take a photo.
        case empty
        /// The items could not be read (never "empty").
        case failed(any Error)
    }

    /// The space the crumb leads to.
    public struct Crumb: Sendable, Hashable {
        public let id: String
        public let name: String
        public let color: String
    }

    public let id: String
    /// `containers.getWithCounts(id)` (key `container:<id>`).
    public let container: InventoryQuery<ContainerWithCounts?>
    /// `items.listByContainer(id)` (key `items-of:<id>`), newest first.
    public let items: InventoryQuery<[ItemWithContext]>
    /// `spaces.getById(container.spaceId)` (key `space:<spaceId>`, `space:none` before).
    public let space: InventoryQuery<Space?>
    /// The rows' write-through quantity models (one per item id, pruned after every read).
    public let quantities: ItemRowQuantityModels

    @ObservationIgnored private let spacesRepository: any SpacesRepository
    @ObservationIgnored private let rememberCategories: @MainActor ([String?]) -> Void
    @ObservationIgnored private let now: @Sendable () -> Int64
    /// The rows whose arrival highlight was decided, once each.
    @ObservationIgnored private var arrivalsDecided: Set<String> = []

    /// - Parameters:
    ///   - quantities: `app.makeRowQuantityModels()`.
    ///   - rememberCategories: feeds the categories seen to the Add and Edit forms' suggestions.
    ///   - now: epoch milliseconds, for the arrival highlight.
    public init(
        id: String,
        spaces: any SpacesRepository,
        containers: any ContainersRepository,
        items itemsRepository: any ItemsRepository,
        quantities: ItemRowQuantityModels,
        revision: Int = 0,
        rememberCategories: @escaping @MainActor ([String?]) -> Void = { _ in },
        now: @escaping @Sendable () -> Int64
    ) {
        self.id = id
        self.quantities = quantities
        spacesRepository = spaces
        self.rememberCategories = rememberCategories
        self.now = now
        container = InventoryQuery(key: PlacesReads.containerKey(id), revision: revision) { try await containers.getWithCounts(id) }
        items = InventoryQuery(key: PlacesReads.itemsOfKey(id), revision: revision) { try await itemsRepository.listByContainer(id) }
        space = InventoryQuery(key: Self.spaceKey(nil), revision: revision) { nil }
        container.onSettle = { [weak self] in self?.containerSettled() }
        items.onSettle = { [weak self] in self?.itemsSettled() }
    }

    // MARK: Outputs

    /// The container, once read.
    public var containerData: ContainerWithCounts? { container.data ?? nil }

    /// Instead of the screen: nothing renders until both reads are in.
    public var blocking: Blocking? {
        guard containerData != nil else {
            if let cause = container.cause { return .failed(cause) }
            return container.isLoading ? .loading : .gone
        }
        if items.data == nil && items.cause == nil { return .loading }
        return nil
    }

    /// The contents in the order people look for them.
    public var sorted: [ItemWithContext] {
        ContainerRules.sortContents(items.data ?? [])
    }

    /// The name, or "Unnamed box".
    public var title: String {
        containerData.map { ContainerRules.titleOf($0.container) } ?? ""
    }

    /// The way back up to the space: from its own read, or from any row, which carries it too.
    public var crumb: Crumb? {
        if let space = space.data ?? nil {
            return Crumb(id: space.id, name: space.name, color: space.color)
        }
        if let first = sorted.first {
            return Crumb(id: first.spaceId, name: first.spaceName, color: first.spaceColor)
        }
        return nil
    }

    /// Room kept for the crumb while it loads, so the head does not jump; none once the space
    /// read failed.
    public var keepsCrumbRoom: Bool { crumb == nil && space.cause == nil }

    /// "Bin", "Drawer"…
    public var typeName: String {
        containerData.map { ContainerRules.typeNameOf($0.visualType) } ?? ""
    }

    /// Under the title: the type alone when empty (the empty state says the rest), else
    /// "Bin · 3 items".
    public var subline: String {
        if let rows = items.data, rows.isEmpty { return typeName }
        let count = items.data?.count ?? containerData?.itemCount ?? 0
        return L10n.Container.sub(type: typeName, items: count)
    }

    /// The container has a QR label (RN `qrToken !== null`).
    public var isLinked: Bool { containerData?.qrToken != nil }

    /// The QR entry's label: "QR label" or "Add a QR label".
    public var qrLabel: String { isLinked ? L10n.Container.qrLinked : L10n.Container.qrNone }

    /// "QR label, linked. Opens the label." or "Add a QR label".
    public var qrAccessibilityLabel: String { isLinked ? L10n.Container.qrLinkedA11y : L10n.Container.qrNone }

    /// The tape read letter by letter: "Label code C A B, J 9 2 R".
    public var codeAccessibilityLabel: String {
        L10n.A11y.labelCodeTitle(spelled: spellCode(containerData?.shortCode ?? ""))
    }

    /// "Edit Tool chest", once the container is known.
    public var editLabel: String? { containerData.map { _ in L10n.Container.edit(label: title) } }

    /// A refresh of the container or its items failed while earlier data stays.
    public var showsRefreshBanner: Bool {
        needsRefreshBanner(container.refreshFailed, cause: container.cause)
            || needsRefreshBanner(items.refreshFailed, cause: items.cause)
    }

    public var contents: Contents {
        guard items.data != nil else {
            return .failed(items.cause ?? ContainerDetailUnread())
        }
        let sorted = sorted
        return sorted.isEmpty ? .empty : .rows(sorted)
    }

    /// The bottom bar (camera and Add here), only with contents.
    public var hasBottomBar: Bool { !sorted.isEmpty }

    /// "This bin is empty".
    public var emptyTitle: String { L10n.Container.Empty.title(type: typeName) }

    /// Whether `item`'s row is picked out as just arrived. Decided once per row, the first time
    /// it is asked (when the row first appears); later asks answer false.
    public func claimsArrival(_ item: ItemWithContext) -> Bool {
        guard !arrivalsDecided.contains(item.id) else { return false }
        arrivalsDecided.insert(item.id)
        return ContainerRules.isFreshArrival(createdAt: item.createdAt, now: now())
    }

    // MARK: Inputs

    /// Try again over a failed container: all three reads.
    public func reloadAll() {
        container.reload()
        items.reload()
        space.reload()
    }

    /// Pull to refresh: all three reads, returning once they have settled.
    public func refresh() async {
        await PlacesReads.refresh([container, items, space])
    }

    public func focusChanged(_ focused: Bool, revision: Int?) {
        container.focusChanged(focused, revision: revision)
        items.focusChanged(focused, revision: revision)
        space.focusChanged(focused, revision: revision)
    }

    public func revisionChanged(_ revision: Int) {
        container.revisionChanged(revision)
        items.revisionChanged(revision)
        space.revisionChanged(revision)
    }

    // MARK: Private

    static func spaceKey(_ spaceId: String?) -> String {
        PlacesReads.spaceKey(spaceId ?? "none")
    }

    /// The space read follows the container's space (RN's key `space:<spaceId ?? 'none'>`).
    private func containerSettled() {
        let spaceId = containerData?.spaceId
        let key = Self.spaceKey(spaceId)
        guard !EntityText.same(key, space.key) else { return }
        let spaces = spacesRepository
        space.setKey(key) {
            guard let spaceId else { return nil }
            return try await spaces.getById(spaceId)
        }
    }

    /// Categories seen feed the forms' suggestions; quantity models are kept for shown rows only.
    private func itemsSettled() {
        guard let rows = items.data else { return }
        rememberCategories(rows.map(\.category))
        quantities.keep(only: rows.map(\.id))
    }
}

/// The items were not read (the screen never shows contents in that case; a placeholder cause).
struct ContainerDetailUnread: Error {}
