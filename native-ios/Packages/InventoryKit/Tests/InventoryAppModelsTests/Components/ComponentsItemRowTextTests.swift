import Foundation
import InventoryCore
import InventoryStrings
import Testing
@testable import InventoryAppModels

/// The fold rule and labels of src/ui/components/ItemRow.tsx (06 §15.2, §7.2). RN has no tests
/// for the row; these pin the rules the spec spells out.
@Suite("ItemRow text (ItemRow.tsx)")
struct ComponentsItemRowTextTests {
    static let now: Int64 = 1_790_000_000_000
    static let minute: Int64 = 60_000

    static func item(name: String = "Drill", quantity: Int = 3, containerId: String = "c1", containerName: String? = "Tool chest") -> ItemWithContext {
        ItemWithContext(
            item: Item(id: "i1", containerId: containerId, name: name, category: "Tools", quantity: quantity, notes: nil, createdAt: now, updatedAt: now),
            photoId: nil,
            photoUri: nil,
            photoThumbUri: nil,
            tags: [],
            spaceId: "s1",
            spaceName: "Garage",
            spaceIcon: "🚗",
            spaceColor: "#5B8DEF",
            containerName: containerName,
            containerShortCode: "CAB-J92R"
        )
    }

    @Test("the where line is the location line, never folded text")
    func whereLineIsNotText() {
        #expect(ItemRowText.secondLine(.where, category: "Tools", createdAt: Self.now, count: 3, now: Self.now) == nil)
    }

    @Test("detail shows the category, with the folded count in front")
    func detailLine() {
        #expect(ItemRowText.secondLine(.detail, category: "Tools", createdAt: 0, count: nil)?.text == "Tools")
        #expect(ItemRowText.secondLine(.detail, category: "Tools", createdAt: 0, count: 3)?.text == "×3 · Tools")
        #expect(ItemRowText.secondLine(.detail, category: "Tools", createdAt: 0, count: 1)?.text == "Tools")
        let none = ItemRowText.secondLine(.detail, category: "Tools", createdAt: 0, count: 0)
        #expect(none?.text == "None left · Tools")
        #expect(none?.lead?.isNoneLeft == true)
    }

    @Test("detail with no category says nothing unless a count is folded")
    func detailWithoutCategory() {
        #expect(ItemRowText.secondLine(.detail, category: nil, createdAt: 0, count: nil) == nil)
        #expect(ItemRowText.secondLine(.detail, category: "", createdAt: 0, count: 1) == nil)
        #expect(ItemRowText.secondLine(.detail, category: nil, createdAt: 0, count: 5)?.text == "×5")
        // JS truthiness: a space is a category.
        #expect(ItemRowText.secondLine(.detail, category: " ", createdAt: 0, count: nil)?.text == " ")
    }

    @Test("added reads Added …, the bare age after a lead, and the capitalised age alone")
    func addedLine() {
        let created = Self.now - 5 * Self.minute
        #expect(ItemRowText.secondLine(.added, category: nil, createdAt: created, count: nil, now: Self.now)?.text == "Added 5 minutes ago")
        #expect(ItemRowText.secondLine(.added, category: nil, createdAt: created, count: 3, now: Self.now)?.text == "×3 · 5 minutes ago")
        #expect(ItemRowText.secondLine(.added, category: nil, createdAt: Self.now, count: 3, now: Self.now)?.text == "×3 · just now")
        #expect(ItemRowText.secondLine(.added, category: nil, createdAt: Self.now, count: 1, now: Self.now)?.text == "Just now")
        #expect(ItemRowText.secondLine(.added, category: nil, createdAt: Self.now, count: 0, now: Self.now)?.text == "None left · just now")
        #expect(ItemRowText.secondLine(.added, category: nil, createdAt: created, count: 1, now: Self.now)?.text == "5 minutes ago")
    }

    @Test("only File and delete fold the count")
    func foldingTools() {
        #expect(ItemRowToolKind.file.foldsQuantity)
        #expect(ItemRowToolKind.delete.foldsQuantity)
        #expect(!ItemRowToolKind.chip.foldsQuantity)
        #expect(!ItemRowToolKind.stepper.foldsQuantity)
        #expect(!ItemRowToolKind.none.foldsQuantity)
    }

    @Test("the badge says nothing for one, ×N otherwise and None left at zero")
    func badge() {
        #expect(ItemRowText.badge(1) == nil)
        #expect(ItemRowText.badge(4) == QuantityBadgeText(text: "×4", isNoneLeft: false))
        #expect(ItemRowText.badge(0) == QuantityBadgeText(text: "None left", isNoneLeft: true))
        // The chip shows ×1 too, so there is always something to tap.
        #expect(ItemRowText.quantity(1).text == "×1")
        #expect(ItemRowText.quantity(12_000).text == "×12000")
    }

    @Test("the row speaks as one sentence")
    func rowLabel() {
        #expect(ItemRowText.accessibilityLabel(Self.item(), quantity: 3) == "Drill. In Garage, Tool chest, label C A B, J 9 2 R. Quantity 3.")
        #expect(ItemRowText.accessibilityLabel(Self.item(name: "  "), quantity: 0) == "Needs a name. In Garage, Tool chest, label C A B, J 9 2 R. None left.")
        let dropZone = Self.item(containerId: DropZone.containerId, containerName: "Drop zone")
        #expect(ItemRowText.accessibilityLabel(dropZone, quantity: 1) == "Drill. In the drop zone, not filed yet. Quantity 1.")
        #expect(ItemRowText.accessibilityHint == L10n.A11y.opensItem)
    }

    @Test("the chip, File and delete labels name the item")
    func toolLabels() {
        #expect(ItemRowText.chipAccessibilityLabel(name: "Wood screws", quantity: 3) == L10n.Quantity.chipA11y(name: "Wood screws", value: "3"))
        #expect(ItemRowText.chipAccessibilityLabel(name: "Wood screws", quantity: 0) == L10n.Quantity.chipA11y(name: "Wood screws", value: L10n.Quantity.noneLeftValue))
        #expect(ItemRowText.deleteAccessibilityLabel(name: "Drill") == L10n.Rows.deleteA11y(name: "Drill"))
        #expect(ItemRowText.deleteAccessibilityLabel(name: " ") == L10n.Rows.deletePhotoA11y)
        #expect(ItemRowText.fileAccessibilityLabel(name: "") == L10n.Rows.fileA11y(name: L10n.Entities.unnamedItem))
    }

    @Test("a 56 thumbnail shrinks to 48 beside a stepper or when stacked; 76 stays")
    func thumbSizes() {
        #expect(ItemRowText.thumbSize(56, small: false) == 56)
        #expect(ItemRowText.thumbSize(56, small: true) == 48)
        #expect(ItemRowText.thumbSize(76, small: true) == 76)
    }

    @Test("identifiers keep the RN testIDs")
    func identifiers() {
        #expect(ItemRowText.rowIdentifier("a") == "item-row-a")
        #expect(ItemRowText.chipIdentifier("a") == "qty-chip-a")
        #expect(ItemRowText.deleteIdentifier("a") == "review-delete-a")
        #expect(ItemRowText.fileIdentifier("a") == "drop-zone-file-a")
    }
}
