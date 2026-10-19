import Foundation
import GRDB
import InventoryCore
import Testing
@testable import InventoryStorage

// Parity with the TypeScript repositories the home server runs (DECISIONS U12).
// `Fixtures/db/search/inventory.db` was built through the real TS repositories,
// and `search-vectors.json` / `reads.json` hold what they returned over it. The
// Swift repositories read the same file and must return the same rows, in the
// same order, field for field.

/// Opens a private copy of the search fixture database.
private func openSearchFixture(_ scratch: ScratchDirectory) throws -> LocalRepositories {
    let path = try DatabaseFixtures.copy("search/inventory.db", into: scratch)
    let store = try DatabaseStore(path: path)
    try store.migrate()
    return LocalRepositories(store: store)
}

private func sameScalars(_ a: [String], _ b: [String]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.unicodeScalars.elementsEqual($1.unicodeScalars) }
}

struct SearchVectors: Decodable {
    struct Query: Decodable, Sendable, CustomTestStringConvertible {
        let query: String
        let terms: [String]
        let locations: [LocationSearchResult]
        /// `[id, matchKind]` in result order.
        let items: [[String]]

        var testDescription: String { "\"\(query)\"" }
    }

    /// Each item's search projection, stored once.
    let items: [String: ItemWithContext]
    let queries: [Query]

    static let loaded: SearchVectors? = try? DatabaseFixtures.decode(SearchVectors.self, from: "search-vectors.json")
}

@Suite("search parity with the TypeScript repositories")
struct SearchParityTests {
    @Test("the vectors loaded")
    func vectorsLoaded() throws {
        let vectors = try #require(SearchVectors.loaded)
        #expect(vectors.queries.count > 150)
        // The fixture exercises both caps.
        #expect(vectors.queries.contains { $0.items.count == LocalSearchRepository.itemResultLimit })
        #expect(vectors.queries.contains { $0.locations.count == LocalSearchRepository.locationResultLimit })
    }

    @Test("returns the same terms, locations and items in the same order", arguments: SearchVectors.loaded?.queries ?? [])
    func sameResults(_ vector: SearchVectors.Query) async throws {
        let vectors = try #require(SearchVectors.loaded)
        let scratch = try ScratchDirectory()
        let repos = try openSearchFixture(scratch)

        let results = try await repos.search.search(vector.query)

        #expect(sameScalars(results.terms, vector.terms), "terms \(results.terms) vs \(vector.terms)")
        #expect(results.locations == vector.locations)
        #expect(results.items.map { [$0.id, $0.matchKind.rawValue] } == vector.items)
        for result in results.items {
            #expect(result.item == vectors.items[result.id], "item \(result.id) differs")
        }
    }

    @Test("searchSpaces and searchContainers take terms directly")
    func searchLocationsByTerms() async throws {
        let scratch = try ScratchDirectory()
        let repos = try openSearchFixture(scratch)
        let vector = try #require(SearchVectors.loaded?.queries.first { $0.query == "garage" })
        let spaces = try await repos.search.searchSpaces(vector.terms)
        let containers = try await repos.search.searchContainers(vector.terms)
        #expect(spaces + containers == vector.locations)
    }
}

/// `reads.json`: what the TS repositories' read methods returned over the fixture.
struct ReadVectors: Decodable {
    struct SpaceReads: Decodable {
        let id: String
        let getById: Space?
        let deletionImpact: SpaceDeletionImpact
        let listBySpace: [ContainerWithCounts]
    }

    struct ContainerReads: Decodable {
        let id: String
        let getById: Container?
        let getWithCounts: ContainerWithCounts?
        let deletionImpact: ContainerDeletionImpact
        let listByContainer: [ItemWithContext]
        let qrByContainer: QrBinding?
    }

    struct ItemReads: Decodable {
        let id: String
        let getById: ItemWithContext?
        let getPhotos: [ItemPhoto]
    }

    struct Recent: Decodable {
        let limit: Int
        let items: [ItemWithContext]
    }

    struct Scan: Decodable {
        let raw: String
        let outcome: ScanOutcome

        private enum CodingKeys: String, CodingKey { case raw, outcome }
        private enum OutcomeKeys: String, CodingKey { case kind, container, token, raw }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            raw = try values.decode(String.self, forKey: .raw)
            let outcome = try values.nestedContainer(keyedBy: OutcomeKeys.self, forKey: .outcome)
            switch try outcome.decode(String.self, forKey: .kind) {
            case "bound":
                self.outcome = .bound(
                    container: try outcome.decode(Container.self, forKey: .container),
                    token: try outcome.decode(String.self, forKey: .token)
                )
            case "unknown":
                self.outcome = .unknown(token: try outcome.decode(String.self, forKey: .token))
            default:
                self.outcome = .invalid(raw: try outcome.decode(String.self, forKey: .raw))
            }
        }
    }

    struct TokenRead: Decodable {
        let token: String
        let binding: QrBinding?
    }

    let toolBoxId: String
    let crateId: String
    let listWithCounts: [SpaceWithCounts]
    let listAllWithSpace: [ContainerWithSpace]
    let listUnsorted: [ItemWithContext]
    let countUnsorted: Int
    let countAll: Int
    let listRecent: [Recent]
    let spaces: [SpaceReads]
    let containers: [ContainerReads]
    let items: [ItemReads]
    let scans: [Scan]
    let tokens: [TokenRead]

    static func load() throws -> ReadVectors {
        try DatabaseFixtures.decode(ReadVectors.self, from: "reads.json")
    }
}

@Suite("read parity with the TypeScript repositories")
struct ReadParityTests {
    @Test("lists, counts and recents match")
    func listsMatch() async throws {
        let vectors = try ReadVectors.load()
        let scratch = try ScratchDirectory()
        let repos = try openSearchFixture(scratch)

        #expect(try await repos.spaces.listWithCounts() == vectors.listWithCounts)
        #expect(try await repos.containers.listAllWithSpace() == vectors.listAllWithSpace)
        #expect(try await repos.items.listUnsorted() == vectors.listUnsorted)
        #expect(try await repos.items.countUnsorted() == vectors.countUnsorted)
        #expect(try await repos.items.countAll() == vectors.countAll)
        for recent in vectors.listRecent {
            #expect(try await repos.items.listRecent(limit: recent.limit) == recent.items, "listRecent(\(recent.limit))")
        }
    }

    @Test("every space read matches")
    func spacesMatch() async throws {
        let vectors = try ReadVectors.load()
        let scratch = try ScratchDirectory()
        let repos = try openSearchFixture(scratch)
        for space in vectors.spaces {
            #expect(try await repos.spaces.getById(space.id) == space.getById, "getById \(space.id)")
            #expect(try await repos.spaces.deletionImpact(space.id) == space.deletionImpact, "deletionImpact \(space.id)")
            #expect(try await repos.containers.listBySpace(space.id) == space.listBySpace, "listBySpace \(space.id)")
        }
    }

    @Test("every container read matches")
    func containersMatch() async throws {
        let vectors = try ReadVectors.load()
        let scratch = try ScratchDirectory()
        let repos = try openSearchFixture(scratch)
        for container in vectors.containers {
            let id = container.id
            #expect(try await repos.containers.getById(id) == container.getById, "getById \(id)")
            #expect(try await repos.containers.getWithCounts(id) == container.getWithCounts, "getWithCounts \(id)")
            #expect(try await repos.containers.deletionImpact(id) == container.deletionImpact, "deletionImpact \(id)")
            #expect(try await repos.items.listByContainer(id) == container.listByContainer, "listByContainer \(id)")
            #expect(try await repos.qr.getByContainer(id) == container.qrByContainer, "qr.getByContainer \(id)")
        }
    }

    @Test("every item read matches")
    func itemsMatch() async throws {
        let vectors = try ReadVectors.load()
        let scratch = try ScratchDirectory()
        let repos = try openSearchFixture(scratch)
        for item in vectors.items {
            #expect(try await repos.items.getById(item.id) == item.getById, "getById \(item.id)")
            #expect(try await repos.items.getPhotos(item.id) == item.getPhotos, "getPhotos \(item.id)")
        }
    }

    @Test("scans and token lookups match")
    func scansMatch() async throws {
        let vectors = try ReadVectors.load()
        let scratch = try ScratchDirectory()
        let repos = try openSearchFixture(scratch)
        for scan in vectors.scans {
            #expect(try await repos.qr.resolveScan(scan.raw) == scan.outcome, "resolveScan \(scan.raw)")
        }
        for token in vectors.tokens {
            #expect(try await repos.qr.getByToken(token.token) == token.binding, "getByToken \(token.token)")
        }
    }
}
