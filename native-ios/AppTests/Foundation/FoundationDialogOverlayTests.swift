import SwiftUI
import Testing
import UIKit
@testable import Inventory
import InventoryAppModels

/// The overlay window sits above system alerts, so a toast would cover an action sheet's bottom
/// buttons and take their taps: while a confirmation or action sheet is up the toast steps
/// aside, and comes back once the dialog has gone (wave-4 review).
@Suite("Toasts over dialogs (hosted)", .serialized)
@MainActor
struct FoundationDialogOverlayTests {
    private struct Fixture {
        let app: AppContainer
        let host: ShellTestWindow
        let overlay: ShellOverlayController
        let window: ShellOverlayWindow
        let presenter: ShellDialogPresenter
        let tracker: ShellDialogTracker
        let root: UIViewController
    }

    private func fixture() async throws -> Fixture {
        let app = AppContainer.preview()
        await app.boot.run()
        let host = try ShellTestWindow(Color.clear)
        let scene = try #require(ShellTestWindow.scene)
        let root = try #require(host.window.rootViewController)
        let tracker = ShellDialogTracker()
        let overlay = ShellOverlayController(app: app, dialogs: tracker)
        overlay.install(on: scene)
        let window = try #require(overlay.window)
        let presenter = ShellDialogPresenter(presenter: { root }, tracker: tracker)
        return Fixture(app: app, host: host, overlay: overlay, window: window, presenter: presenter, tracker: tracker, root: root)
    }

    private func close(_ fixture: Fixture) {
        fixture.window.isHidden = true
        fixture.host.close()
    }

    @Test("an action sheet hides a showing toast until it has gone")
    func actionSheet() async throws {
        let fixture = try await fixture()
        defer { close(fixture) }
        fixture.app.toasts.show(ToastOptions(message: "Moved to Tool chest (Garage).", action: ToastAction(label: "Undo") {}))
        await ShellTestWait.until("the toast's window") { !fixture.window.isHidden }

        fixture.presenter.showActionSheet(ShellActionSheet(options: [.init(label: "Retake") {}, .init(label: "Remove photo", destructive: true) {}]))
        await ShellTestWait.until("the action sheet") { fixture.root.presentedViewController is UIAlertController }
        #expect(fixture.tracker.isShowingDialog)
        await ShellTestWait.until("the toast stepping aside") { fixture.window.isHidden }
        #expect(fixture.app.toasts.current != nil, "the toast itself is not dismissed")

        fixture.root.dismiss(animated: false)
        await ShellTestWait.until("the dialog gone") { !fixture.tracker.isShowingDialog }
        await ShellTestWait.until("the toast back") { !fixture.window.isHidden }
    }

    @Test("a confirmation hides a showing toast; a toast shown during it waits until it has gone")
    func confirmation() async throws {
        let fixture = try await fixture()
        defer { close(fixture) }
        let answer = Task {
            await fixture.presenter.confirm(ConfirmOptions(title: "Delete “Cordless drill”?", body: "This cannot be undone.", confirmLabel: "Delete"))
        }
        await ShellTestWait.until("the alert") { fixture.root.presentedViewController is UIAlertController }
        #expect(fixture.tracker.isShowingDialog)

        fixture.app.toasts.show(ToastOptions(message: "The quantity was not saved. Try again.", tone: .error))
        // Give the overlay a chance to follow the toast: it must stay hidden.
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.window.isHidden)

        fixture.root.dismiss(animated: false)
        #expect(await answer.value == false)
        await ShellTestWait.until("the toast shown once the alert has gone") { !fixture.window.isHidden }
        #expect(!fixture.tracker.isShowingDialog)
    }

    @Test("the overlay follows the tracker: a toast waits while a dialog counts as up")
    func followsTracker() async throws {
        let fixture = try await fixture()
        defer { close(fixture) }
        fixture.tracker.began()
        fixture.app.toasts.show(ToastOptions(message: "Moved."))
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.window.isHidden)
        fixture.tracker.ended()
        await ShellTestWait.until("the toast back") { !fixture.window.isHidden }
    }
}
