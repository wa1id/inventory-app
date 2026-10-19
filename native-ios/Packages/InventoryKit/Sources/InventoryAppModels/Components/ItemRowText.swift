import InventoryCore
import InventoryStrings

// RN: src/ui/components/ItemRow.tsx and QuantityChip.tsx. What an item row says, without its
// drawing: the second line and its quantity fold, the badges and every spoken label (06 §15.2).

/// What an item row's second line shows (RN `ItemRowProps.line`).
public enum ItemRowLine: Sendable, Hashable {
    /// Where the item is: pip, "Space › Container", label tape (the default).
    case `where`
    /// Its category.
    case detail
    /// When it was added ("Added 5 minutes ago"): the drop zone's list.
    case added
}

/// The control at the end of an item row (RN `ItemRowProps.tool`).
public enum ItemRowToolKind: Sendable, Hashable {
    /// The quantity chip that opens a large stepper under the row (the default).
    case chip
    /// A compact stepper that writes through.
    case stepper
    /// "File…" (the drop zone).
    case file
    /// A trash button (the Quick Snap review).
    case delete
    /// Nothing but a "×4" badge.
    case none

    /// Beside "File…" or a delete the count joins the second line, so the name keeps the width
    /// (RN `folded`, ItemRow.tsx:244).
    public var foldsQuantity: Bool { self == .file || self == .delete }
}

/// A count as the rows write it: "×4", or "None left" in the signal colour at zero.
public struct QuantityBadgeText: Sendable, Hashable {
    public var text: String
    /// Drawn in the signal (red) colour.
    public var isNoneLeft: Bool

    public init(text: String, isNoneLeft: Bool) {
        self.text = text
        self.isNoneLeft = isNoneLeft
    }
}

/// An item row's second line when it is not the location (RN `SecondLine`, ItemRow.tsx:75-110).
public struct ItemRowSecondLineText: Sendable, Hashable {
    /// The folded count in front: "×3" or "None left"; nil for one, or when nothing is folded.
    public var lead: QuantityBadgeText?
    /// The category, or when the item was added.
    public var rest: String?

    /// The line as one string, the parts joined by `L10n.Rows.separator` (" · ").
    public var text: String {
        [lead?.text, rest].compactMap { $0 }.joined(separator: L10n.Rows.separator)
    }
}

/// The words and identifiers of an item row (RN ItemRow.tsx, QuantityChip.tsx).
public enum ItemRowText {
    /// The item's name, or "Needs a name" when it has none (RN `displayName`).
    public static func displayName(_ name: String) -> String {
        isUnnamed(name) ? L10n.Entities.unnamedItem : name
    }

    /// A blank or white-space name is unnamed (RN `!item.name.trim()`).
    public static func isUnnamed(_ name: String) -> Bool {
        !EntityText.hasText(name)
    }

    /// "×4", or "None left" at zero. "×1" too: the chip always has something to tap.
    public static func quantity(_ quantity: Int) -> QuantityBadgeText {
        quantity == 0
            ? QuantityBadgeText(text: L10n.Rows.noneLeft, isNoneLeft: true)
            : QuantityBadgeText(text: L10n.Rows.times(count: quantity), isNoneLeft: false)
    }

    /// The badge beside a row without a quantity control: nothing for one, as on the desk
    /// (RN `QuantityBadge`).
    public static func badge(_ quantity: Int) -> QuantityBadgeText? {
        quantity == 1 ? nil : self.quantity(quantity)
    }

    /// The second line for `detail` and `added` rows, or nil for `where` (the location line)
    /// and when there is nothing to say (RN `SecondLine`).
    ///
    /// - `lead`: nothing when `count` is nil (not folded) or 1, else "×N" or "None left".
    /// - `rest`: the category for `detail`; for `added`, "Added 5 minutes ago" when nothing is
    ///   folded, the bare "5 minutes ago" after a lead, and "5 minutes ago" capitalised
    ///   ("Just now") when folded without a lead.
    ///
    /// - Parameters:
    ///   - count: the quantity folded into the line (rows whose end holds "File…" or a delete),
    ///     or nil.
    ///   - now: epoch ms the age counts from; the current time when nil.
    public static func secondLine(
        _ line: ItemRowLine,
        category: String?,
        createdAt: Int64,
        count: Int?,
        now: Int64? = nil
    ) -> ItemRowSecondLineText? {
        if line == .where { return nil }
        let lead: QuantityBadgeText? = count.flatMap { $0 == 1 ? nil : quantity($0) }
        let rest: String?
        switch line {
        case .detail:
            // JS truthiness: an empty category says nothing; " " still shows.
            rest = category.flatMap { $0.isEmpty ? nil : $0 }
        case .added, .where:
            let when = now.map { Format.ago(createdAt, now: $0) } ?? Format.ago(createdAt)
            if count == nil {
                rest = L10n.Rows.added(ago: when)
            } else if lead != nil {
                rest = when
            } else {
                rest = L10n.Rows.addedShort(ago: when)
            }
        }
        if lead == nil && rest == nil { return nil }
        return ItemRowSecondLineText(lead: lead, rest: rest)
    }

    /// The row as one sentence: "Drill. In Garage, Tool chest, label C A B, J 9 2 R. Quantity 3."
    /// (RN `rowLabel`).
    public static func accessibilityLabel(_ item: ItemWithContext, quantity: Int) -> String {
        L10n.Rows.itemA11y(name: displayName(item.name), where: whereSpoken(item), quantity: quantitySpoken(quantity))
    }

    /// "Opens the item."
    public static var accessibilityHint: String { L10n.A11y.opensItem }

    /// The chip: "Wood screws, quantity 3" or "…, none left" (RN `QuantityChip`).
    public static func chipAccessibilityLabel(name: String, quantity: Int) -> String {
        L10n.Quantity.chipA11y(name: name, value: quantity == 0 ? L10n.Quantity.noneLeftValue : String(quantity))
    }

    /// "Opens plus and minus under the row" (RN `strings.quantity.chipHint`).
    public static var chipAccessibilityHint: String { L10n.Quantity.chipHint }

    /// The trash button: "Delete Wood screws", or "Delete this photo" for an unnamed item.
    public static func deleteAccessibilityLabel(name: String) -> String {
        isUnnamed(name) ? L10n.Rows.deletePhotoA11y : L10n.Rows.deleteA11y(name: displayName(name))
    }

    /// The "File…" button: "File Wood screws…".
    public static func fileAccessibilityLabel(name: String) -> String {
        L10n.Rows.fileA11y(name: displayName(name))
    }

    /// The thumbnail: 48 beside a stepper or in the stacked layout when the row asked for 56;
    /// 76 stays 76 (RN `thumbSize`).
    public static func thumbSize(_ thumb: Int, small: Bool) -> Int {
        thumb == 56 && small ? 48 : thumb
    }

    /// `item-row-<id>`: the row's UI-test identifier.
    public static func rowIdentifier(_ id: String) -> String { "item-row-\(id)" }
    /// `qty-chip-<id>`.
    public static func chipIdentifier(_ id: String) -> String { "qty-chip-\(id)" }
    /// `review-delete-<id>`.
    public static func deleteIdentifier(_ id: String) -> String { "review-delete-\(id)" }
    /// `drop-zone-file-<id>`.
    public static func fileIdentifier(_ id: String) -> String { "drop-zone-file-\(id)" }
}
