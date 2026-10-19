import InventoryCore

/// Why a save did not happen, in plain words for a form's warning banner (RN `SaveNotice`,
/// src/ui/spaces/FormLayout.tsx:64-78; 07 §4.14).
///
/// The title is the described title, except for a local failure, whose body ("It was not
/// saved. Try again.") says it all. The banner is assertive. Raw messages never show.
public struct SaveNoticeCopy: Sendable, Hashable {
    public var kind: ErrorKind
    public var title: String?
    public var message: String

    /// - Parameters:
    ///   - cause: what the save threw, or nil when the record turned out to be gone.
    ///   - subject: what the form saves; a gone container says so even from the Add sheet,
    ///     where a 404 on create means the container went.
    public init(cause: (any Error)?, subject: ErrorSubject) {
        let described = describeError(cause, context: .save, subject: subject)
        kind = described.kind
        title = described.kind == .local ? nil : described.title
        message = described.body
    }
}
