import SwiftUI
import Testing
import UIKit
@testable import Inventory
import InventoryAppModels

@Suite("Confirm presenter (hosted)", .serialized)
@MainActor
struct ShellDialogTests {
    @Test("a confirmation is an alert above the top-most sheet: Cancel first, the confirm button destructive")
    func alertAboveSheet() async throws {
        let host = try ShellTestWindow(Color.clear)
        defer { host.close() }
        let root = try #require(host.window.rootViewController)
        let sheet = UIViewController()
        root.present(sheet, animated: false)
        await ShellTestWait.until("the sheet") { root.presentedViewController === sheet }

        let presenter = ShellDialogPresenter(presenter: {
            var top: UIViewController? = root
            while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
            return top
        })
        let answer = Task {
            await presenter.confirm(ConfirmOptions(title: "Delete “Cordless drill”?", body: "This cannot be undone.", confirmLabel: "Delete"))
        }
        await ShellTestWait.until("the alert") { sheet.presentedViewController is UIAlertController }
        let alert = try #require(sheet.presentedViewController as? UIAlertController)
        #expect(alert.preferredStyle == .alert)
        #expect(alert.title == "Delete “Cordless drill”?")
        #expect(alert.message == "This cannot be undone.")
        #expect(alert.actions.map(\.title) == ["Cancel", "Delete"])
        #expect(alert.actions.map(\.style) == [.cancel, .destructive])

        // Its sheet goes away under it (the removed-phone layer closing everything): Cancel.
        sheet.dismiss(animated: false)
        #expect(await answer.value == false)
    }

    @Test("a non-destructive confirmation and the case of nothing to present from")
    func defaultStyleAndNoPresenter() async throws {
        let none = ShellDialogPresenter(presenter: { nil })
        #expect(await none.confirm(ConfirmOptions(title: "t", body: "b", confirmLabel: "OK", destructive: false)) == false)

        let host = try ShellTestWindow(Color.clear)
        defer { host.close() }
        let root = try #require(host.window.rootViewController)
        let presenter = ShellDialogPresenter(presenter: { root })
        let answer = Task { await presenter.confirm(ConfirmOptions(title: "Restore?", body: "b", confirmLabel: "Restore", cancelLabel: "Keep editing", destructive: false)) }
        await ShellTestWait.until("the alert") { root.presentedViewController is UIAlertController }
        let alert = try #require(root.presentedViewController as? UIAlertController)
        #expect(alert.actions.map(\.title) == ["Keep editing", "Restore"])
        #expect(alert.actions.map(\.style) == [.cancel, .default])
        root.dismiss(animated: false)
        #expect(await answer.value == false)
    }

    @Test("an action sheet lists the options, destructive ones marked, Cancel last")
    func actionSheet() async throws {
        let host = try ShellTestWindow(Color.clear)
        defer { host.close() }
        let root = try #require(host.window.rootViewController)
        let presenter = ShellDialogPresenter(presenter: { root })
        presenter.showActionSheet(ShellActionSheet(options: [
            .init(label: "Retake") {},
            .init(label: "Remove photo", destructive: true) {},
        ]))
        await ShellTestWait.until("the sheet") { root.presentedViewController is UIAlertController }
        let alert = try #require(root.presentedViewController as? UIAlertController)
        #expect(alert.preferredStyle == .actionSheet)
        #expect(alert.actions.map(\.title) == ["Retake", "Remove photo", "Cancel"])
        #expect(alert.actions.map(\.style) == [.default, .destructive, .cancel])
        root.dismiss(animated: false)
    }
}
