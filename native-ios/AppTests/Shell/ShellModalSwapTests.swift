import SwiftUI
import Testing
import UIKit
@testable import Inventory
import InventoryAppModels
import InventoryStrings

/// The modal levels' hand-over when the router swaps the modal at one level for a new one while
/// the old one is still animating away (the place picker's New space handing over to New
/// container), hosted in a window so UIKit really presents and dismisses.
@Suite("Shell modal swaps (hosted)", .serialized)
@MainActor
struct ShellModalSwapTests {
    /// The title of the navigation bar in the top-most presented controller.
    private func presentedTitle(_ host: ShellTestWindow) -> String? {
        var top = host.window.rootViewController
        while let next = top?.presentedViewController { top = next }
        guard let top, top !== host.window.rootViewController else { return nil }
        let bar = top.view.shellDescendants.compactMap { $0 as? UINavigationBar }.first
        return bar?.topItem?.title
    }

    private func presentedCount(_ host: ShellTestWindow) -> Int {
        var count = 0
        var top = host.window.rootViewController
        while let next = top?.presentedViewController {
            if !next.isBeingDismissed { count += 1 }
            top = next
        }
        return count
    }

    @Test("a sheet closed and another opened at the same level while it goes away shows the new one, not the old screen")
    func sheetSwapAtOneLevel() async throws {
        let app = AppContainer.preview()
        await app.boot.run()
        let host = try ShellTestWindow(MainShell().shellEnvironment(app))
        defer { host.close() }
        let garage = try #require(try await app.repositories.spaces.listWithCounts().first { $0.name == "Garage" })

        app.router.present(.sheet(.spaceNew(request: nil)))
        await ShellTestWait.until("New space up") { presentedTitle(host) == L10n.SpaceForm.newTitle }
        try await Task.sleep(for: .milliseconds(600))

        // Closed, then the next form opened while the first is still animating away.
        app.router.dismissTop()
        try await Task.sleep(for: .milliseconds(50))
        app.router.present(.sheet(.containerNew(spaceId: garage.id, request: nil)))

        await ShellTestWait.until("New container up") { presentedTitle(host) == L10n.ContainerForm.newTitle }
        try await Task.sleep(for: .seconds(1.5))
        #expect(presentedTitle(host) == L10n.ContainerForm.newTitle)
        #expect(presentedCount(host) == 1)
        #expect(app.router.modals.count == 1)
    }
}
