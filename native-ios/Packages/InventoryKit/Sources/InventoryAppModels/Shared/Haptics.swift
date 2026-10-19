/// Every haptic the app plays, named for the moment it marks so the same moment always feels
/// the same (RN `haptics`, src/ui/haptics.ts; call sites in 08 §7.2).
///
/// Models emit these through an injected ``HapticPlayer``; the app target plays them with
/// UIKit feedback generators (``feedback`` says which), so InventoryKit stays free of UIKit.
/// Playing is fire-and-forget and never fails into the caller.
///
/// There is no haptic on successful deletes, on navigation, on toasts, on a successful edit of
/// an existing record, on an unbound scanned label or on a successful backup (08 §7.2).
public enum HapticEvent: String, Sendable, Hashable, CaseIterable {
    /// Stepper ± tap (every 5th step during hold-repeat). Not when the value did not change.
    case step
    /// Stepper reached 0, "None left": a heavier tick than a plain step; replaces `step`.
    case reachedZero
    /// A choice changed: place, space, type, colour, icon, segment; search cleared.
    /// Only when the option was not already selected (except the Add form's place entries).
    case choice
    /// Undo applied.
    case undo
    /// Add, Move, File, label linked, joined, QR recognised, restore succeeded.
    case success
    /// A conflict (409) shown to the person.
    case warning
    /// A failed write, an invalid QR, a quantity that did not save.
    case error
    /// Add block pressed; fast-mode shot returned (before the item is saved).
    case tap
    /// Add block long-pressed (Quick Snap): distinct from a plain tap. Not when a system
    /// context menu already played its own.
    case longPress

    /// The feedback generator call RN made for this event through expo-haptics.
    public var feedback: HapticFeedback {
        switch self {
        case .step, .choice, .undo: .selection
        case .reachedZero, .tap: .impact(.light)
        case .longPress: .impact(.medium)
        case .success: .notification(.success)
        case .warning: .notification(.warning)
        case .error: .notification(.error)
        }
    }
}

/// A UIKit feedback generator call, without UIKit (08 §7.1).
public enum HapticFeedback: Sendable, Hashable {
    /// `UISelectionFeedbackGenerator().selectionChanged()` (expo `selectionAsync`).
    case selection
    /// `UIImpactFeedbackGenerator(style:).impactOccurred()` (expo `impactAsync`).
    case impact(ImpactStyle)
    /// `UINotificationFeedbackGenerator().notificationOccurred(_:)` (expo `notificationAsync`).
    case notification(NotificationType)

    /// `UIImpactFeedbackGenerator.FeedbackStyle`; RN uses only these two.
    public enum ImpactStyle: String, Sendable, Hashable {
        case light, medium
    }

    /// `UINotificationFeedbackGenerator.FeedbackType`.
    public enum NotificationType: String, Sendable, Hashable {
        case success, warning, error
    }
}

/// Plays a haptic. Models take one through their initialiser (`{ _ in }` in tests that do not
/// care, a recorder in tests that do); the app target passes one that drives the generators.
public typealias HapticPlayer = @MainActor @Sendable (HapticEvent) -> Void
