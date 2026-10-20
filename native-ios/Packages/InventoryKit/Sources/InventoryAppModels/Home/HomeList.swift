import InventoryCore
import InventoryStrings

/// What Home's one list shows, worked out without the view (RN src/ui/home/homeList.ts;
/// 06 §5.5, §5.7). The view renders each entry; the order, the sections and which rows share
/// an inset-grouped section are decided here.
public enum HomeList {
    /// How many recent items Home asks for first (RN `RECENT_FIRST`).
    public static let recentFirst = 12
    /// How many after "Show more" (RN `RECENT_MORE`).
    public static let recentMore = 40

    /// Where a row sits in its section (RN `SheetPosition`, `sheetCell(index, count)`).
    public struct Position: Sendable, Hashable {
        public var index: Int
        public var count: Int

        public init(index: Int, count: Int) {
            self.index = index
            self.count = count
        }
    }

    /// "Do we still have it?" for a name kept in more than one place (RN `NameTotal`).
    public struct NameTotal: Sendable, Hashable {
        /// The name as the first matching item spells it, trimmed.
        public var name: String
        /// Added up over every item with that name.
        public var quantity: Int
        /// Different containers those items are in.
        public var places: Int

        public init(name: String, quantity: Int, places: Int) {
            self.name = name
            self.quantity = quantity
            self.places = places
        }
    }

    /// What stands in for a list that cannot be shown (RN `HomeStatus`).
    public enum Status: String, Sendable, Hashable {
        /// A skeleton (list variant, 4 rows).
        case loading
        /// The error state, or `L10n.Home.waitingForServer` when the connection explains it.
        case error
        /// The empty household.
        case empty
        /// A skeleton (rows variant, 5 rows) once the search has taken a moment.
        case searching
        /// The search error state.
        case searchFailed
        /// "Nothing called …".
        case noResults
    }

    /// One row of Home's list (RN `HomeEntry`). ``key`` is unique within a list.
    public enum Entry: Sendable, Hashable, Identifiable {
        /// The search field: always first, and the list's one sticky row.
        case field
        /// "This phone keeps its own inventory."
        case notice
        /// `L10n.Errors.refreshFailed` with Try again.
        case refreshFailed
        /// The drop-zone card.
        case dropZone
        /// "4 items and 2 places found" (not a live region).
        case summary(text: String)
        /// A section title with its count; `first` when nothing comes before it.
        case title(key: String, title: String, count: Int, first: Bool)
        /// The totals line at the top of the matched items.
        case totals([NameTotal])
        case item(key: String, item: ItemWithContext, position: Position)
        case place(key: String, hit: LocationSearchResult, position: Position)
        /// "Show more".
        case more
        case status(Status)

        /// The entry's kind, for tests and for views that switch on it.
        public enum Kind: String, Sendable, Hashable {
            case field, notice, refreshFailed, dropZone, summary, title, totals, item, place, more, status
        }

        public var kind: Kind {
            switch self {
            case .field: .field
            case .notice: .notice
            case .refreshFailed: .refreshFailed
            case .dropZone: .dropZone
            case .summary: .summary
            case .title: .title
            case .totals: .totals
            case .item: .item
            case .place: .place
            case .more: .more
            case .status: .status
            }
        }

        /// RN's list key.
        public var key: String {
            switch self {
            case .field: "field"
            case .notice: "notice"
            case .refreshFailed: "refresh-failed"
            case .dropZone: "drop-zone"
            case .summary: "summary"
            case .title(let key, _, _, _): key
            case .totals: "totals"
            case .item(let key, _, _): key
            case .place(let key, _, _): key
            case .more: "recent-more"
            case .status: "status"
            }
        }

        public var id: String { key }
    }

    /// The household at a glance (RN `householdCounts`' result).
    public struct HouseholdCounts: Sendable, Hashable {
        public var spaces: Int
        public var containers: Int
        public var items: Int

        public init(spaces: Int, containers: Int, items: Int) {
            self.spaces = spaces
            self.containers = containers
            self.items = items
        }

        /// "5 spaces, 13 containers and 45 items." (`L10n.Home.summary`).
        public var summary: String {
            L10n.Home.summary(spaces: spaces, containers: containers, items: items)
        }
    }

    /// Home with nothing typed, below the notice and the card (RN `IdleBody`).
    public enum IdleBody: Sendable, Hashable {
        /// Recently added, newest first, and whether "Show more" is offered.
        case list(recent: [ItemWithContext], canShowMore: Bool)
        /// A status in place of the list: `.loading`, `.error` or `.empty`.
        case status(Status)
    }

    /// The inputs of ``idleEntries(_:)`` (RN `IdleInput`).
    public struct IdleInput: Sendable, Hashable {
        /// The "This phone keeps its own inventory" notice.
        public var notice: Bool
        /// A refresh failed for a reason the connection banner does not explain.
        public var refreshFailed: Bool
        public var dropZoneCount: Int
        public var body: IdleBody

        public init(notice: Bool, refreshFailed: Bool, dropZoneCount: Int, body: IdleBody) {
            self.notice = notice
            self.refreshFailed = refreshFailed
            self.dropZoneCount = dropZoneCount
            self.body = body
        }
    }

    /// The fields ``nameTotals(_:)`` reads from an item.
    public struct NameTotalInput: Sendable, Hashable {
        public var name: String
        public var quantity: Int
        public var containerId: String

        public init(name: String, quantity: Int, containerId: String) {
            self.name = name
            self.quantity = quantity
            self.containerId = containerId
        }
    }

    /// "5 spaces, 13 containers and 45 items.": space counts leave out the drop zone (a system
    /// space), so its items are added on top; its container is not counted, as on the desk.
    public static func householdCounts(
        _ spaces: [(containerCount: Int, itemCount: Int)],
        dropZoneCount: Int
    ) -> HouseholdCounts {
        var containers = 0
        var items = dropZoneCount
        for space in spaces {
            containers = saturatingSum(containers, space.containerCount)
            items = saturatingSum(items, space.itemCount)
        }
        return HouseholdCounts(spaces: spaces.count, containers: containers, items: items)
    }

    /// ``householdCounts(_:dropZoneCount:)`` over `spaces.listWithCounts()`.
    public static func householdCounts(spaces: [SpaceWithCounts], dropZoneCount: Int) -> HouseholdCounts {
        householdCounts(spaces.map { ($0.containerCount, $0.itemCount) }, dropZoneCount: dropZoneCount)
    }

    /// One total per name kept in two or more containers: the answer to "do we still have AA
    /// batteries?" when they sit in two boxes. Names match trimmed and case-insensitively
    /// (JS `trim().toLowerCase()`, compared as JS compares strings); unnamed items are never
    /// totalled; two items of one name in one container need a second container. Totals come
    /// in the order their names first appear.
    public static func nameTotals(_ items: [NameTotalInput]) -> [NameTotal] {
        var groups: [(name: String, quantity: Int, containers: [[UInt16]])] = []
        var indexByKey: [[UInt16]: Int] = [:]
        for item in items {
            let name = item.name.jsTrimmed()
            if name.isEmpty { continue }
            let key = Array(name.jsLowercased().utf16)
            let container = Array(item.containerId.utf16)
            if let index = indexByKey[key] {
                groups[index].quantity = saturatingSum(groups[index].quantity, item.quantity)
                if !groups[index].containers.contains(container) { groups[index].containers.append(container) }
            } else {
                indexByKey[key] = groups.count
                groups.append((name, item.quantity, [container]))
            }
        }
        return groups
            .filter { $0.containers.count > 1 }
            .map { NameTotal(name: $0.name, quantity: $0.quantity, places: $0.containers.count) }
    }

    /// ``nameTotals(_:)`` over search hits.
    public static func nameTotals(_ items: [ItemSearchResult]) -> [NameTotal] {
        nameTotals(items.map { NameTotalInput(name: $0.name, quantity: $0.quantity, containerId: $0.containerId) })
    }

    /// Home with nothing typed: the stale-data banner, the unpaired notice, the drop-zone card,
    /// then Recently added (drop-zone items included, so "somewhere" adds show up).
    public static func idleEntries(_ input: IdleInput) -> [Entry] {
        var entries: [Entry] = []
        if input.refreshFailed { entries.append(.refreshFailed) }
        if input.notice { entries.append(.notice) }
        if input.dropZoneCount > 0 { entries.append(.dropZone) }

        switch input.body {
        case .status(let status):
            entries.append(.status(status))
            return entries
        case .list(let recent, let canShowMore):
            // No items at all is the empty state's job; an empty section says nothing.
            if recent.isEmpty { return entries }
            entries.append(.title(key: "title-recent", title: L10n.Home.recent, count: recent.count, first: entries.isEmpty))
            entries += itemEntries(recent, keyPrefix: "recent")
            if canShowMore { entries.append(.more) }
            return entries
        }
    }

    /// Item hits split into the item's own matches and those matched by where they are, each in
    /// the order the search returned them.
    public static func splitMatches(_ items: [ItemSearchResult]) -> (direct: [ItemSearchResult], location: [ItemSearchResult]) {
        (items.filter { $0.matchKind == .direct }, items.filter { $0.matchKind == .location })
    }

    /// Search results in the desk's order, because the item is the answer: the items that
    /// matched, then the spaces and containers that matched, then the items kept in those
    /// places. Nothing found is a status, never an empty list. A corrected query (native only)
    /// says what was searched instead above the results, whatever the number of sections.
    public static func resultEntries(_ results: SearchResults, refreshFailed: Bool, correction: SearchModel.Correction? = nil) -> [Entry] {
        let (direct, location) = splitMatches(results.items)
        let places = results.locations

        if direct.isEmpty && location.isEmpty && places.isEmpty {
            return [.status(.noResults)]
        }

        var entries: [Entry] = []
        if refreshFailed { entries.append(.refreshFailed) }
        // With one section, its title already says how many, so the summary would only repeat
        // it; the search key still announces it.
        let sections = [direct.isEmpty, places.isEmpty, location.isEmpty].filter { !$0 }.count
        if let correction {
            entries.append(.summary(text: L10n.Search.Corrected.showing(typed: correction.typed, shown: correction.shown)))
        } else if sections > 1 {
            entries.append(.summary(text: L10n.Search.summary(items: results.items.count, places: places.count)))
        }

        var first = true
        if !direct.isEmpty {
            entries.append(.title(key: "title-items", title: L10n.Search.items, count: direct.count, first: first))
            first = false
            let totals = nameTotals(direct)
            if !totals.isEmpty { entries.append(.totals(totals)) }
            entries += itemEntries(direct.map(\.item), keyPrefix: "item")
        }
        if !places.isEmpty {
            entries.append(.title(key: "title-places", title: L10n.Search.places, count: places.count, first: first))
            first = false
            entries += places.enumerated().map { index, hit -> Entry in
                .place(key: "place-\(hit.kind.rawValue)-\(hit.id)", hit: hit, position: Position(index: index, count: places.count))
            }
        }
        if !location.isEmpty {
            entries.append(.title(key: "title-kept", title: L10n.Search.keptInThose, count: location.count, first: first))
            entries += itemEntries(location.map(\.item), keyPrefix: "kept")
        }
        return entries
    }

    /// `a + b`, held at the ends of `Int` rather than trapping (JS numbers never overflow).
    private static func saturatingSum(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? (b > 0 ? Int.max : Int.min) : sum
    }

    private static func itemEntries(_ items: [ItemWithContext], keyPrefix: String) -> [Entry] {
        items.enumerated().map { index, item -> Entry in
            .item(key: "\(keyPrefix)-\(item.id)", item: item, position: Position(index: index, count: items.count))
        }
    }
}
