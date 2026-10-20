import Observation
import Synchronization
import SwiftUI
import UIKit
import InventoryAppModels
import InventoryStrings

/// Confirmations and action sheets as system alerts, presented from the top-most presented view
/// controller of the app's window, so they show above every sheet and cover (RN src/ui/confirm.ts;
/// 07 §0.8).
///
/// - `confirm`: Cancel (cancel style) first, then the confirm button, destructive unless the
///   options say otherwise. True only for the confirm button; Cancel, and an alert that goes away
///   any other way (its presenter dismissed under it), answer false, exactly once.
/// - `showActionSheet`: the options, destructive ones marked, Cancel last. On iPad it shows as a
///   popover in the middle of the presenter, without an arrow.
///
/// While either is up, ``ShellDialogTracker`` says so, and the overlay window hides the toast: it
/// sits above system alerts and would cover (and take the taps of) an action sheet's buttons.
@MainActor
final class ShellDialogPresenter: ConfirmPresenting, ShellActionSheetPresenting {
    /// Finds the view controller to present from; the active scene's main window by default.
    private let presenter: @MainActor () -> UIViewController?
    private let tracker: ShellDialogTracker

    init(
        presenter: @escaping @MainActor () -> UIViewController? = { ShellDialogPresenter.topViewController() },
        tracker: ShellDialogTracker = .shared
    ) {
        self.presenter = presenter
        self.tracker = tracker
    }

    func confirm(_ options: ConfirmOptions) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let answer = ShellDialogAnswer(continuation)
            let alert = UIAlertController(title: options.title, message: options.body, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: options.cancelLabel, style: .cancel) { _ in answer.resolve(false) })
            alert.addAction(UIAlertAction(title: options.confirmLabel, style: options.destructive ? .destructive : .default) { _ in
                answer.resolve(true)
            })
            guard let presenter = presenter() else {
                answer.resolve(false)
                return
            }
            presenter.present(alert, animated: true)
            // An alert that goes away without a tap (its presenter dismissed under it, or a
            // presentation UIKit refused) answers Cancel.
            track(alert) { answer.resolve(false) }
        }
    }

    /// Counts `alert` as showing until it has gone (dismissed after a tap, its presenter
    /// dismissed under it, or a presentation UIKit refused), then runs `gone`.
    private func track(_ alert: UIAlertController, gone: @escaping @MainActor @Sendable () -> Void = {}) {
        let tracker = tracker
        tracker.began()
        Task { @MainActor in
            repeat {
                try? await Task.sleep(for: .milliseconds(100))
            } while alert.presentingViewController != nil
            gone()
            tracker.ended()
        }
    }

    func showActionSheet(_ sheet: ShellActionSheet) {
        guard let presenter = presenter() else { return }
        let alert = UIAlertController(title: sheet.title, message: nil, preferredStyle: .actionSheet)
        for option in sheet.options {
            let handler = option.handler
            alert.addAction(UIAlertAction(title: option.label, style: option.destructive ? .destructive : .default) { _ in
                handler()
            })
        }
        alert.addAction(UIAlertAction(title: sheet.cancelLabel ?? L10n.Common.cancel, style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(alert, animated: true)
        track(alert)
    }

    /// The top-most view controller of the foreground scene's main window (never the overlay
    /// window), skipping one that is being dismissed.
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow && !($0 is ShellOverlayWindow) }
            ?? scene?.windows.first { !($0 is ShellOverlayWindow) }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

/// Whether a confirmation or action sheet from ``ShellDialogPresenter`` is showing. The overlay
/// window follows it: it sits at `.alert + 1`, above system alerts, so while a dialog is up the
/// toast steps aside instead of covering its buttons (the removed-phone layer stays).
@MainActor
@Observable
final class ShellDialogTracker {
    /// The app's: every presenter and the overlay window share it.
    static let shared = ShellDialogTracker()

    /// Dialogs presented and not gone yet.
    private(set) var openCount = 0

    var isShowingDialog: Bool { openCount > 0 }

    func began() {
        openCount += 1
    }

    func ended() {
        openCount = max(0, openCount - 1)
    }
}

extension View {
    /// Counts a SwiftUI `.confirmationDialog` or `.alert` that this view presents as a shell
    /// dialog while `isPresented` is true, so a live toast steps aside instead of covering its
    /// buttons and taking their taps (the overlay window sits above system alerts). Pass the flag
    /// the dialog binds: `.confirmationDialog(…, isPresented: $asking) { … }.tracksShellDialog(isPresented: asking)`.
    /// `app.platform.confirm` and `app.platform.actionSheets` are tracked already.
    func tracksShellDialog(isPresented: Bool, tracker: ShellDialogTracker = .shared) -> some View {
        modifier(ShellDialogTracking(isPresented: isPresented, tracker: tracker))
    }
}

/// Counts one SwiftUI dialog in ``ShellDialogTracker`` while it is presented and this view is
/// on screen (a view taken away with its dialog up stops counting).
private struct ShellDialogTracking: ViewModifier {
    let isPresented: Bool
    let tracker: ShellDialogTracker
    @State private var counted = false

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented, initial: true) { _, presented in update(presented) }
            .onAppear { update(isPresented) }
            .onDisappear { update(false) }
    }

    private func update(_ presented: Bool) {
        guard presented != counted else { return }
        counted = presented
        if presented { tracker.began() } else { tracker.ended() }
    }
}

/// Resumes a confirmation once: from a button, or with false when the alert goes away otherwise.
final class ShellDialogAnswer: Sendable {
    private let continuation: Mutex<CheckedContinuation<Bool, Never>?>

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resolve(_ value: Bool) {
        continuation.withLock { $0.take() }?.resume(returning: value)
    }

    var isResolved: Bool {
        continuation.withLock { $0 == nil }
    }

    deinit {
        resolve(false)
    }
}
