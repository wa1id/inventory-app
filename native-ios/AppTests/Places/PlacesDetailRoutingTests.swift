import SwiftUI
import Testing
@testable import Inventory
import InventoryAppModels
import InventoryCore

/// The space and container screens hosted in the real shell (07 §0.1): an old route to the drop
/// zone's system records goes to the Drop zone tab, as RN's `ToDropZone` did with `goToTab`, which
/// popped the route; the screen must not stay behind on the tab it was pushed on.
@Suite("Places detail routing (hosted)", .serialized)
@MainActor
struct PlacesDetailRoutingTests {
    @Test("a pushed drop-zone container or space takes itself off its stack and opens the Drop zone tab")
    func dropZoneRoutesLeaveTheirStack() async throws {
        let app = AppContainer.preview()
        let host = try ShellTestWindow(RootView().shellEnvironment(app))
        defer { host.close() }
        await ShellTestWait.until("the main shell") { app.boot.phase == .main && app.router.acceptsNavigation }

        app.router.push(.container(id: DropZone.containerId))
        await ShellTestWait.until("the Drop zone tab") { app.router.selectedTab == .dropZone }
        // Left on Home, it would send Home to the drop zone again each time Home showed.
        await ShellTestWait.until("Home's stack cleared") { app.router.path(.home).isEmpty }

        app.router.selectTab(.spaces)
        await ShellTestWait.until("the Spaces tab") { app.router.selectedTab == .spaces }
        app.router.push(.space(id: DropZone.spaceId))
        await ShellTestWait.until("the Drop zone tab again") { app.router.selectedTab == .dropZone }
        await ShellTestWait.until("Spaces' stack cleared") { app.router.path(.spaces).isEmpty }
    }
}
