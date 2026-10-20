import CoreGraphics
import Foundation
import ImageIO
import InventoryCore
import InventoryServices
import InventoryTestSupport
import Testing
import UniformTypeIdentifiers
@testable import InventoryAppModels

@Suite("QuickSnapReviewModel: focus, revision and refresh (useInventoryQuery triggers)", .timeLimit(.minutes(1)))
@MainActor
struct CaptureReviewTriggerTests {
    @Test("reads when the screen comes into focus, again on each focus gain, and nothing while behind")
    func focusReads() async {
        let harness = QuickSnapReviewHarness()
        harness.items.rows = [CaptureTestRows.dropZone("a", name: "Drill", createdAt: 150)]
        let model = harness.model(expected: 1)
        #expect(harness.items.listCalls.isEmpty, "nothing is read before the screen is in front")

        model.focusChanged(true, revision: 3)
        await model.readTask?.value
        #expect(harness.items.listCalls.count == 1)
        #expect(model.list.map(\.id) == ["a"])

        // Still focused, same revision: nothing new to read.
        model.focusChanged(true, revision: 3)
        await model.readTask?.value
        #expect(harness.items.listCalls.count == 1)

        // Covered by the item screen: no reads, however the inventory changes.
        model.focusChanged(false, revision: 3)
        model.revisionChanged(4)
        model.revisionChanged(5)
        await model.readTask?.value
        #expect(harness.items.listCalls.count == 1)

        // Back in front: one read catches up.
        harness.items.rows = [CaptureTestRows.dropZone("b", createdAt: 160), CaptureTestRows.dropZone("a", name: "Drill", createdAt: 150)]
        model.focusChanged(true, revision: 5)
        await model.readTask?.value
        #expect(harness.items.listCalls.count == 2)
        #expect(model.list.map(\.id) == ["a", "b"])
    }

    @Test("a write while in front reads again, once per revision")
    func revisionReads() async {
        let harness = QuickSnapReviewHarness()
        let model = harness.model(expected: 2)
        model.focusChanged(true, revision: 0)
        await model.readTask?.value
        #expect(model.status == .pending)

        // A pipeline lands and invalidates.
        harness.items.rows = [CaptureTestRows.dropZone("a", name: "Drill", createdAt: 150)]
        model.revisionChanged(1)
        await model.readTask?.value
        #expect(harness.items.listCalls.count == 2)
        #expect(model.title == "1 saved to the drop zone")

        model.revisionChanged(1)
        await model.readTask?.value
        #expect(harness.items.listCalls.count == 2, "the same revision reads nothing")
    }

    @Test("pull to refresh reads and returns once the rows are in, focused or not")
    func refresh() async {
        let harness = QuickSnapReviewHarness()
        harness.items.rows = [CaptureTestRows.dropZone("a", createdAt: 150)]
        let model = harness.model(expected: 1)
        await model.refresh()
        #expect(harness.items.listCalls.count == 1)
        #expect(model.list.map(\.id) == ["a"])
        #expect(!model.isLoading)
    }
}

@Suite("CaptureNavigator: the camera's exits on the router (05 §3)")
@MainActor
struct CaptureNavigatorTests {
    private func camera(_ router: Router, route: CaptureRoute = .quickSnap, request: RouteRequest<StoredImage>? = nil) -> ModalEntry {
        router.present(.cover(.capture(route, request: request)))
    }

    @Test("back closes the camera's cover and nothing under it")
    func back() {
        let router = Router()
        router.push(.settings)
        let cover = camera(router)
        CaptureNavigator(router: router, address: cover.address).navigate(.back)
        #expect(router.modals.isEmpty)
        #expect(router.path(.home).map(\.route) == [.settings])
    }

    @Test("a photo nobody waited for replaces the camera with the Add sheet carrying it; Type it instead carries none")
    func addItem() throws {
        let router = Router()
        let photo = StoredImage(uri: "file:///p.webp", thumbUri: "file:///p-thumb.webp", width: 646, height: 1400, byteSize: 52_000)
        let cover = camera(router, route: CaptureRoute(containerId: "c1"))
        CaptureNavigator(router: router, address: cover.address).navigate(.addItem(containerId: "c1", photo: photo))
        #expect(router.modals.count == 1)
        #expect(router.modals.first?.route == .sheet(.addItem(AddParams(containerId: "c1", photo: photo))))
        #expect(router.modals.first?.id != cover.id, "a sheet is a new presentation, not the cover's")

        let typed = Router()
        let second = camera(typed)
        CaptureNavigator(router: typed, address: second.address).navigate(.addItem(containerId: DropZone.containerId, photo: nil))
        #expect(typed.modals.map(\.route) == [.sheet(.addItem(AddParams(containerId: DropZone.containerId)))])
    }

    @Test("Done pushes the review inside the cover, and the swipe back from it lands where the set started (Q13)")
    func reviewSwipeBack() throws {
        let router = Router()
        router.push(.settings)
        let cover = camera(router)
        let review = QuickSnapReviewRoute(containerId: DropZone.containerId, since: 100, expected: 2)
        CaptureNavigator(router: router, address: cover.address).navigate(.review(review))
        #expect(router.modals.count == 1)
        #expect(router.modals.first?.path.map(\.route) == [.quickSnapReview(review)])
        #expect(!router.isFocused(cover.address), "the camera under the review is not in front, so its session stops")

        // The edge swipe pops the review: the closed camera goes too.
        router.setModalPath([], modal: cover.id)
        #expect(router.modals.isEmpty)
        #expect(router.path(.home).map(\.route) == [.settings])
    }

    @Test("the review's Done and Keep shooting take the camera with them, and the swipe-back rule then does nothing")
    func reviewLeavesNormally() throws {
        let router = Router()
        let cover = camera(router)
        let reviewRoute = QuickSnapReviewRoute(containerId: DropZone.containerId, since: 100, expected: 2)
        CaptureNavigator(router: router, address: cover.address).navigate(.review(reviewRoute))
        let review = try #require(router.modals.first?.path.last)

        let next = CaptureRoute(containerId: DropZone.containerId, mode: .fast, since: 100, expectedBase: 2)
        QuickSnapReviewNavigator(router: router, address: review.address).navigate(.keepShooting(next))
        #expect(router.modals.count == 1)
        #expect(router.modals.first?.route == .cover(.capture(next, request: nil)))
        #expect(router.modals.first?.id == cover.id, "the same cover stays up with a new camera")
        #expect(router.modals.first?.path.isEmpty == true)

        // The new camera's own set ends on Done.
        let fresh = try #require(router.modals.first)
        CaptureNavigator(router: router, address: fresh.address).navigate(.review(reviewRoute))
        let second = try #require(router.modals.first?.path.last)
        QuickSnapReviewNavigator(router: router, address: second.address).navigate(.leave(containerId: DropZone.containerId))
        #expect(router.modals.isEmpty)
    }
}

@Suite("QuickSnapReviewNavigator: the review's exits on the router (05 §6.5)")
@MainActor
struct CaptureReviewNavigatorTests {
    @Test("Done closes the camera's cover; the screens under it stay")
    func leave() throws {
        let router = Router()
        router.push(.container(id: "c1"))
        router.present(.cover(.capture(CaptureRoute(containerId: "c1", mode: .fast), request: nil)))
        let review = router.push(.quickSnapReview(QuickSnapReviewRoute(containerId: "c1", since: 1, expected: 1)))
        QuickSnapReviewNavigator(router: router, address: review.address).navigate(.leave(containerId: "c1"))
        #expect(router.modals.isEmpty)
        #expect(router.path(.home).map(\.route) == [.container(id: "c1")])
    }

    @Test("a review pushed on a tab pops; one nobody can go back from opens its container")
    func leaveWithoutCover() {
        let router = Router()
        let review = router.push(.quickSnapReview(QuickSnapReviewRoute(containerId: "c1", since: 1, expected: 1)))
        QuickSnapReviewNavigator(router: router, address: review.address).navigate(.leave(containerId: "c1"))
        #expect(router.path(.home).isEmpty)

        QuickSnapReviewNavigator(router: router, address: .push(999)).navigate(.leave(containerId: "c1"))
        #expect(router.path(.home).map(\.route) == [.container(id: "c1")])
    }

    @Test("Try again with no cover to replace presents a fresh camera")
    func tryAgainWithoutCover() {
        let router = Router()
        let review = router.push(.quickSnapReview(QuickSnapReviewRoute(containerId: DropZone.containerId, since: 1, expected: 1)))
        let fresh = CaptureRoute(containerId: DropZone.containerId, mode: .fast)
        QuickSnapReviewNavigator(router: router, address: review.address).navigate(.tryAgain(fresh))
        #expect(router.path(.home).isEmpty)
        #expect(router.modals.map(\.route) == [.cover(.capture(fresh, request: nil))])
    }

    @Test("a row opens its item over the review; View goes to the Drop zone tab and closes everything")
    func openItemAndView() {
        let router = Router()
        router.present(.cover(.capture(.quickSnap, request: nil)))
        let review = router.push(.quickSnapReview(QuickSnapReviewRoute(containerId: DropZone.containerId, since: 1, expected: 1)))
        let navigator = QuickSnapReviewNavigator(router: router, address: review.address)
        navigator.navigate(.openItem(id: "i1", filing: true))
        #expect(router.modals.first?.path.map(\.route) == [.quickSnapReview(QuickSnapReviewRoute(containerId: DropZone.containerId, since: 1, expected: 1)), .item(id: "i1", filing: true)])

        navigator.navigate(.viewDropZone)
        #expect(router.modals.isEmpty)
        #expect(router.selectedTab == .dropZone)
    }
}

@Suite("CaptureIntoPlace.pillLine: the Into pill's words")
struct CaptureIntoPillTextTests {
    private func place(name: String?) -> CaptureIntoPlace {
        CaptureIntoPlace(containerId: "c1", containerName: name, containerShortCode: "BOX-7K2M", spaceId: "s1", spaceName: "Garage", spaceColor: "#5B8DEF")
    }

    @Test("names the space and the container, the tape carrying the code")
    func named() {
        #expect(place(name: "Tool chest").pillLine == "Garage › Tool chest")
    }

    @Test("an unnamed container is its tape alone; only a missing name falls back, as RN's ??")
    func unnamed() {
        #expect(place(name: nil).pillLine == "Garage ›")
        #expect(place(name: "").pillLine == "Garage › ")
    }
}

@Suite("CaptureShotThumbnail: the last-shot tile's picture")
struct CaptureShotThumbnailTests {
    /// A JPEG of `width` × `height` pixels with an EXIF orientation.
    private func jpeg(width: Int, height: Int, orientation: Int = 1) throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.8, green: 0.5, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test("decodes only a small picture, its longer side at most 300 px, keeping the shape")
    func small() throws {
        let thumbnail = try #require(CaptureShotThumbnail.decode(try jpeg(width: 1200, height: 1600)))
        #expect(thumbnail.pixelHeight == 300)
        #expect(thumbnail.pixelWidth == 225)
    }

    @Test("turns a sideways still upright by its orientation")
    func upright() throws {
        // Stored landscape, shot portrait (EXIF 6: rotate 90° clockwise to view).
        let thumbnail = try #require(CaptureShotThumbnail.decode(try jpeg(width: 1600, height: 1200, orientation: 6)))
        #expect(thumbnail.pixelWidth == 225)
        #expect(thumbnail.pixelHeight == 300)
    }

    @Test("bytes that are not a picture give nothing")
    func notAnImage() {
        #expect(CaptureShotThumbnail.decode(Data("not a photo".utf8)) == nil)
    }
}
