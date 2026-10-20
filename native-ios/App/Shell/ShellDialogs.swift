import Synchronization
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
@MainActor
final class ShellDialogPresenter: ConfirmPresenting, ShellActionSheetPresenting {
    /// Finds the view controller to present from; the active scene's main window by default.
    private let presenter: @MainActor () -> UIViewController?

    init(presenter: @escaping @MainActor () -> UIViewController? = { ShellDialogPresenter.topViewController() }) {
        self.presenter = presenter
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
            Self.resolveWhenGone(alert, answer)
        }
    }

    /// An alert that goes away without a tap (its presenter dismissed under it, or a presentation
    /// UIKit refused) answers Cancel.
    private static func resolveWhenGone(_ alert: UIAlertController, _ answer: ShellDialogAnswer) {
        Task { @MainActor in
            while !answer.isResolved {
                try? await Task.sleep(for: .milliseconds(200))
                if alert.presentingViewController == nil { answer.resolve(false) }
            }
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
