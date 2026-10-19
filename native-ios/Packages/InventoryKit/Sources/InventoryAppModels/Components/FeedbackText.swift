import InventoryCore
import InventoryStrings

// RN: src/ui/components/Banner.tsx, ErrorState.tsx, Skeleton.tsx and SettingsRow.tsx. The words
// the feedback components speak (06 §15.1, §17; 08 §9.2).

/// How a banner announces itself (RN `BannerProps.live`).
public enum BannerLiveness: Sendable, Hashable {
    /// Announced when it appears and when its words change (the default).
    case polite
    /// The same on iOS: VoiceOver has no live regions, so both interrupt.
    case assertive
    /// Never announced: copy that follows typing, the unpaired notice, the connection banner.
    case off

    public var announces: Bool { self != .off }
}

/// The words of the feedback components.
public enum FeedbackText {
    /// What a banner announces: "<title>. <message>", or the message alone (RN `Banner`).
    public static func bannerAnnouncement(title: String?, message: String) -> String {
        if let title, !title.isEmpty { return "\(title). \(message)" }
        return message
    }

    /// An error state's heading and body: the described words, unless the screen gives its
    /// own (RN `ErrorState`). `nil` cause reads as gone, as a read that found nothing.
    public static func errorState(
        cause: (any Error)?,
        context: ErrorContext = .read,
        subject: ErrorSubject = .list,
        title: String? = nil,
        body: String? = nil
    ) -> (title: String, body: String) {
        let described = describeError(cause, context: context, subject: subject)
        return (title ?? described.title, body ?? described.body)
    }

    /// "Loading…": a skeleton's one spoken label unless the screen names what loads.
    public static var loading: String { L10n.A11y.loading }

    /// A settings row's label with its value, so the state is heard before opening:
    /// "Household, Joined as Walid's iPhone" (RN `SettingsRow`).
    public static func settingsAccessibilityLabel(label: String, value: String?) -> String {
        guard let value, !value.isEmpty else { return label }
        return "\(label), \(value)"
    }
}
