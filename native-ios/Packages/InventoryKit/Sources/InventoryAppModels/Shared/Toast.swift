/// How a toast reads (RN `ToastOptions.tone`, src/providers/ToastProvider.tsx).
public enum ToastTone: String, Sendable, Hashable {
    /// The default.
    case info
    /// Alert role, a leading signal bar, and at least 1.5 s on screen before anything replaces it.
    case error
}

/// The one button a toast may carry, usually Undo (RN `ToastAction`).
public struct ToastAction: Sendable {
    /// The visible label: "Undo".
    public var label: String
    /// Item-specific where it helps: "Undo moving Cordless drill". VoiceOver reads ``label``
    /// when this is nil.
    public var accessibilityLabel: String?
    /// Runs at most once, on the main actor; the toast then goes away.
    public var handler: @MainActor @Sendable () -> Void

    public init(label: String, accessibilityLabel: String? = nil, handler: @escaping @MainActor @Sendable () -> Void) {
        self.label = label
        self.accessibilityLabel = accessibilityLabel
        self.handler = handler
    }
}

/// What to show in a toast (RN `ToastOptions`).
///
/// Toasts report writes that finished somewhere the person is no longer looking: "Moved to
/// Tool chest (Garage)" with Undo after a move sheet closes, or a quantity that did not save
/// in a row of a long list (09 §4.6).
public struct ToastOptions: Sendable {
    public var message: String
    public var tone: ToastTone
    public var action: ToastAction?
    /// Overrides the default life (``baseDuration``). No RN caller passes one.
    public var duration: Duration?

    public init(message: String, tone: ToastTone = .info, action: ToastAction? = nil, duration: Duration? = nil) {
        self.message = message
        self.tone = tone
        self.action = action
        self.duration = duration
    }

    /// How long the toast stays before VoiceOver doubling: `duration`, else
    /// `Motion.delay.toastWithAction` (9 s) with an action or `Motion.delay.toast` (5 s)
    /// without (RN `record.duration ?? (record.action ? delay.toastWithAction : delay.toast)`,
    /// ToastProvider.tsx:164).
    public var baseDuration: Duration {
        duration ?? .milliseconds(action == nil ? Motion.delay.toast : Motion.delay.toastWithAction)
    }
}

/// Shows and dismisses toasts (RN `useToast()`: `{ show, dismiss }`).
///
/// `ToastCenter` conforms; models take `any ToastPresenting` so tests can record what they
/// showed.
@MainActor
public protocol ToastPresenting: AnyObject {
    /// Shows a toast (or queues it behind an error that has not been up 1.5 s yet) and returns
    /// its id, `"toast-N"`.
    @discardableResult
    func show(_ options: ToastOptions) -> String

    /// Takes the toast with this id away, or drops it if it is still waiting. Unknown ids are ignored.
    func dismiss(_ id: String)
}
