import SwiftUI
import InventoryCore
import InventoryStrings

/// Shown when a screen's data could not be read (RN ErrorState.tsx; 09 §7.3): what happened and
/// what is still safe, in plain words from `describeError`, with Try again. A database problem
/// never looks like "you own nothing", and raw codes never reach the screen.
///
/// Text precedence is RN's: when a ``Cause`` is given, or either override is missing, the copy
/// comes from `describeError(cause, context, subject)`; `title` and `body` then override it.
/// ``Cause/gone`` is RN's explicit `null` (a read that found the record deleted): pass it from
/// the screen's own branch, never from an `InventoryQuery`'s nil cause (09 §5). Overrides come
/// from `L10n`, never from an error's message. The heading is announced when it appears or
/// changes.
struct ErrorStateView: View {
    /// What the failed read gave.
    enum Cause {
        /// It threw.
        case failed(any Error)
        /// It answered nothing: the record is gone (RN `cause={null}`).
        case gone
    }

    private let heading: String
    private let message: String
    private let onRetry: (() -> Void)?
    private let secondary: Secondary?
    @Environment(\.shellAnnounce) private var announce

    /// The optional second button (RN `secondary`).
    struct Secondary {
        var label: String
        var identifier: String?
        var action: () -> Void

        init(_ label: String, identifier: String? = nil, action: @escaping () -> Void) {
            self.label = label
            self.identifier = identifier
            self.action = action
        }
    }

    /// - Parameters:
    ///   - cause: what the read gave; nil when the screen supplies both texts itself.
    ///   - onRetry: always the query's own reload.
    init(
        cause: Cause?,
        context: ErrorContext = .read,
        subject: ErrorSubject = .list,
        title: String? = nil,
        body: String? = nil,
        onRetry: (() -> Void)? = nil,
        secondary: Secondary? = nil
    ) {
        let described: ErrorCopy? = if cause != nil || title == nil || body == nil {
            switch cause {
            case .failed(let error): describeError(error, context: context, subject: subject)
            case .gone: describeError(nil, context: context, subject: subject)
            // RN `undefined` with an override missing: anything unclassified reads as local.
            case nil: describeError(ErrorStateUnspecified(), context: context, subject: subject)
            }
        } else {
            nil
        }
        heading = title ?? described?.title ?? ""
        message = body ?? described?.body ?? ""
        self.onRetry = onRetry
        self.secondary = secondary
    }

    var body: some View {
        ContentUnavailableView {
            Label(heading, systemImage: "arrow.clockwise")
        } description: {
            if !message.isEmpty { Text(message) }
        } actions: {
            if let onRetry {
                Button(action: onRetry) {
                    Label(L10n.Common.tryAgain, systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("error-retry")
            }
            if let secondary {
                Button(secondary.label, action: secondary.action)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier(secondary.identifier ?? "error-secondary")
            }
        }
        .onChange(of: heading, initial: true) { _, heading in
            if !heading.isEmpty { announce(heading) }
        }
    }
}

/// RN's `undefined` cause.
private struct ErrorStateUnspecified: Error {}

#Preview("Local read failed") {
    ErrorStateView(cause: .failed(CancellationError()), onRetry: {})
}

#Preview("Gone, with a secondary action") {
    ErrorStateView(cause: .gone, subject: .container, onRetry: {}, secondary: .init(L10n.Common.goToHome) {})
}

#Preview("Overrides only") {
    ErrorStateView(cause: nil, title: L10n.Boot.failedTitle, body: L10n.Boot.failedBody, onRetry: {})
}
