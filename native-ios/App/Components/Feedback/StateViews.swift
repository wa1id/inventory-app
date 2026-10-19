import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// One of an empty or error state's buttons.
struct StateAction {
    let label: String
    var glyph: Glyph?
    var isLoading = false
    var identifier: String?
    let action: () -> Void
}

/// Why a list is empty and what to do next (RN `EmptyState`, 06 §15.1 and Q6).
///
/// A stock `ContentUnavailableView`. The primary action is the filled button; a secondary one is
/// quiet under a primary and bordered when it is the only next step.
struct EmptyStateView: View {
    let title: String
    let message: String
    var glyph: Glyph?
    var primary: StateAction?
    var secondary: StateAction?
    var identifier: String?

    var body: some View {
        ContentUnavailableView {
            if let glyph {
                Label(title, glyph: glyph)
            } else {
                Text(verbatim: title)
            }
        } description: {
            Text(verbatim: message)
        } actions: {
            if let primary {
                button(primary, variant: .primary)
            }
            if let secondary {
                button(secondary, variant: primary == nil ? .secondary : .quiet)
            }
        }
        .accessibilityIdentifierIfPresent(identifier)
    }

    private func button(_ action: StateAction, variant: ButtonVariant) -> some View {
        LoadingButton(
            label: action.label,
            glyph: action.glyph,
            variant: variant,
            isLoading: action.isLoading,
            identifier: action.identifier,
            action: action.action
        )
    }
}

/// A read that failed, in plain words, with Try again (RN `ErrorState`, 06 §15.1).
///
/// The words come from `describeError`, never a raw code; the screen may give its own title or
/// body. The heading is announced when it appears, so a failure never looks like "you own
/// nothing" to a VoiceOver user either.
struct ErrorStateView: View {
    /// What was thrown, or nil for a read that found nothing (gone).
    let cause: (any Error)?
    var context: ErrorContext = .read
    var subject: ErrorSubject = .list
    var title: String?
    var message: String?
    /// The query's own reload.
    var onRetry: (() -> Void)?
    var secondary: StateAction?
    var identifier: String?

    var body: some View {
        let words = FeedbackText.errorState(cause: cause, context: context, subject: subject, title: title, body: message)
        ContentUnavailableView {
            Label(words.title, glyph: .refresh)
        } description: {
            Text(verbatim: words.body)
        } actions: {
            if let onRetry {
                LoadingButton(label: L10n.Common.tryAgain, glyph: .refresh, variant: .secondary, action: onRetry)
            }
            if let secondary {
                LoadingButton(label: secondary.label, variant: .quiet, identifier: secondary.identifier, action: secondary.action)
            }
        }
        .accessibilityIdentifierIfPresent(identifier)
        .announcesOnChange(words.title)
    }
}

/// The shape of what is loading (RN `Skeleton`, 06 §15.1).
///
/// It shows only once a read has taken 180 ms (`Motion.delay.skeleton`), so fast reads never
/// flash it. Static on purpose: no shimmer. One VoiceOver element, "Loading…" unless the screen
/// says what loads ("Opening that label…").
struct SkeletonView: View {
    enum Variant: Sendable {
        /// Item rows.
        case rows
        /// A title, then item rows.
        case list
        /// Picker options: no thumbnail, eight rows.
        case options
        /// An item screen: photo, title, two outlines.
        case detail
        /// A two-column grid of cards.
        case grid
    }

    var variant: Variant = .rows
    var rows = 6
    /// The thumbnail on each row: 56, 76, or nil for none.
    var thumb: CGFloat? = DesignMetrics.thumb
    var label: String = FeedbackText.loading

    @State private var delay = DelayedFlag()

    var body: some View {
        // One container, so swapping the placeholder for the content does not count as the
        // skeleton disappearing (which would restart the wait).
        VStack(spacing: 0) {
            if delay.value {
                content
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: label))
                    .accessibilityAddTraits(.updatesFrequently)
            } else {
                // Takes no room, but is there to appear and start the wait.
                Color.clear.frame(height: 0).accessibilityHidden(true)
            }
        }
        .onAppear { delay.setActive(true) }
        .onDisappear { delay.setActive(false) }
    }

    @ViewBuilder
    private var content: some View {
        switch variant {
        case .rows:
            placeholderRows(count: rows, thumb: thumb)
        case .list:
            VStack(alignment: .leading, spacing: 16) {
                block(width: 200, height: 30, radius: 6)
                placeholderRows(count: rows, thumb: thumb)
            }
        case .options:
            placeholderRows(count: 8, thumb: nil)
        case .detail:
            VStack(alignment: .leading, spacing: 16) {
                block(width: DesignMetrics.thumbDetail, height: DesignMetrics.thumbDetail, radius: DesignMetrics.thumbRadius)
                block(width: 240, height: 28, radius: 6)
                outline(height: 120)
                outline(height: 56)
            }
        case .grid:
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(0..<rows, id: \.self) { _ in
                    block(height: 96, radius: 12)
                }
            }
        }
    }

    private func placeholderRows(count: Int, thumb: CGFloat?) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                if index > 0 { Divider().padding(.leading, thumb.map { $0 + 24 } ?? 12) }
                HStack(spacing: 12) {
                    if let thumb {
                        block(width: thumb, height: thumb, radius: DesignMetrics.thumbRadius)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        GeometryReader { proxy in
                            VStack(alignment: .leading, spacing: 8) {
                                block(width: proxy.size.width * 0.6, height: 14)
                                block(width: proxy.size.width * 0.4, height: 14)
                            }
                        }
                        .frame(height: 36)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .frame(minHeight: thumb == DesignMetrics.thumbPhoto ? 96 : (thumb == nil ? 56 : 72))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: DesignMetrics.cardRadius, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private func block(width: CGFloat? = nil, height: CGFloat, radius: CGFloat = 4) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color(uiColor: .tertiarySystemFill))
            .frame(width: width, height: height)
    }

    private func outline(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: DesignMetrics.cardRadius, style: .continuous)
            .strokeBorder(Color(uiColor: .tertiarySystemFill), lineWidth: 2)
            .frame(height: height)
    }
}

/// White text in a glass capsule over the camera picture, readable on any scene
/// (RN `StatusPill`). With `announces`, a change of text is announced (a running count).
struct StatusPill: View {
    let text: String
    var glyph: Glyph?
    var announces = false
    var identifier: String?

    var body: some View {
        HStack(spacing: 6) {
            if let glyph {
                Image(glyph: glyph).accessibilityHidden(true)
            }
            Text(verbatim: text)
                .textRole(.meta)
                .lineLimit(2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 36)
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: .capsule)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifierIfPresent(identifier)
        .announcesOnChange(text, enabled: announces)
    }
}

#Preview("Empty") {
    EmptyStateView(
        title: "Nothing waiting",
        message: "Everything is filed.",
        glyph: .inbox,
        primary: StateAction(label: "Quick Snap", glyph: .layers) {},
        secondary: StateAction(label: "Add an item") {}
    )
}

#Preview("Error") {
    ErrorStateView(cause: nil, subject: .item, onRetry: {})
}

#Preview("Skeleton") {
    SkeletonView(variant: .list).padding()
}

#Preview("Status pill") {
    ZStack {
        LinearGradient(colors: [.orange, .black], startPoint: .top, endPoint: .bottom)
        StatusPill(text: "3 photos taken", glyph: .layers, announces: true)
    }
}
