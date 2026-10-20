import InventoryCore
import InventoryStrings

/// Home's one list (``HomeList/Entry``) grouped into the sections of a native inset-grouped
/// `List` (06 §5.11 "Native layout"): RN drew each run of rows in a bordered sheet under its
/// section title (`sheetCell`, src/ui/components/Sheet.tsx), which is exactly an inset-grouped
/// section with a header.
///
/// - The search field is the navigation bar's `.searchable` field, so ``HomeList/Entry/field``
///   adds no section.
/// - The stale-data banner, the unpaired notice and the drop-zone card are a section each, as
///   is a status (loading, an error, an empty household, no results).
/// - A section title starts a titled section; the item and place rows after it belong to it
///   until the next title.
/// - What RN drew outside the bordered sheet goes around the section, where RN had it: the
///   results summary ("4 items and 2 places found") and the totals line ("“AA batteries”: ×14
///   in 2 places") in its header, above and below the title; "Show more" in its footer.
public enum HomeSections {
    /// One section of the list.
    public struct Section: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable {
            /// `L10n.Errors.refreshFailed` with Try again.
            case refreshFailed
            /// "This phone keeps its own inventory."
            case notice
            /// The drop-zone card.
            case dropZone
            /// A status in place of a list.
            case status(HomeList.Status)
            /// Rows under an optional title.
            case rows
        }

        /// Unique within the list: the key of the entry that started it.
        public var id: String
        public var kind: Kind
        /// The results summary to show above the title (not a live region).
        public var summary: String?
        /// The section title ("Recently added", "Items", …), when it has one.
        public var title: String?
        /// The count beside the title.
        public var count: Int?
        /// Names kept in two or more places, under the title (the matched items only).
        public var totals: [HomeList.NameTotal]
        public var rows: [Row]
        /// "Show more" under the rows (Recently added's first page).
        public var showsMore: Bool

        public init(
            id: String,
            kind: Kind,
            summary: String? = nil,
            title: String? = nil,
            count: Int? = nil,
            totals: [HomeList.NameTotal] = [],
            rows: [Row] = [],
            showsMore: Bool = false
        ) {
            self.id = id
            self.kind = kind
            self.summary = summary
            self.title = title
            self.count = count
            self.totals = totals
            self.rows = rows
            self.showsMore = showsMore
        }
    }

    /// One row of a titled section.
    public enum Row: Sendable, Hashable, Identifiable {
        /// An item row; `key` is RN's list key (`recent-<id>`, `item-<id>`, `kept-<id>`).
        case item(key: String, item: ItemWithContext)
        /// A space or container that matched (`place-<kind>-<id>`).
        case place(key: String, hit: LocationSearchResult)

        /// RN's list key, unique within the list.
        public var id: String {
            switch self {
            case .item(let key, _): key
            case .place(let key, _): key
            }
        }
    }

    /// Groups `entries` into sections, keeping their order.
    public static func sections(_ entries: [HomeList.Entry]) -> [Section] {
        var sections: [Section] = []
        var summary: String?
        // The titled section being filled, if the last section is one.
        var openRows = false

        /// The titled section being filled, opening an untitled one for rows before any title
        /// (never produced by HomeList).
        func openSection(key: String) {
            guard !openRows else { return }
            sections.append(Section(id: key, kind: .rows, summary: summary))
            summary = nil
            openRows = true
        }

        for entry in entries {
            switch entry {
            case .field:
                continue
            case .refreshFailed:
                sections.append(Section(id: entry.key, kind: .refreshFailed))
                openRows = false
            case .notice:
                sections.append(Section(id: entry.key, kind: .notice))
                openRows = false
            case .dropZone:
                sections.append(Section(id: entry.key, kind: .dropZone))
                openRows = false
            case .status(let status):
                sections.append(Section(id: entry.key, kind: .status(status)))
                openRows = false
            case .summary(let text):
                summary = text
                openRows = false
            case .title(let key, let title, let count, _):
                sections.append(Section(id: key, kind: .rows, summary: summary, title: title, count: count))
                summary = nil
                openRows = true
            case .totals(let totals):
                openSection(key: entry.key)
                sections[sections.count - 1].totals += totals
            case .item(let key, let item, _):
                openSection(key: key)
                sections[sections.count - 1].rows.append(.item(key: key, item: item))
            case .place(let key, let hit, _):
                openSection(key: key)
                sections[sections.count - 1].rows.append(.place(key: key, hit: hit))
            case .more:
                openSection(key: entry.key)
                sections[sections.count - 1].showsMore = true
            }
        }
        return sections
    }

    /// The item ids the list shows, for `ItemRowQuantityModels.keep(only:)`.
    public static func itemIds(_ sections: [Section]) -> [String] {
        sections.flatMap { section in
            section.rows.compactMap { row -> String? in
                guard case .item(_, let item) = row else { return nil }
                return item.id
            }
        }
    }
}

/// One total of the totals line, in the parts the view draws: "“AA batteries”:" then the count
/// set apart ("×14", or "none left" in the signal colour), then "in 2 places" (RN TotalLine.tsx).
/// Plain text, not a control; VoiceOver reads it as one sentence.
public struct HomeTotalLineText: Sendable, Hashable {
    /// "“AA batteries”:"
    public var name: String
    /// "×14", or `L10n.Quantity.noneLeftValue` at zero.
    public var count: String
    /// Nothing is left in any of the places: the count is drawn in the signal colour.
    public var isNoneLeft: Bool
    /// "in 2 places", or "in any of 2 places" at zero.
    public var places: String
    /// The whole line as one sentence: "“AA batteries”: ×14 in 2 places".
    public var accessibilityLabel: String

    public init(_ total: HomeList.NameTotal) {
        let none = total.quantity == 0
        isNoneLeft = none
        name = L10n.Search.totalName(name: total.name)
        count = none ? L10n.Quantity.noneLeftValue : L10n.Rows.times(count: total.quantity)
        places = none ? L10n.Search.totalNoneIn(places: total.places) : L10n.Search.totalIn(places: total.places)
        accessibilityLabel = none
            ? L10n.Search.totalNone(name: total.name, places: total.places)
            : L10n.Search.total(name: total.name, count: total.quantity, places: total.places)
    }
}
