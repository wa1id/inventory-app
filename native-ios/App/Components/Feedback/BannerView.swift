import SwiftUI
import InventoryAppModels
import InventoryStrings

/// One of a banner's buttons (RN `BannerAction`).
struct BannerAction {
    let label: String
    var accessibilityHint: String?
    /// Busy: keeps its label, takes no presses, shows a spinner once the wait is real.
    var isLoading = false
    var identifier: String?
    let action: () -> Void
}

/// An inline notice (RN `Banner`, 06 §15.1).
///
/// Info is quiet; warning tints the icon and title in the signal colour on a faint red wash,
/// and the message stays primary. A banner with a secondary action draws the primary bordered so
/// the two are told apart; otherwise both are quiet. VoiceOver hears "<title>. <message>" when
/// the banner appears and whenever its words change, unless `live` is off (copy that follows
/// typing, the unpaired notice, the connection banner).
struct BannerView: View {
    enum Tone: Sendable {
        case info, warning
    }

    /// `card` draws its own rounded background (above a list, in a sheet); `row` leaves it to
    /// the list row it sits in.
    enum Chrome: Sendable {
        case card, row
    }

    let tone: Tone
    var glyph: Glyph?
    var title: String?
    let message: String
    var primary: BannerAction?
    var secondary: BannerAction?
    var onDismiss: (() -> Void)?
    var live: BannerLiveness = .polite
    var chrome: Chrome = .card
    var identifier: String?

    private let layout = LayoutScale()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(glyph: glyph ?? (tone == .warning ? .warning : .info))
                .font(.body)
                // An inline icon grows with the text up to 1.6 times (RN `inlineIconSize`).
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(tone == .warning ? DesignColor.signal : .primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if let title, !title.isEmpty {
                        Text(verbatim: title)
                            .textRole(.section)
                            .foregroundStyle(tone == .warning ? DesignColor.signal : .primary)
                    }
                    Text(verbatim: message)
                        .textRole(.meta)
                        .foregroundStyle(.primary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                if primary != nil || secondary != nil {
                    AdaptiveStack(horizontalAlignment: .leading, spacing: 8) {
                        if let primary {
                            button(primary, variant: secondary == nil ? .quiet : .secondary)
                        }
                        if let secondary {
                            button(secondary, variant: .quiet)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(glyph: .close)
                        .frame(minWidth: DesignMetrics.minTouchTarget, minHeight: DesignMetrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(verbatim: L10n.Common.dismiss))
                .padding(.top, -12)
                .padding(.trailing, -8)
            }
        }
        .padding(chrome == .card ? 14 : 0)
        .background {
            if chrome == .card {
                RoundedRectangle(cornerRadius: DesignMetrics.cardRadius, style: .continuous)
                    .fill(tone == .warning ? DesignColor.signalWash : Color(uiColor: .tertiarySystemFill))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifierIfPresent(identifier)
        .announcesOnChange(FeedbackText.bannerAnnouncement(title: title, message: message), enabled: live.announces)
    }

    private func button(_ action: BannerAction, variant: ButtonVariant) -> some View {
        LoadingButton(
            label: action.label,
            variant: variant,
            size: .small,
            isLoading: action.isLoading,
            accessibilityHint: action.accessibilityHint,
            identifier: action.identifier,
            action: action.action
        )
    }
}

/// The photo suggestion banner (RN `SuggestionBanner`, 06 §15.4, 05 §11.2): sparkles while
/// recognition runs or after it filled the form, a pencil when it failed. The stale state is
/// never announced: its copy follows the name field keystroke by keystroke.
struct SuggestionBannerView: View {
    /// What the banner shows: `AddSheetModel.suggestionBanner` (stale already derived).
    let state: SuggestionState
    var onRetry: (() -> Void)?
    /// Re-derives the other details from the name now in the form.
    var onRefresh: (() -> Void)?
    var chrome: BannerView.Chrome = .card

    var body: some View {
        if let copy = state.bannerCopy {
            BannerView(
                tone: .info,
                glyph: copy.isFailure ? .edit : .sparkle,
                title: copy.title,
                message: copy.message,
                primary: action(for: copy),
                live: copy.announced ? .polite : .off,
                chrome: chrome,
                identifier: "suggestion-banner"
            )
        }
    }

    private func action(for copy: SuggestionBannerCopy) -> BannerAction? {
        switch copy.action {
        case .retry?:
            onRetry.map { BannerAction(label: SuggestionBannerCopy.Action.retry.label, action: $0) }
        case .update?:
            onRefresh.map { BannerAction(label: SuggestionBannerCopy.Action.update.label, accessibilityHint: SuggestionBannerCopy.Action.update.hint, action: $0) }
        case nil:
            nil
        }
    }
}

#Preview("Banners") {
    ScrollView {
        VStack(spacing: 12) {
            BannerView(tone: .info, title: "Not saved", message: "Check the connection and try again.", primary: BannerAction(label: "Try again") {})
            BannerView(
                tone: .warning,
                title: "Could not reach the home server",
                message: "What you typed is still here.",
                primary: BannerAction(label: "Join") {},
                secondary: BannerAction(label: "Not now") {},
                onDismiss: {}
            )
            SuggestionBannerView(state: .running)
            SuggestionBannerView(state: .applied(confidence: 0.9, forName: "Drill"))
            SuggestionBannerView(state: .stale(forName: "Angle grinder"), onRefresh: {})
            SuggestionBannerView(state: .failed(.offline), onRetry: {})
        }
        .padding()
    }
}
