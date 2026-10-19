import InventoryStrings

/// What a confirmation asks before something that cannot be taken back (RN `ConfirmOptions`,
/// src/ui/confirm.ts).
///
/// Reserved for deletes, replacing or removing a label, restoring a backup, leaving or
/// importing into the household and discarding a dirty form. Moves, files and adds use Undo
/// instead; quantities, names and edits use neither. The plans that may need one carry it as
/// this value: scanRules' `planBind` (replacing a container's label), containerRules'
/// `planSticker` (moving or replacing a sticker; RN's `ConfirmCopy` is these options with the
/// defaults), and `useDirtyGuard` ("Discard your changes?" with "Keep editing").
///
/// RN shows it as an alert: Cancel (cancel style) first, then the confirm button, destructive
/// unless `destructive` is false; dismissing it counts as Cancel.
public struct ConfirmOptions: Sendable, Hashable {
    /// A question: "Delete “Cordless drill”?"
    public var title: String
    /// The impact, and what stays: "This cannot be undone."
    public var body: String
    public var confirmLabel: String
    /// `L10n.Common.cancel` ("Cancel") unless given; a dirty form says "Keep editing".
    public var cancelLabel: String
    /// Draws the confirm button as destructive. True unless given: most confirms are deletes.
    public var destructive: Bool

    public init(
        title: String,
        body: String,
        confirmLabel: String,
        cancelLabel: String = L10n.Common.cancel,
        destructive: Bool = true
    ) {
        self.title = title
        self.body = body
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
        self.destructive = destructive
    }
}

/// Asks a confirmation and waits for the answer (RN `confirm(options): Promise<boolean>`).
///
/// The app target conforms with a presenter that shows the alert; models take
/// `any ConfirmPresenting` and tests answer with a script.
@MainActor
public protocol ConfirmPresenting: AnyObject {
    /// True only when the person pressed the confirm button; false on Cancel and when the
    /// dialog was dismissed any other way.
    func confirm(_ options: ConfirmOptions) async -> Bool
}
