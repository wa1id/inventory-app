import InventoryCore
import InventoryNetwork
import InventoryStrings

// RN: src/ui/components/ItemForm.tsx:12-114. The item form's values and its two pure rules:
// validating what was typed, and folding a photo suggestion into it.

/// What the item form holds, every field as typed (RN `ItemFormValues`).
///
/// `tags` is the raw comma-separated text; `quantity` is the text of the number field.
public struct ItemFormValues: Sendable, Hashable {
    public var name: String
    public var category: String
    public var tags: String
    public var quantity: String
    public var notes: String

    public init(name: String = "", category: String = "", tags: String = "", quantity: String = "1", notes: String = "") {
        self.name = name
        self.category = category
        self.tags = tags
        self.quantity = quantity
        self.notes = notes
    }

    /// A new item: everything blank, quantity "1" (RN `EMPTY_ITEM_FORM`).
    public static let empty = ItemFormValues()
}

/// What validation complains about, both at once so nothing is lost between attempts
/// (RN `ItemFormErrors`).
public struct ItemFormErrors: Sendable, Hashable {
    /// `L10n.Forms.itemNameRequired` when the trimmed name is empty.
    public var name: String?
    /// `L10n.Forms.quantityInvalid` when the quantity is not a whole number of 0 or more.
    public var quantity: String?

    public init(name: String? = nil, quantity: String? = nil) {
        self.name = name
        self.quantity = quantity
    }

    public var isEmpty: Bool { name == nil && quantity == nil }
}

/// Validated values ready for the repository (RN `ParsedItemForm`).
public struct ParsedItemForm: Sendable, Hashable {
    /// Trimmed, never empty.
    public var name: String
    /// Trimmed, or nil when blank.
    public var category: String?
    /// Split on commas, each trimmed, blanks dropped.
    public var tags: [String]
    public var quantity: Int
    /// Trimmed, or nil when blank.
    public var notes: String?

    public init(name: String, category: String?, tags: [String], quantity: Int, notes: String?) {
        self.name = name
        self.category = category
        self.tags = tags
        self.quantity = quantity
        self.notes = notes
    }
}

/// The item form's rules (RN `src/ui/components/ItemForm.tsx`).
public enum ItemForm {
    /// Validates the form without discarding anything typed (RN `validateItemForm`).
    ///
    /// Returns every error together with the parsed values; `parsed` is nil whenever there is
    /// an error, so a recoverable failure is shown inline while the typing stays on screen.
    public static func validate(_ values: ItemFormValues) -> (errors: ItemFormErrors, parsed: ParsedItemForm?) {
        var errors = ItemFormErrors()
        let name = values.name.jsTrimmed()
        if name.isEmpty { errors.name = L10n.Forms.itemNameRequired }
        let quantity = parseQuantityInput(values.quantity)
        if quantity == nil { errors.quantity = L10n.Forms.quantityInvalid }
        guard errors.isEmpty, let quantity else { return (errors, nil) }
        return (
            errors,
            ParsedItemForm(
                name: name,
                category: blankToNil(values.category.jsTrimmed()),
                tags: tagList(values.tags),
                quantity: quantity,
                notes: blankToNil(values.notes.jsTrimmed())
            )
        )
    }

    /// Folds a photo suggestion into the form (RN `applySuggestion`).
    ///
    /// - `overwrite: false`, the first answer: fills only blank fields, so a suggestion
    ///   landing while someone types never takes a field back.
    /// - `overwrite: true`, an explicit refresh after the name was corrected: category and
    ///   tags are replaced, even with blanks, because they described the rejected guess.
    ///
    /// The name is never taken once the field holds anything, even white space (JS `||` on the
    /// raw string); quantity and notes are never touched.
    public static func applySuggestion(
        _ current: ItemFormValues,
        _ suggestion: RecognitionSuggestion,
        overwrite: Bool = false
    ) -> ItemFormValues {
        let tags = suggestion.tags.joined(separator: ", ")
        var next = current
        next.name = current.name.isEmpty ? (suggestion.name ?? "") : current.name
        if overwrite {
            next.category = suggestion.category ?? ""
            next.tags = tags
        } else {
            next.category = current.category.isEmpty ? (suggestion.category ?? "") : current.category
            next.tags = current.tags.isEmpty ? tags : current.tags
        }
        return next
    }

    /// The typed tags as the repository takes them: split on commas, trimmed, blanks dropped.
    public static func tagList(_ text: String) -> [String] {
        EntityText.splitOnComma(text).map { $0.jsTrimmed() }.filter { !$0.isEmpty }
    }

    private static func blankToNil(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}
