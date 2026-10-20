/// What Home's search field does that the stock `.searchable` field cannot say by itself
/// (RN src/ui/components/SearchField.tsx; 06 §5.3).
public enum HomeSearchFieldRules {
    /// The field was emptied in one step from two or more characters: the clear button (RN's
    /// own clear button played `choice`, SearchField.tsx:61-65). Deleting the last character
    /// is typing, not clearing, and plays nothing. The stock field does not report its clear
    /// button, so this is how Home tells.
    public static func isClear(from old: String, to new: String) -> Bool {
        new.isEmpty && old.utf16.count > 1
    }
}
