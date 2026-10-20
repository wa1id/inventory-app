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

/// A read that failed, in plain words, with Try again (RN `ErrorState`, 06 §15.1, 09 §7.3).
///
/// The words come from `describeError`, never a raw code; the screen may give its own title or
/// body (from `L10n`, never an error's message). The heading is announced when it appears or
/// changes, so a failure never looks like "you own nothing" to a VoiceOver user either.
///
/// Text precedence is RN's: when a ``Cause`` is given, or either override is missing, the copy
/// comes from `describeError(cause, context, subject)`; `title` and `body` then override it.
/// ``Cause/gone`` is RN's explicit `null` (a read that found the record deleted): pass it from
/// the screen's own branch, never from an `InventoryQuery`'s nil `cause` (09 §5). A nil cause is
/// RN's `undefined`: the screen supplies both texts (the boot gate), or anything unclassified
/// reads as a local failure.
struct ErrorStateView: View {
    /// What the failed read gave.
    enum Cause {
        /// It threw (`query.cause`).
        case failed(any Error)
        /// It answered nothing: the record is gone (RN `cause={null}`).
        case gone
    }

    private let heading: String
    private let message: String
    /// The query's own reload.
    private let onRetry: (() -> Void)?
    private let secondary: StateAction?
    private let identifier: String?

    /// - Parameters:
    ///   - cause: what the read gave; nil when the screen supplies both texts itself.
    ///   - onRetry: always the query's own reload (`error-retry`).
    ///   - secondary: a quiet second button (`secondary.identifier`, else `error-secondary`).
    init(
        cause: Cause?,
        context: ErrorContext = .read,
        subject: ErrorSubject = .list,
        title: String? = nil,
        body: String? = nil,
        onRetry: (() -> Void)? = nil,
        secondary: StateAction? = nil,
        identifier: String? = nil
    ) {
        let thrown: (any Error)? = switch cause {
        case .failed(let error): error
        case .gone: nil
        // RN `undefined` with an override missing: anything unclassified reads as local.
        case nil: ErrorStateUnspecified()
        }
        let words = FeedbackText.errorState(cause: thrown, context: context, subject: subject, title: title, body: body)
        heading = words.title
        message = words.body
        self.onRetry = onRetry
        self.secondary = secondary
        self.identifier = identifier
    }

    var body: some View {
        ContentUnavailableView {
            Label(heading, glyph: .refresh)
        } description: {
            if !message.isEmpty { Text(verbatim: message) }
        } actions: {
            if let onRetry {
                LoadingButton(label: L10n.Common.tryAgain, glyph: .refresh, variant: .secondary, identifier: "error-retry", action: onRetry)
            }
            if let secondary {
                LoadingButton(
                    label: secondary.label,
                    glyph: secondary.glyph,
                    variant: .quiet,
                    isLoading: secondary.isLoading,
                    identifier: secondary.identifier ?? "error-secondary",
                    action: secondary.action
                )
            }
        }
        .accessibilityIdentifierIfPresent(identifier)
        .announcesOnChange(heading)
    }
}

/// RN's `undefined` cause.
private struct ErrorStateUnspecified: Error {}

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
    ErrorStateView(cause: .gone, subject: .item, onRetry: {}, secondary: StateAction(label: L10n.Common.goToHome) {})
}

#Preview("Error, overrides only") {
    ErrorStateView(cause: nil, title: L10n.Boot.failedTitle, body: L10n.Boot.failedBody, onRetry: {})
}

#Preview("Skeleton") {
    SkeletonView(variant: .list).padding()
}
