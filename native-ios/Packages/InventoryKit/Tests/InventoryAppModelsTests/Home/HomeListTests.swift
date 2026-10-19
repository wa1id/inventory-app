import InventoryCore
import InventoryStrings
import Testing
@testable import InventoryAppModels

// Port of src/ui/home/__tests__/homeList.test.ts, test for test (06 §21).

private typealias Fixtures = ShellFixtures

private func kinds(_ entries: [HomeList.Entry]) -> [HomeList.Entry.Kind] {
    entries.map(\.kind)
}

private func total(_ name: String, _ quantity: Int, _ containerId: String) -> HomeList.NameTotalInput {
    HomeList.NameTotalInput(name: name, quantity: quantity, containerId: containerId)
}

@Suite("homeList › householdCounts")
struct HomeListHouseholdCountsTests {
    @Test("adds the drop zone’s items but not its container")
    func addsDropZoneItems() {
        #expect(HomeList.householdCounts([(4, 21), (9, 20)], dropZoneCount: 4)
            == HomeList.HouseholdCounts(spaces: 2, containers: 13, items: 45))
    }

    @Test("counts an empty household as nothing")
    func emptyHousehold() {
        #expect(HomeList.householdCounts([], dropZoneCount: 0) == HomeList.HouseholdCounts(spaces: 0, containers: 0, items: 0))
    }

    @Test("reads as one sentence")
    func oneSentence() {
        #expect(L10n.Home.summary(spaces: 5, containers: 13, items: 45) == "5 spaces, 13 containers and 45 items.")
        #expect(L10n.Home.summary(spaces: 1, containers: 1, items: 1) == "1 space, 1 container and 1 item.")
        #expect(HomeList.HouseholdCounts(spaces: 5, containers: 13, items: 45).summary == "5 spaces, 13 containers and 45 items.")
    }

    @Test("counts spaces.listWithCounts rows the same way")
    func overSpaceRows() {
        let spaces = [Fixtures.space("a", containers: 4, items: 21), Fixtures.space("b", containers: 9, items: 20)]
        #expect(HomeList.householdCounts(spaces: spaces, dropZoneCount: 4) == HomeList.HouseholdCounts(spaces: 2, containers: 13, items: 45))
    }
}

@Suite("homeList › nameTotals")
struct HomeListNameTotalsTests {
    @Test("adds up a name kept in two containers, ignoring case and spaces")
    func addsUp() {
        #expect(HomeList.nameTotals([
            total("AA batteries", 12, "c1"),
            total(" aa Batteries ", 2, "c2"),
            total("Drill", 1, "c1"),
        ]) == [HomeList.NameTotal(name: "AA batteries", quantity: 14, places: 2)])
    }

    @Test("says none are left when every place is empty")
    func noneLeft() throws {
        let totals = HomeList.nameTotals([
            total("Printer ink", 0, "c1"),
            total("Printer ink", 0, DropZone.containerId),
        ])
        let first = try #require(totals.first)
        #expect(first == HomeList.NameTotal(name: "Printer ink", quantity: 0, places: 2))
        #expect(L10n.Search.totalNone(name: first.name, places: first.places) == "“Printer ink”: none left in any of 2 places")
    }

    @Test("counts places, not items, and needs a second place")
    func needsSecondPlace() {
        #expect(HomeList.nameTotals([total("Screws", 10, "c1"), total("Screws", 5, "c1")]).isEmpty)
        #expect(HomeList.nameTotals([total("Screws", 10, "c1"), total("Screws", 5, "c1"), total("Screws", 1, "c2")])
            == [HomeList.NameTotal(name: "Screws", quantity: 16, places: 2)])
    }

    @Test("never totals unnamed items")
    func neverUnnamed() {
        #expect(HomeList.nameTotals([total("", 1, "c1"), total("  ", 1, "c2")]).isEmpty)
    }

    @Test("keeps the order the names first appear in")
    func firstAppearanceOrder() {
        let totals = HomeList.nameTotals([
            total("Tape", 1, "c1"),
            total("Glue", 1, "c1"),
            total("Glue", 1, "c2"),
            total("Tape", 1, "c2"),
        ])
        #expect(totals.map(\.name) == ["Tape", "Glue"])
    }

    @Test("matches names as JS strings: JS trim and lowercase, no canonical equivalence")
    func jsStringSemantics() {
        // U+FEFF is JS white space; a decomposed é is a different JS string from a composed one.
        #expect(HomeList.nameTotals([total("\u{FEFF}Café", 1, "c1"), total("CAFÉ", 1, "c2")])
            == [HomeList.NameTotal(name: "Café", quantity: 2, places: 2)])
        #expect(HomeList.nameTotals([total("Caf\u{E9}", 1, "c1"), total("Cafe\u{301}", 1, "c2")]).isEmpty)
    }
}

@Suite("homeList › idleEntries")
struct HomeListIdleEntriesTests {
    private let recent = [Fixtures.item("a"), Fixtures.item("b"), Fixtures.item("c")]

    @Test("shows the notice, the card and then Recently added with sheet positions")
    func noticeCardRecent() throws {
        let entries = HomeList.idleEntries(HomeList.IdleInput(
            notice: true, refreshFailed: false, dropZoneCount: 2,
            body: .list(recent: recent, canShowMore: true)))
        #expect(kinds(entries) == [.notice, .dropZone, .title, .item, .item, .item, .more])
        guard case .title(_, let title, let count, let first) = entries[2] else {
            Issue.record("expected a title, got \(entries[2])")
            return
        }
        #expect(title == "Recently added")
        #expect(count == 3)
        #expect(!first)
        let positions = entries.compactMap { entry -> HomeList.Position? in
            if case .item(_, _, let position) = entry { return position }
            return nil
        }
        #expect(positions == [
            HomeList.Position(index: 0, count: 3),
            HomeList.Position(index: 1, count: 3),
            HomeList.Position(index: 2, count: 3),
        ])
    }

    @Test("leaves out the card when nothing is waiting, and the section when nothing is stored")
    func nothing() {
        #expect(HomeList.idleEntries(HomeList.IdleInput(
            notice: false, refreshFailed: false, dropZoneCount: 0,
            body: .list(recent: [], canShowMore: false))).isEmpty)
    }

    @Test("puts the section first when nothing comes before it")
    func sectionFirst() {
        let entries = HomeList.idleEntries(HomeList.IdleInput(
            notice: false, refreshFailed: false, dropZoneCount: 0,
            body: .list(recent: recent, canShowMore: false)))
        guard case .title(_, _, _, let first)? = entries.first else {
            Issue.record("expected a title first")
            return
        }
        #expect(first)
    }

    @Test("shows a status in place of the list, and the stale-data notice on top")
    func statusWithBanner() {
        #expect(kinds(HomeList.idleEntries(HomeList.IdleInput(
            notice: false, refreshFailed: true, dropZoneCount: 1,
            body: .status(.error)))) == [.refreshFailed, .dropZone, .status])
    }
}

@Suite("homeList › resultEntries")
struct HomeListResultEntriesTests {
    private func titles(_ entries: [HomeList.Entry]) -> [(String, Int, Bool)] {
        entries.compactMap { entry in
            if case .title(_, let title, let count, let first) = entry { return (title, count, first) }
            return nil
        }
    }

    @Test("orders items, places, then items kept in those places")
    func order() {
        let entries = HomeList.resultEntries(
            Fixtures.results(
                [Fixtures.hit("d1"), Fixtures.hit("l1", .location), Fixtures.hit("d2"), Fixtures.hit("l2", .location)],
                [Fixtures.place("box"), Fixtures.place("garage", .space)]),
            refreshFailed: false)
        #expect(kinds(entries) == [.summary, .title, .item, .item, .title, .place, .place, .title, .item, .item])
        #expect(entries[0] == .summary(text: "4 items and 2 places found"))
        let titles = titles(entries)
        #expect(titles.map { $0.0 } == ["Items", "Spaces and containers", "Kept in those places"])
        #expect(titles.map { $0.2 } == [true, false, false])
    }

    @Test("gives every entry its own key, even an id that is both a place and a row")
    func uniqueKeys() {
        let entries = HomeList.resultEntries(
            Fixtures.results([Fixtures.hit("x"), Fixtures.hit("y", .location)], [Fixtures.place("x")]),
            refreshFailed: false)
        let keys = entries.map(\.key)
        #expect(Set(keys).count == keys.count)
        #expect(keys.contains("item-x"))
        #expect(keys.contains("place-container-x"))
        #expect(keys.contains("kept-y"))
    }

    @Test("puts the totals at the top of the items")
    func totalsFirst() {
        let entries = HomeList.resultEntries(
            Fixtures.results([
                Fixtures.hit("a", name: "AA batteries", quantity: 12, containerId: "c1"),
                Fixtures.hit("b", name: "AA batteries", quantity: 2, containerId: "c2"),
            ]),
            refreshFailed: false)
        #expect(kinds(entries) == [.title, .totals, .item, .item])
        #expect(entries[1] == .totals([HomeList.NameTotal(name: "AA batteries", quantity: 14, places: 2)]))
    }

    @Test("starts with the first section that has anything")
    func firstNonEmptySection() {
        let entries = HomeList.resultEntries(
            Fixtures.results([Fixtures.hit("a", .location)], [Fixtures.place("box")]),
            refreshFailed: false)
        #expect(kinds(entries) == [.summary, .title, .place, .title, .item])
        let titles = titles(entries)
        #expect(titles.first?.0 == "Spaces and containers")
        #expect(titles.first?.2 == true)
        #expect(entries[0] == .summary(text: "1 item and 1 place found"))
    }

    @Test("leaves the summary to the section title when there is one section")
    func oneSection() {
        #expect(kinds(HomeList.resultEntries(Fixtures.results([Fixtures.hit("a"), Fixtures.hit("b")]), refreshFailed: false))
            == [.title, .item, .item])
        let entries = HomeList.resultEntries(Fixtures.results([], [Fixtures.place("box")]), refreshFailed: false)
        #expect(kinds(entries) == [.title, .place])
        let titles = titles(entries)
        #expect(titles.count == 1)
        #expect(titles.first?.0 == "Spaces and containers")
        #expect(titles.first?.1 == 1)
        #expect(titles.first?.2 == true)
    }

    @Test("says nothing was found as a status, not an empty list")
    func noResults() {
        #expect(HomeList.resultEntries(Fixtures.results([]), refreshFailed: true) == [.status(.noResults)])
        #expect(HomeList.Entry.status(.noResults).key == "status")
    }

    @Test("keeps the results under the stale-data notice when a refresh failed")
    func underBanner() {
        #expect(Array(kinds(HomeList.resultEntries(Fixtures.results([Fixtures.hit("a")]), refreshFailed: true)).prefix(2))
            == [.refreshFailed, .title])
        #expect(Array(kinds(HomeList.resultEntries(Fixtures.results([Fixtures.hit("a")], [Fixtures.place("box")]), refreshFailed: true)).prefix(2))
            == [.refreshFailed, .summary])
    }
}

@Suite("homeList › splitMatches")
struct HomeListSplitMatchesTests {
    @Test("keeps each kind in the order the search returned it")
    func keepsOrder() {
        let (direct, location) = HomeList.splitMatches([
            Fixtures.hit("1"), Fixtures.hit("2", .location), Fixtures.hit("3"), Fixtures.hit("4", .location),
        ])
        #expect(direct.map(\.id) == ["1", "3"])
        #expect(location.map(\.id) == ["2", "4"])
    }
}

@Suite("homeList › search copy")
struct HomeListSearchCopyTests {
    @Test("summarises what was found")
    func summary() {
        #expect(L10n.Search.summary(items: 3, places: 1) == "3 items and 1 place found")
        #expect(L10n.Search.summary(items: 1, places: 0) == "1 item found")
        #expect(L10n.Search.summary(items: 0, places: 0) == "Nothing found")
    }

    @Test("reads the total line as one sentence")
    func totalLine() {
        #expect(L10n.Search.total(name: "AA batteries", count: 14, places: 2) == "“AA batteries”: ×14 in 2 places")
    }
}

@Suite("homeList › entry keys")
struct HomeListEntryKeyTests {
    @Test("the fixed entries keep RN's keys", arguments: [
        (HomeList.Entry.field, "field"),
        (.notice, "notice"),
        (.refreshFailed, "refresh-failed"),
        (.dropZone, "drop-zone"),
        (.summary(text: "x"), "summary"),
        (.totals([]), "totals"),
        (.more, "recent-more"),
        (.status(.loading), "status"),
    ])
    func keys(entry: HomeList.Entry, key: String) {
        #expect(entry.key == key)
        #expect(entry.id == key)
    }

    @Test("Home asks for 12 recent items, then 40")
    func limits() {
        #expect(HomeList.recentFirst == 12)
        #expect(HomeList.recentMore == 40)
    }
}
