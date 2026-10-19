import InventoryCore
import Testing
@testable import InventoryServices

/// RN `item(overrides)` in fastReview.test.ts: a Garage › Shelf row.
enum FastReviewRows {
    static func item(id: String = "item-1", name: String = "", createdAt: Int64 = 0, updatedAt: Int64 = 0) -> ItemWithContext {
        ItemWithContext(
            item: Item(
                id: id,
                containerId: "container-1",
                name: name,
                category: nil,
                quantity: 1,
                notes: nil,
                createdAt: createdAt,
                updatedAt: updatedAt
            ),
            photoId: nil,
            photoUri: nil,
            photoThumbUri: nil,
            tags: [],
            spaceId: "space-1",
            spaceName: "Garage",
            spaceIcon: "🚗",
            spaceColor: "#000",
            containerName: "Shelf",
            containerShortCode: "BOX-0000"
        )
    }
}

@Suite("FastReview.sessionItems (fastReview.test.ts)")
struct FastReviewSessionItemsTests {
    @Test("keeps only items created during the session, oldest first")
    func keepsSessionOldestFirst() {
        let rows = [
            FastReviewRows.item(id: "newest", createdAt: 300),
            FastReviewRows.item(id: "older", createdAt: 200),
            FastReviewRows.item(id: "pre-session", createdAt: 99),
        ]
        #expect(FastReview.sessionItems(rows, since: 100).map(\.id) == ["older", "newest"])
    }

    @Test("includes an item created exactly at the session start")
    func includesStart() {
        #expect(FastReview.sessionItems([FastReviewRows.item(createdAt: 100)], since: 100).count == 1)
    }

    @Test("keeps the repository's order for rows created in the same millisecond, as JS's stable sort does")
    func stableTies() {
        let rows = [
            FastReviewRows.item(id: "c", createdAt: 200),
            FastReviewRows.item(id: "b", createdAt: 100),
            FastReviewRows.item(id: "a", createdAt: 100),
            FastReviewRows.item(id: "z", createdAt: 100),
        ]
        #expect(FastReview.sessionItems(rows, since: 0).map(\.id) == ["b", "a", "z", "c"])
    }
}

@Suite("FastReview.summarize (fastReview.test.ts)")
struct FastReviewSummaryTests {
    @Test("splits saved rows into named and unnamed")
    func splitsNamed() {
        let rows = [
            FastReviewRows.item(id: "a", name: "Drill"),
            FastReviewRows.item(id: "b", name: ""),
            FastReviewRows.item(id: "c", name: "   "),
        ]
        #expect(FastReview.summarize(rows, expected: 3) == FastSessionSummary(saved: 3, named: 1, unnamed: 2, pending: 0))
    }

    @Test("reports rows the pipeline has not landed yet as pending")
    func pending() {
        #expect(FastReview.summarize([FastReviewRows.item()], expected: 3).pending == 2)
    }

    @Test("never reports negative pending when a reported shot failed to write")
    func neverNegative() {
        #expect(FastReview.summarize([FastReviewRows.item(), FastReviewRows.item(id: "b")], expected: 1).pending == 0)
    }

    @Test("counts a name of JS whitespace only (no-break space, BOM) as unnamed")
    func jsWhitespace() {
        let rows = [FastReviewRows.item(id: "a", name: "\u{00A0}\u{FEFF}"), FastReviewRows.item(id: "b", name: "\u{2003}Hammer")]
        #expect(FastReview.summarize(rows, expected: 0) == FastSessionSummary(saved: 2, named: 1, unnamed: 1, pending: 0))
    }
}
