import InventoryCore
import InventoryStrings

// RN: src/ui/components/TextField.tsx, CodeInput.tsx and QuantityStepper.tsx. The spoken labels
// and visible helper text of the form fields (07 §4.7, §4.10).

/// What a labelled text field says (RN `TextField`).
public enum TextFieldCopy {
    /// The field's spoken label: the label (or its spoken override), then ", required" and
    /// ", error: …" when they apply. "Required" is announced, never drawn.
    public static func spokenLabel(label: String, accessibilityLabel: String? = nil, required: Bool, error: String?) -> String {
        [
            accessibilityLabel ?? label,
            required ? L10n.Forms.required : nil,
            error.flatMap { $0.isEmpty ? nil : L10n.Forms.errorA11y(error: $0) },
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    /// What VoiceOver hears when an error appears (queued behind what it is reading).
    public static func errorAnnouncement(_ error: String) -> String {
        L10n.Forms.errorA11y(error: error)
    }

    /// " (optional)" after an optional field's label.
    public static var optionalSuffix: String { L10n.Forms.optional }
}

/// A household or recovery code as the code field shows it (RN `CodeInput`, 03 §3.5).
public enum CodeFieldText {
    /// What the field shows: groups of five joined by hyphens.
    public static func display(_ normalised: String) -> String {
        formatCode(normalised)
    }

    /// What every change stores: no spaces or hyphens, upper case, `I`/`L` → 1, `O` → 0. Never
    /// cut to the expected length; validity is the screen's call on submit.
    public static func normalise(_ typed: String) -> String {
        normaliseCode(typed)
    }

    /// "12 of 26 characters" (counted in UTF-16 units, as JS `length`).
    public static func counter(_ normalised: String, length: Int = codeLength) -> String {
        L10n.Forms.codeCounter(count: normalised.utf16.count, total: length)
    }

    /// The counter on the label row: only once there is something to count.
    public static func visibleCounter(_ normalised: String, length: Int = codeLength) -> String? {
        normalised.isEmpty ? nil : counter(normalised, length: length)
    }

    /// Whether typed text holds a line break: Return closes the keyboard and submits, it never
    /// adds a line.
    public static func isSubmit(_ typed: String) -> Bool {
        typed.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
    }
}

/// What the quantity stepper says (RN `QuantityStepper`).
public enum QuantityStepperCopy {
    /// "Increase quantity of Wood screws", or the plain form without a name.
    public static func increaseLabel(itemName: String?) -> String {
        itemName.map { L10n.Quantity.increase(name: $0) } ?? L10n.Quantity.increasePlain
    }

    /// "Decrease quantity of Wood screws", or the plain form without a name.
    public static func decreaseLabel(itemName: String?) -> String {
        itemName.map { L10n.Quantity.decrease(name: $0) } ?? L10n.Quantity.decreasePlain
    }

    /// The adjustable element's label: "Quantity of Wood screws", or "Quantity".
    public static func fieldLabel(itemName: String?) -> String {
        itemName.map { L10n.Quantity.field(name: $0) } ?? L10n.Quantity.fieldPlain
    }

    /// The adjustable element's value: "None left" at zero, else the number.
    public static func valueText(_ value: Int) -> String {
        value <= minQuantity ? L10n.Rows.noneLeft : String(value)
    }

    /// `quantity-decrease[-suffix]`, `quantity-input[-suffix]`, `quantity-increase[-suffix]`: bare
    /// on the item screen and the Add form, suffixed by the item id in lists.
    public static func identifier(_ part: String, suffix: String?) -> String {
        suffix.map { "quantity-\(part)-\($0)" } ?? "quantity-\(part)"
    }
}
