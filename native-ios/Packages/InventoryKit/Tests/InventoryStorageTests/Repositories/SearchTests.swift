import Foundation
import GRDB
import InventoryCore
import Testing
@testable import InventoryStorage

/// Ports `src/repositories/__tests__/search.test.ts`, plus 01 §13.8 #2, #3.
@Suite("search")
struct SearchTests {
    struct Seeded {
        let repos: LocalRepositories
        let garage: Space
        let kitchen: Space
        let toolBox: Container
        let drawer: Container
    }

    /// RN `seedInventory`.
    static func seedInventory() async throws -> Seeded {
        let repos = try freshRepos()

        let garage = try await repos.spaces.create(CreateSpaceInput(name: "Garage", icon: "car", color: "#5B8DEF"))
        let kitchen = try await repos.spaces.create(CreateSpaceInput(name: "Kitchen", icon: "pot", color: "#E4572E"))

        let toolBox = try await repos.containers.create(
            CreateContainerInput(spaceId: garage.id, name: "Tool Box", visualType: .box)
        )
        let drawer = try await repos.containers.create(
            CreateContainerInput(spaceId: kitchen.id, name: "Utensil Drawer", visualType: .drawer)
        )

        _ = try await repos.items.create(ItemDraft(
            containerId: toolBox.id,
            name: "Cordless Drill",
            category: "Power Tools",
            tags: ["dewalt", "18v"]
        ))
        _ = try await repos.items.create(ItemDraft(containerId: toolBox.id, name: "Hammer", category: "Hand Tools"))
        _ = try await repos.items.create(ItemDraft(containerId: drawer.id, name: "Whisk", category: "Utensils"))

        return Seeded(repos: repos, garage: garage, kitchen: kitchen, toolBox: toolBox, drawer: drawer)
    }

    @Test("returns nothing for an empty query")
    func emptyQuery() async throws {
        let seeded = try await Self.seedInventory()
        let results = try await seeded.repos.search.search("   ")
        #expect(results == SearchResults(terms: [], locations: [], items: []))
    }

    @Test("matches USB-C when the query omits the hyphen")
    func matchesUsbC() async throws {
        let seeded = try await Self.seedInventory()
        let repos = seeded.repos
        _ = try await repos.items.create(ItemDraft(
            containerId: seeded.toolBox.id,
            name: "USB-C to USB-A cable",
            category: "Cables"
        ))

        #expect(try await repos.search.search("usbc").items.map(\.name) == ["USB-C to USB-A cable"])
        #expect(try await repos.search.search("usb-c").items.map(\.name) == ["USB-C to USB-A cable"])

        _ = try await repos.items.create(ItemDraft(containerId: seeded.toolBox.id, name: "Microusb cable", category: "Cables"))
        #expect(try await repos.search.search("usbc").items.map(\.name) == ["USB-C to USB-A cable"])
    }

    @Test("matches an item by name, case-insensitively")
    func matchesByName() async throws {
        let seeded = try await Self.seedInventory()
        let results = try await seeded.repos.search.search("DRILL")

        #expect(results.items.map(\.name) == ["Cordless Drill"])
        #expect(results.items.first?.matchKind == .direct)
    }

    @Test("carries the space icon and colour so a result can be placed at a glance")
    func carriesSpaceStyle() async throws {
        let seeded = try await Self.seedInventory()
        let results = try await seeded.repos.search.search("DRILL")

        #expect(results.items.first?.spaceName == "Garage")
        #expect(results.items.first?.spaceIcon == "car")
        #expect(results.items.first?.spaceColor == "#5B8DEF")
    }

    @Test("matches by category and by tag")
    func matchesCategoryAndTag() async throws {
        let seeded = try await Self.seedInventory()
        let search = seeded.repos.search

        #expect(try await search.search("power tools").items.count == 1)
        #expect(try await search.search("dewalt").items.map(\.name) == ["Cordless Drill"])
        #expect(try await search.search("18v").items.count == 1)
    }

    @Test("includes items found through their space and marks them as location matches")
    func locationMatches() async throws {
        let seeded = try await Self.seedInventory()
        let results = try await seeded.repos.search.search("kitchen")

        #expect(results.items.map(\.name) == ["Whisk"])
        #expect(results.items.first?.matchKind == .location)
    }

    @Test("lists matching spaces and containers in a separate locations section")
    func listsLocations() async throws {
        let seeded = try await Self.seedInventory()
        let results = try await seeded.repos.search.search("garage")

        #expect(results.locations.map(\.kind).contains(.space))
        #expect(results.locations.first?.title == "Garage")
    }

    @Test("finds a container by its short code, with or without the dash")
    func findsShortCode() async throws {
        let seeded = try await Self.seedInventory()
        let code = seeded.toolBox.shortCode

        let withDash = try await seeded.repos.search.search(code)
        let withoutDash = try await seeded.repos.search.search(code.replacingOccurrences(of: "-", with: ""))

        #expect(withDash.locations.contains { $0.id == seeded.toolBox.id })
        #expect(withoutDash.locations.contains { $0.id == seeded.toolBox.id })
    }

    @Test("combines an item term with a location term")
    func combinesTerms() async throws {
        let seeded = try await Self.seedInventory()
        // "drill" matches the item; "garage" matches only its space.
        let results = try await seeded.repos.search.search("garage drill")
        #expect(results.items.map(\.name) == ["Cordless Drill"])
    }

    @Test("requires every term to match somewhere")
    func requiresEveryTerm() async throws {
        let seeded = try await Self.seedInventory()
        let results = try await seeded.repos.search.search("drill kitchen")
        #expect(results.items.isEmpty)
    }

    @Test("ranks direct item matches above location-only matches")
    func ranksDirectFirst() async throws {
        let seeded = try await Self.seedInventory()
        let box = try await seeded.repos.containers.create(
            CreateContainerInput(spaceId: seeded.garage.id, name: "Spare Parts", visualType: .bin)
        )
        _ = try await seeded.repos.items.create(ItemDraft(containerId: box.id, name: "Garage Door Remote"))

        let results = try await seeded.repos.search.search("garage")

        #expect(results.items.first?.name == "Garage Door Remote")
        #expect(results.items.first?.matchKind == .direct)
    }

    @Test("treats LIKE wildcards in the query as literal characters")
    func escapesWildcards() async throws {
        let seeded = try await Self.seedInventory()
        // Without escaping, "%" would match every item in the inventory.
        #expect(try await seeded.repos.search.search("%").items.isEmpty)
        #expect(try await seeded.repos.search.search("_").items.isEmpty)
    }

    @Test("reflects edits and deletions without any cache to invalidate")
    func reflectsEdits() async throws {
        let seeded = try await Self.seedInventory()
        let repos = seeded.repos
        let item = try #require(try await repos.items.listByContainer(seeded.toolBox.id).first)

        _ = try await repos.items.update(item.id, UpdateItemInput(name: "Angle Grinder"))
        #expect(try await repos.search.search("grinder").items.count == 1)

        _ = try await repos.items.delete(item.id)
        #expect(try await repos.search.search("grinder").items.isEmpty)
    }

    @Test("formats the Space > Container path shown on each result")
    func formatsLocationPath() async throws {
        let seeded = try await Self.seedInventory()
        let results = try await seeded.repos.search.search("drill")
        let first = try #require(results.items.first)
        #expect(formatLocationPath(first.item) == "Garage > Tool Box")
    }

    @Test("falls back to the short code when a container has no name")
    func pathFallsBackToShortCode() async throws {
        let seeded = try await Self.seedInventory()
        let unnamed = try await seeded.repos.containers.create(
            CreateContainerInput(spaceId: seeded.garage.id, visualType: .crate)
        )
        _ = try await seeded.repos.items.create(ItemDraft(containerId: unnamed.id, name: "Tent Pegs"))

        let results = try await seeded.repos.search.search("tent")
        let first = try #require(results.items.first)
        #expect(formatLocationPath(first.item) == "Garage > \(unnamed.shortCode)")
    }

    // MARK: 01 §13.8

    @Test("folds accents in the query only: café finds nothing stored as Café, caf does")
    func oneSidedAccentFolding() async throws {
        let seeded = try await Self.seedInventory()
        _ = try await seeded.repos.items.create(ItemDraft(containerId: seeded.drawer.id, name: "Café Mug"))

        #expect(try await seeded.repos.search.search("café").items.isEmpty)
        #expect(try await seeded.repos.search.search("caf").items.map(\.name) == ["Café Mug"])
    }

    @Test("finds drop-zone items through their location; the drop zone is never a location", arguments: [
        "drop", "zone", "dropzone",
    ])
    func dropZoneThroughLocation(query: String) async throws {
        let seeded = try await Self.seedInventory()
        _ = try await seeded.repos.items.create(ItemDraft(containerId: DropZone.containerId, name: "Mystery cable"))

        let results = try await seeded.repos.search.search(query)
        #expect(results.items.map(\.name) == ["Mystery cable"])
        #expect(results.items.first?.matchKind == .location)
        #expect(results.locations.isEmpty)
        #expect(formatLocationPath(try #require(results.items.first).item) == "Drop zone")
    }
}

@Suite("search performance")
struct SearchPerformanceTests {
    /// Issue #14: search stays responsive at 10,000 items (a guard against O(n²) regressions).
    @Test("stays responsive with 10,000 items")
    func tenThousandItems() async throws {
        let repos = try freshRepos()
        let space = try await repos.spaces.create(CreateSpaceInput(name: "Warehouse", icon: "box", color: "#5B8DEF"))
        let container = try await repos.containers.create(CreateContainerInput(spaceId: space.id, visualType: .shelf))

        try await repos.store.queue.write { db in
            let now = epochMillis()
            for index in 0..<10_000 {
                try db.execute(
                    sql: """
                        INSERT INTO items (id, container_id, name, category, quantity, created_at,
                                           updated_at, search_text)
                        VALUES (?, ?, ?, ?, 1, ?, ?, ?)
                        """,
                    arguments: ["item-\(index)", container.id, "Widget \(index)", "Parts", now, now, "widget \(index) parts"]
                )
            }
        }

        #expect(try await repos.items.countAll() == 10_000)

        // The CPU time of the thread that ran the search, measured inside the read: a test
        // process starved for seconds on a loaded Mac does not add to it, as it would to
        // wall-clock time, while an O(n²) search still blows through the second.
        let (results, elapsed) = try await repos.store.queue.read { db in
            let started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let results = try repos.search.search("widget 4242", in: db)
            return (results, Duration.nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started)))
        }

        #expect(results.items.map(\.name) == ["Widget 4242"])
        #expect(elapsed < .milliseconds(1000))
    }
}
