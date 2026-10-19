import InventoryCore
import InventoryNetwork
import InventoryStrings

/// Where photo recognition stands for the Add sheet (RN `SuggestionState`,
/// src/ui/components/SuggestionBanner.tsx:5-19).
///
/// `forName` is the name the rest of the suggestion was derived from: the one suggested, or
/// the one the person corrected it to on the last refresh. `stale` is never stored: the sheet
/// derives it on every keystroke with ``staleName(typed:)`` and shows ``banner(typed:)``.
public enum SuggestionState: Sendable, Hashable {
    case idle
    case running
    case applied(confidence: Double, forName: String)
    /// The name was edited since the details were derived; they describe the old guess.
    case stale(forName: String)
    case refreshing
    case refreshed(forName: String)
    case failed(RecognitionFailureReason)

    /// Recognition is under way (`running` or `refreshing`): a draft cut off here restarts it.
    public var isInFlight: Bool {
        switch self {
        case .running, .refreshing: true
        default: false
        }
    }

    /// The name the supporting details no longer describe, or nil when they still do
    /// (RN `staleSuggestionName`).
    ///
    /// Only an applied or refreshed suggestion can go stale. The typed name is trimmed; empty,
    /// or exactly `forName` (code units, case-sensitive), is not stale.
    public func staleName(typed typedName: String) -> String? {
        let forName: String
        switch self {
        case .applied(_, let name), .refreshed(let name): forName = name
        default: return nil
        }
        let typed = typedName.jsTrimmed()
        if typed.isEmpty || EntityText.same(typed, forName) { return nil }
        return typed
    }

    /// What the banner shows for this state with `typed` in the name field: `stale(typed)` when
    /// the name drifted, else the state itself (RN `app/item/new.tsx:715`).
    public func banner(typed typedName: String) -> SuggestionState {
        staleName(typed: typedName).map { .stale(forName: $0) } ?? self
    }

    /// The banner's copy for this state; nil for `idle`, which shows no banner
    /// (RN `SuggestionBanner`, :45-130; 05 §11.2).
    public var bannerCopy: SuggestionBannerCopy? {
        switch self {
        case .idle:
            nil
        case .running:
            SuggestionBannerCopy(title: nil, message: L10n.Suggestions.running, action: nil, announced: true, isFailure: false)
        case .refreshing:
            SuggestionBannerCopy(title: nil, message: L10n.Suggestions.refreshing, action: nil, announced: true, isFailure: false)
        case .applied:
            SuggestionBannerCopy(title: L10n.Suggestions.applied, message: L10n.Suggestions.check, action: nil, announced: true, isFailure: false)
        case .refreshed(let name):
            SuggestionBannerCopy(title: L10n.Suggestions.refreshed(name: name), message: L10n.Suggestions.check, action: nil, announced: true, isFailure: false)
        case .stale(let name):
            SuggestionBannerCopy(
                title: L10n.Suggestions.stale(name: name),
                message: L10n.Suggestions.staleBody,
                action: .update,
                announced: false,
                isFailure: false
            )
        case .failed(let reason):
            SuggestionBannerCopy(
                title: L10n.Suggestions.failed,
                message: Self.failedBody(reason),
                action: reason == .notConfigured ? nil : .retry,
                announced: true,
                isFailure: true
            )
        }
    }

    /// `strings.suggestions.failedBody[reason]`.
    static func failedBody(_ reason: RecognitionFailureReason) -> String {
        switch reason {
        case .notConfigured: L10n.Suggestions.FailedBody.not_configured
        case .offline: L10n.Suggestions.FailedBody.offline
        case .timeout: L10n.Suggestions.FailedBody.timeout
        case .rateLimited: L10n.Suggestions.FailedBody.rate_limited
        case .serverError: L10n.Suggestions.FailedBody.server_error
        case .malformedResponse: L10n.Suggestions.FailedBody.malformed_response
        case .unsupportedVersion: L10n.Suggestions.FailedBody.unsupported_version
        case .lowConfidence: L10n.Suggestions.FailedBody.low_confidence
        case .unrecognized: L10n.Suggestions.FailedBody.unrecognized
        }
    }
}

/// What the suggestion banner says (RN `SuggestionBanner` render; 06 §15.4).
public struct SuggestionBannerCopy: Sendable, Hashable {
    /// The banner's one button.
    public enum Action: Sendable, Hashable {
        /// `L10n.Suggestions.retry`: run recognition again, anchored to the typed name.
        case retry
        /// `L10n.Suggestions.update` (hint `L10n.Suggestions.updateHint`): refresh the details
        /// for the typed name, replacing category and tags.
        case update

        public var label: String {
            switch self {
            case .retry: L10n.Suggestions.retry
            case .update: L10n.Suggestions.update
            }
        }

        public var hint: String? {
            switch self {
            case .retry: nil
            case .update: L10n.Suggestions.updateHint
            }
        }
    }

    public var title: String?
    public var message: String
    public var action: Action?
    /// Announced to VoiceOver when it appears; never for `stale`, which would talk over typing.
    public var announced: Bool
    /// The failure look (the edit glyph instead of the sparkle).
    public var isFailure: Bool
}
