import InventoryCore
import InventoryStrings
import Testing
@testable import InventoryAppModels

/// Home's flat list grouped into inset-grouped sections (06 §5.5, §5.7, §5.11 "Native layout").
@Suite("HomeSections (Home's list as native sections)")
struct HomeSectionsTests {
    private typealias Fixtures = ShellFixtures

    private func kinds(_ sections: [HomeSections.Section]) -> [String] {
        sections.map { section in
            switch section.kind {
            case .refreshFailed: "refreshFailed"
            case .notice: "notice"
            case .dropZone: "dropZone"
            case .status(let status): "status:\(status.rawValue)"
            case .rows: "rows:\(section.title ?? "-")"
            }
        }
    }

    @Test("the overview: the banner, the notice and the card each alone, then Recently added with its rows and Show more under them")
    func overview() {
        let recent = (0..<12).map { Fixtures.item("i\($0)") }
        let entries = [HomeList.Entry.field] + HomeList.idleEntries(HomeList.IdleInput(
            notice: true, refreshFailed: true, dropZoneCount: 3, body: .list(recent: recent, canShowMore: true)))
        let sections = HomeSections.sections(entries)

        #expect(kinds(sections) == ["refreshFailed", "notice", "dropZone", "rows:\(L10n.Home.recent)"])
        let recentSection = sections[3]
        #expect(recentSection.count == 12)
        #expect(recentSection.summary == nil)
        #expect(recentSection.rows.map(\.id) == recent.map { "recent-\($0.id)" })
        #expect(recentSection.showsMore)
        #expect(recentSection.totals.isEmpty)
        #expect(Set(sections.map(\.id)).count == sections.count)
        #expect(HomeSections.itemIds(sections) == recent.map(\.id))
    }

    @Test("a status stands alone, after the card")
    func status() {
        let entries = [HomeList.Entry.field] + HomeList.idleEntries(HomeList.IdleInput(
            notice: false, refreshFailed: false, dropZoneCount: 2, body: .status(.error)))
        #expect(kinds(HomeSections.sections(entries)) == ["dropZone", "status:error"])
    }

    @Test("the field alone adds nothing")
    func fieldOnly() {
        #expect(HomeSections.sections([.field]).isEmpty)
        #expect(HomeSections.sections([.field, .status(.searching)]).map(\.id) == ["status"])
    }

    @Test("results: the summary above the first title, the totals under it; items, places and kept-in each a section")
    func results() {
        let results = Fixtures.results(
            [
                Fixtures.hit("a", name: "AA batteries", quantity: 12, containerId: "c1"),
                Fixtures.hit("b", name: "aa batteries", quantity: 2, containerId: "c2"),
                Fixtures.hit("k", .location),
            ],
            [Fixtures.place("p1"), Fixtures.place("s1", .space)])
        let sections = HomeSections.sections([.field] + HomeList.resultEntries(results, refreshFailed: true))

        #expect(kinds(sections) == [
            "refreshFailed",
            "rows:\(L10n.Search.items)",
            "rows:\(L10n.Search.places)",
            "rows:\(L10n.Search.keptInThose)",
        ])
        #expect(sections[1].summary == L10n.Search.summary(items: 3, places: 2))
        #expect(sections[2].summary == nil)
        #expect(sections[1].rows.map(\.id) == ["item-a", "item-b"])
        #expect(sections[1].totals == [HomeList.NameTotal(name: "AA batteries", quantity: 14, places: 2)])
        #expect(sections[2].totals.isEmpty)
        #expect(!sections[1].showsMore)
        #expect(sections[2].rows.map(\.id) == ["place-container-p1", "place-space-s1"])
        #expect(sections[3].rows.map(\.id) == ["kept-k"])
        #expect(sections[1].count == 2)
        #expect(HomeSections.itemIds(sections) == ["a", "b", "k"])
    }

    @Test("one section of results has no summary")
    func oneSection() {
        let sections = HomeSections.sections(HomeList.resultEntries(Fixtures.results([Fixtures.hit("a"), Fixtures.hit("b")]), refreshFailed: false))
        #expect(kinds(sections) == ["rows:\(L10n.Search.items)"])
        #expect(sections[0].summary == nil)
    }

    @Test("nothing found is a status section")
    func noResults() {
        let sections = HomeSections.sections([.field] + HomeList.resultEntries(Fixtures.results([]), refreshFailed: true))
        #expect(kinds(sections) == ["status:noResults"])
    }

    @Test("older results under the searching skeleton keep their sections")
    func olderUnderSkeleton() {
        let results = Fixtures.results([Fixtures.hit("a")], [Fixtures.place("p1")])
        let body = HomeDerivation.searchBody(pending: true, results: results, cause: nil, dim: true, mountSkeleton: true, connectionIsOnline: true)
        let sections = HomeSections.sections([.field] + body)
        #expect(kinds(sections) == ["status:searching", "rows:\(L10n.Search.items)", "rows:\(L10n.Search.places)"])
        #expect(sections[1].summary == L10n.Search.summary(items: 1, places: 1))
    }

    @Test("rows before any title get an untitled section")
    func untitledRows() {
        let item = Fixtures.item("a")
        let sections = HomeSections.sections([.item(key: "recent-a", item: item, position: HomeList.Position(index: 0, count: 1)), .more])
        #expect(kinds(sections) == ["rows:-"])
        #expect(sections[0].rows.map(\.id) == ["recent-a"])
        #expect(sections[0].showsMore)
    }

    @Test("reads the total line as one sentence, with the count set apart", arguments: [
        (HomeList.NameTotal(name: "AA batteries", quantity: 14, places: 2), "“AA batteries”:", "×14", false, "in 2 places", "“AA batteries”: ×14 in 2 places"),
        (HomeList.NameTotal(name: "Printer ink", quantity: 0, places: 2), "“Printer ink”:", "none left", true, "in any of 2 places", "“Printer ink”: none left in any of 2 places"),
    ])
    func totalLine(total: HomeList.NameTotal, name: String, count: String, none: Bool, places: String, spoken: String) {
        let line = HomeTotalLineText(total)
        #expect(line.name == name)
        #expect(line.count == count)
        #expect(line.isNoneLeft == none)
        #expect(line.places == places)
        #expect(line.accessibilityLabel == spoken)
    }

    @Test("the clear button empties the field in one step; deleting the last letter is typing", arguments: [
        ("drill", "", true),
        ("dr", "", true),
        ("d", "", false),
        ("drill", "dril", false),
        ("", "", false),
        ("", "a", false),
    ])
    func clear(old: String, new: String, isClear: Bool) {
        #expect(HomeSearchFieldRules.isClear(from: old, to: new) == isClear)
    }
}
