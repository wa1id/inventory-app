import SwiftUI
import Testing
import UIKit
@testable import Inventory
import InventoryAppModels
import InventoryCore
import InventoryServices

/// The capture screen's wiring on a real shell (05 §3-4): the stand-in camera reaches the model,
/// a request photo comes back through the router, a photo nobody waits for opens the Add sheet,
/// and a fast set ends on the review inside the cover, where the camera stops and the swipe back
/// closes the cover (Q13).
@Suite("Capture screen (hosted)", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct CaptureScreenHostedTests {
    /// The shell on the preview inventory, with a stand-in camera following `script`.
    private func shell(_ script: CaptureStandInFeed.Script) async throws -> (AppContainer, ShellTestWindow) {
        CaptureStandIn.current = CaptureStandIn.Configuration(permission: CaptureStandInPermission(.authorized), script: script)
        let app = AppContainer.preview()
        // A window of our own is not one of the app's scenes, so SwiftUI would report it as in
        // the background, and the camera runs only in an active scene.
        let host = try ShellTestWindow(RootView().shellEnvironment(app).environment(\.scenePhase, .active))
        await ShellTestWait.until("the main shell") { app.boot.phase == .main && app.router.acceptsNavigation }
        return (app, host)
    }

    private func tearDown(_ host: ShellTestWindow) {
        host.close()
        CaptureStandIn.current = nil
    }

    private func fast(_ shots: [CaptureStandInFeed.Shot], finishes: Bool = false) -> CaptureStandInFeed.Script {
        CaptureStandInFeed.Script(shots: shots, finishes: finishes, pause: .milliseconds(300))
    }

    @Test("the Add sheet's photo comes back through presentForResult, stored, and the camera closes")
    func requestPhoto() async throws {
        let (app, host) = try await shell(fast([.photo]))
        defer { tearDown(host) }

        let waiting = Task {
            await app.router.presentForResult(StoredImage.self) {
                .cover(.capture(CaptureRoute(containerId: DropZone.containerId, mode: .fast), request: $0))
            }
        }
        await ShellTestWait.until("the camera") { !app.router.modals.isEmpty }
        if case .cover(.capture(let route, _))? = app.router.modals.last?.route {
            #expect(route.mode == .fast, "asked for fast; the request makes it single")
        }
        await ShellTestWait.until("the photo handed back and the camera closed", timeout: .seconds(15)) { app.router.modals.isEmpty }
        // Abandons a request nobody answered, so the wait ends either way.
        app.router.dismissAll()
        let photo = await waiting.value

        let stored = try #require(photo, "the camera answered the request")
        #expect(stored.uri.contains("item-photos"))
        let file = try #require(app.photoPathResolver.resolve(stored.uri))
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        await ShellTestWait.until("the camera gone") { app.router.modals.isEmpty }
    }

    @Test("a single photo nobody waits for replaces the camera with the Add sheet carrying it")
    func singlePhotoOpensAdd() async throws {
        let (app, host) = try await shell(fast([.photo]))
        defer { tearDown(host) }

        app.router.present(.cover(.capture(CaptureRoute(containerId: DropZone.containerId), request: nil)))
        await ShellTestWait.until("the Add sheet") {
            if case .sheet(.addItem)? = app.router.modals.last?.route { return true }
            return false
        }
        guard case .sheet(.addItem(let params))? = app.router.modals.last?.route else { return }
        #expect(params.containerId == DropZone.containerId)
        #expect(params.photoUri?.contains("item-photos") == true)
        #expect(params.photoWidth != nil)
        #expect(app.router.modals.count == 1, "the Add sheet took the camera's place")
    }

    @Test("Done on a set pushes the review in the cover with the shots expected; the camera stops under it, and popping the review closes the cover")
    func fastSetEndsOnReview() async throws {
        let (app, host) = try await shell(fast([.photo, .photo], finishes: true))
        defer { tearDown(host) }

        let cover = app.router.present(.cover(.capture(.quickSnap, request: nil)))
        await ShellTestWait.until("the stand-in running") { CaptureStandIn.lastFeed?.isRunning == true }
        await ShellTestWait.until("the review pushed", timeout: .seconds(15)) {
            app.router.modal(cover.id)?.path.last != nil
        }
        guard case .quickSnapReview(let review)? = app.router.modal(cover.id)?.path.last?.route else {
            Issue.record("expected the review over the camera")
            return
        }
        #expect(review.containerId == DropZone.containerId)
        #expect(review.expected == 2)
        await ShellTestWait.until("the camera stopped under the review") { CaptureStandIn.lastFeed?.isRunning == false }

        // Both shots become rows in the drop zone, from the session start on (the pipelines
        // outlive the camera).
        var rows: [ItemWithContext] = []
        for _ in 0..<100 {
            rows = try await app.repositories.items.listByContainer(DropZone.containerId).filter { $0.createdAt >= review.since }
            if rows.count == 2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(rows.count == 2)

        // The edge swipe pops the review: the closed camera goes too.
        app.router.setModalPath([], modal: cover.id)
        #expect(app.router.modals.isEmpty)
    }

    @Test("✕ before any shot closes the camera, and nothing is written")
    func closeEmpty() async throws {
        let (app, host) = try await shell(CaptureStandInFeed.Script())
        defer { tearDown(host) }
        let before = try await app.repositories.items.countUnsorted()

        let cover = app.router.present(.cover(.capture(.quickSnap, request: nil)))
        await ShellTestWait.until("the stand-in running") { CaptureStandIn.lastFeed?.isRunning == true }
        app.router.close(cover.address)
        await ShellTestWait.until("the stand-in stopped") { CaptureStandIn.lastFeed?.isRunning != true }
        #expect(try await app.repositories.items.countUnsorted() == before)
    }
}
