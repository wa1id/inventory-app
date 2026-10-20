import SwiftUI
import Testing
import UIKit
@testable import Inventory
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// The labels screens' wiring to the app (06 §8-§9, 07 §3.9-§3.10): where their models send the
/// router, what reaches the repositories, and the camera feed driving the Scan tab and the sticker
/// camera end to end. Hosted, against the seeded preview inventory.
@Suite("Labels screens: wiring (hosted)", .serialized)
@MainActor
struct LabelsScreenWiringTests {
    private func bootedApp() async -> AppContainer {
        let app = AppContainer.preview()
        await app.boot.run()
        return app
    }

    private func containerId(_ name: String, in app: AppContainer) async throws -> String {
        let containers = try await app.repositories.containers.listAllWithSpace()
        return try #require(containers.first { $0.container.name == name }?.container.id)
    }

    private func option(_ name: String, in app: AppContainer) async throws -> PlaceOption {
        let containers = try await app.repositories.containers.listAllWithSpace()
        let spaces = try await app.repositories.spaces.listWithCounts()
        return try #require(joinPlaceOptions(containers, spaces: spaces).first { $0.name == name })
    }

    // MARK: Label screen

    @Test("a linked label is replaced by its container on the stack that opened it")
    func linkedLabelOpensItsContainer() async throws {
        let app = AppContainer.preview()
        let host = try ShellTestWindow(RootView().shellEnvironment(app))
        defer { host.close() }
        await ShellTestWait.until("the main shell") { app.boot.phase == .main && app.router.acceptsNavigation }
        let toolChest = try await containerId("Tool chest", in: app)

        app.router.push(.label(token: AppContainerPreviewData.toolChestLabelToken))
        await ShellTestWait.until("the Tool chest in place of the label") {
            app.router.path(.home).map(\.route) == [.container(id: toolChest)]
        }
    }

    @Test("the label screen replaces only itself, and only while it is on top")
    func replacesOnlyWhileOnTop() async {
        let app = await bootedApp()
        let router = app.router
        let label = router.push(.label(token: AppContainerPreviewData.unboundLabelToken))
        router.push(.settings)

        #expect(!LabelLinkScreen.navigate(.replaceWithContainer(id: "c1"), router: router, address: label.address))
        #expect(router.path(.home).map(\.route) == [.label(token: AppContainerPreviewData.unboundLabelToken), .settings])
        #expect(!LabelLinkScreen.navigate(.replaceWithContainer(id: "c1"), router: router, address: nil))

        router.setPath([label], for: .home)
        #expect(LabelLinkScreen.navigate(.replaceWithContainer(id: "c1"), router: router, address: label.address))
        #expect(router.path(.home).map(\.route) == [.container(id: "c1")])

        LabelLinkScreen.navigate(.dropZoneTab, router: router, address: nil)
        #expect(router.selectedTab == .dropZone)
        LabelLinkScreen.navigate(.home, router: router, address: nil)
        #expect(router.selectedTab == .home)
    }

    @Test("picking a container for an unlinked label links it, remembers the place, opens it and says so")
    func bindFromThePicker() async throws {
        let app = await bootedApp()
        let redBin = try await option("Red bin", in: app)
        let label = app.router.push(.label(token: AppContainerPreviewData.unboundLabelToken))
        let model = LabelLinkScreen.makeModel(app: app, token: AppContainerPreviewData.unboundLabelToken, address: label.address)
        model.start()
        await model.waitForLookup()
        guard case .unknown = model.state else {
            Issue.record("expected the bind picker, got \(model.state)")
            return
        }

        await model.link(redBin)

        let binding = try await app.repositories.qr.getByContainer(redBin.id)
        #expect(binding?.token == AppContainerPreviewData.unboundLabelToken)
        #expect(app.router.path(.home).map(\.route) == [.container(id: redBin.id)])
        #expect(app.recentPlaces.read().first == redBin.id)
        #expect(app.toasts.current?.options.message == L10n.DeepLink.linked(label: "Red bin"))
    }

    // MARK: Scan tab

    @Test("Scan's outcomes open the container on the tab in front, the drop zone's tab, or the label screen")
    func scanNavigation() async {
        let app = await bootedApp()
        let router = app.router
        router.selectTab(.scan)
        ScanScreen.navigate(.openLabel(token: "abc"), router: router)
        #expect(router.path(.scan).map(\.route) == [.label(token: "abc")])
        ScanScreen.navigate(.openContainer(id: "c9"), router: router)
        #expect(router.path(.scan).map(\.route) == [.label(token: "abc"), .container(id: "c9")])
        ScanScreen.navigate(.openContainer(id: DropZone.containerId), router: router)
        #expect(router.selectedTab == .dropZone)
    }

    @Test("a label the camera reads goes through the scanner, the guard and the lookup to its container")
    func cameraOpensTheContainer() async throws {
        let app = await bootedApp()
        let toolChest = try await containerId("Tool chest", in: app)
        let feed = StandInQrScannerFeed()
        // A window outside a SwiftUI scene reports no scene phase of its own (background), which
        // would keep the camera off.
        let host = try ShellTestWindow(
            NavigationStack { ScanScreen(makeFeed: { feed }) }
                .environment(\.scenePhase, .active)
                .shellEnvironment(app)
        )
        defer { host.close() }

        await ShellTestWait.until("the camera running") { feed.isRunning }
        let payload = formatQrPayload(AppContainerPreviewData.toolChestLabelToken)
        feed.deliver([payload, payload])
        feed.deliver([payload])
        await ShellTestWait.until("the Tool chest pushed") { !app.router.path(.home).isEmpty }
        #expect(app.router.path(.home).map(\.route) == [.container(id: toolChest)])
    }

    // MARK: QR label

    @Test("the QR label screen's model reads and writes through the current repositories")
    func qrLabelMakesALabel() async throws {
        let app = await bootedApp()
        let redBin = try await containerId("Red bin", in: app)
        let model = QrLabelScreen.makeModel(app: app, containerId: redBin)
        model.focusChanged(true, revision: app.database.revision)
        await ShellTestWait.until("both reads") { !model.container.isLoading && !model.binding.isLoading }
        guard case .noLabel = model.state else {
            Issue.record("expected no label, got \(model.state)")
            return
        }
        let revision = app.database.revision

        await model.make()

        let binding = try #require(try await app.repositories.qr.getByContainer(redBin))
        #expect(model.shownToken == binding.token)
        #expect(app.database.revision == revision + 1)
        guard case .label(_, let token) = model.state else {
            Issue.record("expected the label, got \(model.state)")
            return
        }
        #expect(token == binding.token)
    }

    // MARK: Sticker camera

    @Test("the sticker camera closes only itself, once")
    func stickerClosesItself() async {
        let app = await bootedApp()
        let router = app.router
        router.push(.qrLabel(containerId: "c1"))
        let cover = router.present(.cover(.linkSticker(containerId: "c1")))

        LinkStickerScreen.navigate(.close, router: router, address: cover.address)
        #expect(router.modals.isEmpty)
        #expect(router.path(.home).map(\.route) == [.qrLabel(containerId: "c1")])
        // A late answer after it closed closes nothing else.
        LinkStickerScreen.navigate(.close, router: router, address: cover.address)
        #expect(router.path(.home).map(\.route) == [.qrLabel(containerId: "c1")])
    }

    @Test("a sticker the camera reads is linked to the container, the camera closes, and the toast says so")
    func stickerCameraLinks() async throws {
        let app = await bootedApp()
        let redBin = try await containerId("Red bin", in: app)
        app.router.push(.qrLabel(containerId: redBin))
        let cover = app.router.present(.cover(.linkSticker(containerId: redBin)))
        let feed = StandInQrScannerFeed()
        let host = try ShellTestWindow(
            NavigationStack { LinkStickerScreen(containerId: redBin, makeFeed: { feed }) }
                .environment(\.screenAddress, cover.address)
                .environment(\.scenePhase, .active)
                .shellEnvironment(app)
        )
        defer { host.close() }

        await ShellTestWait.until("the camera running for the Red bin") { feed.isRunning }
        feed.deliver([formatQrPayload(AppContainerPreviewData.unboundLabelToken)])
        await ShellTestWait.until("the camera closed") { app.router.modals.isEmpty }

        let binding = try await app.repositories.qr.getByContainer(redBin)
        #expect(binding?.token == AppContainerPreviewData.unboundLabelToken)
        #expect(app.router.path(.home).map(\.route) == [.qrLabel(containerId: redBin)])
        #expect(app.toasts.current?.options.message == L10n.Link.linked(label: "Red bin"))
    }
}
