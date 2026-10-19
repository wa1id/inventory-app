import InventoryStrings
import Observation

/// Asks before a form with unsaved typing closes (RN `useDirtyGuard`,
/// src/hooks/useDirtyGuard.ts:27-67; 07 §4.16).
///
/// The screen keeps ``dirty``, ``saving`` and ``revoked`` current. While the form is dirty
/// and not saving, a close (Cancel, back) asks "Discard your changes?" first; the sheet's
/// swipe-down is off while it is dirty or saving (``interactiveDismissDisabled``). While a
/// save is in flight the guard does not ask, so a save that closes the form never asks. While
/// the removed-phone layer is up (``revoked``) there is nothing to keep editing, so the layer
/// closing every sheet is never asked about.
///
/// Used by Edit details and the space and container forms; the Add sheet keeps a draft instead.
@MainActor
@Observable
public final class DirtyGuard {
    /// The form holds changes worth asking about.
    public var dirty: Bool
    /// A write is in flight.
    public var saving: Bool
    /// The phone was removed from the household (`ConnectionModel` state `revoked`).
    public var revoked: Bool

    @ObservationIgnored private let confirmPresenter: any ConfirmPresenting
    @ObservationIgnored private let title: String?

    /// - Parameter title: the question, "Discard your changes?" unless given.
    public init(
        confirm: any ConfirmPresenting,
        title: String? = nil,
        dirty: Bool = false,
        saving: Bool = false,
        revoked: Bool = false
    ) {
        confirmPresenter = confirm
        self.title = title
        self.dirty = dirty
        self.saving = saving
        self.revoked = revoked
    }

    /// Whether a close is intercepted with the discard question (RN `guarded`).
    public var guarded: Bool { dirty && !saving && !revoked }

    /// Whether the sheet's swipe-down is off (RN `gestureEnabled: !(dirty || saving)`).
    public var interactiveDismissDisabled: Bool { dirty || saving }

    /// The question a guarded close asks.
    public var confirmOptions: ConfirmOptions {
        ConfirmOptions(
            title: title ?? L10n.Forms.discardTitle,
            body: L10n.Forms.discardBody,
            confirmLabel: L10n.Forms.discard,
            cancelLabel: L10n.Forms.keepEditing
        )
    }

    /// Call when the person tries to close the form. Returns true when it may close: at once
    /// when not guarded, else after "Discard" (running `onDiscard` first, for example to drop
    /// a photo nobody kept); false after "Keep editing".
    public func attemptClose(onDiscard: (@MainActor () -> Void)? = nil) async -> Bool {
        guard guarded else { return true }
        guard await confirmPresenter.confirm(confirmOptions) else { return false }
        onDiscard?()
        return true
    }
}
