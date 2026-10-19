import CoreGraphics
import Foundation
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// Everything a camera model under test talks to.
@MainActor
final class CaptureModelHarness {
    let photos: CaptureTestPhotos
    let pipeline = CaptureTestPipeline()
    let items = CaptureTestItems()
    let invalidator = SharedSeamsInvalidationCounter()
    let toasts = SharedSeamsToastRecorder()
    let haptics = SharedSeamsHapticRecorder()
    let telemetry = RecordingTelemetry()
    let navigation = CaptureTestNavigation<CaptureNavigation>()
    let authorization: CaptureTestAuthorization
    private(set) var delivered: [StoredImage] = []
    var deliveryAccepted = true
    let clock = ManualClock()
    nonisolated static let now: Int64 = 1_760_000_000_000

    init(authorization: CameraAuthorization = .authorized, holdStores: Bool = false) {
        photos = CaptureTestPhotos(holdStores: holdStores)
        self.authorization = CaptureTestAuthorization(authorization)
    }

    func model(_ route: CaptureRoute = CaptureRoute(containerId: "c1"), request: Bool = false, running: Bool = true) -> CaptureModel {
        var deliver: (@MainActor @Sendable (StoredImage) -> Bool)?
        if request {
            deliver = { [self] photo in
                delivered.append(photo)
                return deliveryAccepted
            }
        }
        let model = CaptureModel(
            route: route,
            deliverPhoto: deliver,
            permission: authorization.model(.capture, telemetry: telemetry),
            photos: photos,
            fastCapture: pipeline,
            items: items,
            invalidator: invalidator,
            toasts: toasts,
            haptics: haptics.player,
            telemetry: TelemetryReporter(sink: telemetry),
            clock: clock,
            now: { CaptureModelHarness.now },
            navigate: navigation.navigate
        )
        if running { model.sessionStarted() }
        return model
    }
}

private let captureShot = CapturedPhoto(data: Data("heic".utf8), cropAspect: CGSize(width: 393, height: 852))

@Suite("CaptureModel: modes and chrome (app/capture/index.tsx)")
@MainActor
struct CaptureModelChromeTests {
    @Test("opens fast only when asked for and not for a request; a request has no mode picker or Type it instead")
    func initialMode() {
        let harness = CaptureModelHarness()
        #expect(harness.model(CaptureRoute(containerId: "c1", mode: .fast)).mode == .fast)
        #expect(harness.model(CaptureRoute(containerId: "c1")).mode == .single)
        let request = harness.model(CaptureRoute(containerId: "c1", mode: .fast), request: true)
        #expect(request.mode == .single)
        #expect(request.isRequest)
        #expect(!request.showsModePicker)
        #expect(!request.offersTypeInstead)
        #expect(!request.permissionOffersManual)
        request.selectMode(.fast)
        #expect(request.mode == .single)
        #expect(CaptureRoute.quickSnap == CaptureRoute(containerId: DropZone.containerId, mode: .fast))
    }

    @Test("hint, flash and Done labels follow the state")
    func chrome() {
        let harness = CaptureModelHarness()
        let model = harness.model()
        #expect(model.hint == "Tap to focus, then fill the frame.")
        #expect(model.flashLabel == "Flash, off")
        model.toggleFlash()
        #expect(model.flashOn)
        #expect(model.flashLabel == "Flash, on")
        model.selectMode(.fast)
        model.selectMode(.fast)
        // The segmented control's choice haptic, only for a real change.
        #expect(harness.haptics.played == [.choice])
        #expect(model.hint == "Keep shooting. Each photo becomes an item.")
        #expect(model.isDoneDimmed)
        #expect(model.doneAccessibilityLabel == "Done")
        #expect(model.fastStatus == nil)
        #expect(model.droppedNotice == nil)
    }

    @Test("the Into pill shows the drop zone at once, and a container once its place has loaded")
    func intoPill() {
        let harness = CaptureModelHarness()
        let dropZone = harness.model(CaptureRoute(containerId: DropZone.containerId, mode: .fast))
        #expect(dropZone.showsIntoPill)
        #expect(dropZone.intoAccessibilityLabel == "Photos go into the drop zone")

        let container = harness.model(CaptureRoute(containerId: "c1"))
        #expect(!container.showsIntoPill)
        container.intoLoaded(CaptureIntoPlace(containerId: "c1", containerName: "Tool chest", containerShortCode: "CAB-J92R", spaceId: "s1", spaceName: "Garage", spaceColor: "#5B8DEF"))
        #expect(container.showsIntoPill)
        #expect(container.intoAccessibilityLabel == "Photos go into Tool chest, in Garage, label C A B, J 9 2 R")
    }

    @Test("a camera that cannot start says so")
    func didNotStart() {
        let model = CaptureModelHarness().model()
        model.cameraFailedToStart()
        #expect(model.error == "The camera did not start. Close and try again, or type it instead.")
        #expect(!model.isSessionRunning)
        #expect(!model.isShutterEnabled)
    }
}

@Suite("CaptureModel: single mode (05 §4.4-4.5)")
@MainActor
struct CaptureModelSingleTests {
    @Test("ignores the shutter until the session runs, so an early press never shows noPhoto")
    func shutterBeforeSession() async {
        let harness = CaptureModelHarness()
        let model = harness.model(running: false)
        #expect(!model.isShutterEnabled)
        var asked = 0
        await model.shutterPressed { asked += 1; return captureShot }
        #expect(asked == 0)
        #expect(model.error == nil)
        model.sessionStarted()
        #expect(model.isShutterEnabled)
    }

    @Test("stores the photo with the preview crop, logs photo_captured and opens the Add sheet with it")
    func storesAndOpensAdd() async {
        let harness = CaptureModelHarness()
        let model = harness.model()
        await model.shutterPressed { captureShot }

        #expect(harness.photos.stores.count == 1)
        #expect(harness.photos.stores.first?.data == captureShot.data)
        #expect(harness.photos.stores.first?.crop == captureShot.cropAspect)
        #expect(harness.navigation.destinations == [.addItem(containerId: "c1", photo: CaptureTestPhotos.stored)])
        #expect(harness.telemetry.entries == [RecordingTelemetry.Entry(level: "event", name: "photo_captured", payload: [
            "source": .string("camera"), "byteSize": .int(52_000),
        ])])
        // The camera is leaving: it stays busy, and nothing leaves twice.
        #expect(model.processing)
        model.close()
        model.continueManually()
        #expect(harness.navigation.destinations.count == 1)
    }

    @Test("request mode hands the photo back once and goes back")
    func requestDelivers() async {
        let harness = CaptureModelHarness()
        let model = harness.model(request: true)
        await model.shutterPressed { captureShot }
        #expect(harness.delivered == [CaptureTestPhotos.stored])
        #expect(harness.navigation.destinations == [.back])
        await model.shutterPressed { captureShot }
        #expect(harness.delivered.count == 1)
        #expect(harness.photos.stores.count == 1)
    }

    @Test("a request nobody waits for any more falls through to a new item, so the photo is kept")
    func requestFallsThrough() async {
        let harness = CaptureModelHarness()
        harness.deliveryAccepted = false
        let model = harness.model(request: true)
        await model.shutterPressed { captureShot }
        #expect(harness.delivered.count == 1)
        #expect(harness.navigation.destinations == [.addItem(containerId: "c1", photo: CaptureTestPhotos.stored)])
        #expect(harness.photos.deleted.isEmpty)
    }

    @Test("a capture that throws shows noPhoto and leaves the camera as it was")
    func captureThrows() async {
        let harness = CaptureModelHarness()
        let model = harness.model()
        await model.shutterPressed { throw CaptureTestError() }
        #expect(model.error == "The camera did not take the photo. Try again, or type it instead.")
        #expect(!model.processing)
        #expect(harness.navigation.destinations.isEmpty)
        // The notice offers Type it instead.
        #expect(model.offersTypeInstead)
    }

    @Test("a camera that gives no photo does nothing")
    func noPhoto() async {
        let harness = CaptureModelHarness()
        let model = harness.model()
        await model.shutterPressed { nil }
        #expect(model.error == nil)
        #expect(harness.photos.stores.isEmpty)
    }

    @Test("no free space: noRoom, nothing stored")
    func noRoom() async {
        let harness = CaptureModelHarness()
        harness.photos.hasRoom = false
        let model = harness.model()
        await model.shutterPressed { captureShot }
        #expect(model.error == "There is not enough free space on this phone for a photo. Free some space, or type it instead.")
        #expect(harness.photos.stores.isEmpty)
        #expect(!model.processing)
    }

    @Test("a photo that could not be stored logs photo_capture_failed and says notProcessed")
    func storeFails() async {
        let harness = CaptureModelHarness()
        harness.photos.result = .failure(CaptureTestError())
        let model = harness.model()
        await model.shutterPressed { captureShot }
        #expect(model.error == "That photo could not be saved. Try again, or type it instead.")
        #expect(!model.processing)
        #expect(harness.telemetry.entries == [RecordingTelemetry.Entry(level: "error", name: "photo_capture_failed", payload: ["source": .string("camera")])])
        #expect(harness.navigation.destinations.isEmpty)
    }

    @Test("leaving while the photo is stored deletes both files and goes nowhere else")
    func leaveMidStore() async throws {
        let harness = CaptureModelHarness(holdStores: true)
        let model = harness.model()
        let shot = Task { await model.shutterPressed { captureShot } }
        try #require(harness.photos.latch != nil)
        await harness.photos.latch?.waitForArrivals(1)
        #expect(model.processing)
        #expect(model.hint == "Saving your photo…")
        #expect(!model.canChangeMode)
        #expect(!model.isLibraryEnabled)

        model.close()
        await harness.photos.latch?.release(.success(CaptureTestPhotos.stored))
        await shot.value

        #expect(harness.navigation.destinations == [.back])
        #expect(harness.photos.deleted == [[CaptureTestPhotos.stored.uri, CaptureTestPhotos.stored.thumbUri]])
    }

    @Test("a second press while a photo is taken does not take another")
    func takingGuard() async {
        let harness = CaptureModelHarness()
        let model = harness.model()
        var presses = 0
        await model.shutterPressed {
            presses += 1
            await model.shutterPressed { presses += 1; return captureShot }
            return captureShot
        }
        #expect(presses == 1)
    }

    @Test("Type it instead opens the Add sheet without a photo, or goes back to the waiting one, once")
    func typeInstead() {
        let harness = CaptureModelHarness()
        let model = harness.model()
        model.continueManually()
        model.continueManually()
        #expect(harness.navigation.destinations == [.addItem(containerId: "c1", photo: nil)])

        let requestHarness = CaptureModelHarness()
        requestHarness.model(request: true).continueManually()
        #expect(requestHarness.navigation.destinations == [.back])
    }

    @Test("✕ in single mode goes back")
    func closeSingle() {
        let harness = CaptureModelHarness()
        let model = harness.model()
        model.close()
        model.close()
        #expect(harness.navigation.destinations == [.back])
        #expect(harness.invalidator.count == 0)
    }
}

@Suite("CaptureModel: library import (05 §4.8)")
@MainActor
struct CaptureModelLibraryTests {
    @Test("one picker at a time, never while a photo is processed")
    func guards() async throws {
        let harness = CaptureModelHarness(holdStores: true)
        let model = harness.model()
        #expect(model.beginLibraryPick())
        #expect(!model.beginLibraryPick())
        await model.finishLibraryPick(.cancelled)
        #expect(harness.photos.stores.isEmpty)
        #expect(model.beginLibraryPick())

        let pick = Task { await model.finishLibraryPick(.picked(.data(Data("photo".utf8)))) }
        await harness.photos.latch?.waitForArrivals(1)
        #expect(!model.beginLibraryPick())
        await harness.photos.latch?.release(.success(CaptureTestPhotos.stored))
        await pick.value
    }

    @Test("a picked photo is stored whole and opens the Add sheet, logged as from the library")
    func picked() async {
        let harness = CaptureModelHarness()
        let model = harness.model(CaptureRoute(containerId: DropZone.containerId, mode: .fast))
        #expect(model.beginLibraryPick())
        await model.finishLibraryPick(.picked(.data(Data("photo".utf8))))
        #expect(harness.photos.stores.first?.crop == nil)
        #expect(harness.navigation.destinations == [.addItem(containerId: DropZone.containerId, photo: CaptureTestPhotos.stored)])
        #expect(harness.telemetry.events.first?.payload["source"] == .string("library"))
    }

    @Test("a photo that could not be opened says libraryFailed over the camera")
    func failed() async {
        let harness = CaptureModelHarness()
        let model = harness.model()
        _ = model.beginLibraryPick()
        await model.finishLibraryPick(.failed)
        #expect(model.error == "That photo could not be opened.")
        #expect(model.beginLibraryPick())
    }

    @Test("on the permission screen, which has no notice, problems arrive as error toasts")
    func permissionScreenToasts() async {
        let harness = CaptureModelHarness(authorization: .denied)
        harness.photos.hasRoom = false
        let model = harness.model()
        #expect(model.permission.screen == .blocked)
        _ = model.beginLibraryPick()
        await model.finishLibraryPick(.picked(.data(Data())))
        _ = model.beginLibraryPick()
        await model.finishLibraryPick(.failed)
        #expect(model.error == nil)
        #expect(harness.toasts.messages == [
            "There is not enough free space on this phone for a photo. Free some space, or type it instead.",
            "That photo could not be opened.",
        ])
        #expect(harness.toasts.shown.allSatisfy { $0.options.tone == .error })
    }
}

@Suite("CaptureModel: Quick Snap (05 §4.6-4.7)")
@MainActor
struct CaptureModelFastTests {
    @Test("a shot lands at once: count, haptic, last shot, flash, and a pipeline with the crop")
    func shotLands() async {
        let harness = CaptureModelHarness()
        let model = harness.model(CaptureRoute(containerId: DropZone.containerId, mode: .fast))
        await model.shutterPressed { captureShot }

        #expect(model.captured == 1)
        #expect(model.isLocked)
        #expect(!model.canChangeMode)
        #expect(model.modePickerHint == "Finish this set first")
        #expect(!model.offersTypeInstead)
        #expect(harness.haptics.played == [.tap])
        #expect(model.lastShot == captureShot)
        #expect(model.shotSerial == 1)
        #expect(model.fastStatus == FastStatus(text: "Identifying 1…", settled: false))
        #expect(model.doneAccessibilityLabel == "Done, 1 photo taken")
        #expect(!model.isDoneDimmed)
        await captureTestSettle()
        let calls = await harness.pipeline.calls
        #expect(calls.count == 1)
        #expect(calls.first?.containerId == DropZone.containerId)
        #expect(calls.first?.crop == captureShot.cropAspect)
        #expect(calls.first?.data == captureShot.data)
        // The single path is not used.
        #expect(harness.photos.stores.isEmpty)
        model.selectMode(.single)
        #expect(model.mode == .fast)
    }

    @Test("pipelines report as they finish: identified, unnamed, dropped, with their telemetry")
    func pipelinesReport() async {
        let harness = CaptureModelHarness()
        let model = harness.model(CaptureRoute(containerId: DropZone.containerId, mode: .fast))
        for _ in 0..<3 { await model.shutterPressed { captureShot } }
        await harness.pipeline.latch.waitForArrivals(3)
        #expect(model.fastStatus?.text == "Identifying 3…")

        await harness.pipeline.finish(.success(.recognized(itemId: "i1", name: "Drill")))
        await captureTestEventually { model.completed == 1 }
        await harness.pipeline.finish(.success(.unrecognized(itemId: "i2", reason: .lowConfidence)))
        await captureTestEventually { model.completed == 2 }
        await harness.pipeline.finish(.failure(CaptureTestError()))
        await model.waitForPipelines()

        #expect(model.captured == 2)
        #expect(model.completed == 2)
        #expect(model.recognized == 1)
        #expect(model.dropped == 1)
        #expect(model.fastStatus == FastStatus(text: "1 identified · 1 to name", settled: true))
        #expect(model.droppedNotice == "1 photo could not be saved. Nothing else was lost.")
        #expect(harness.invalidator.count == 2)
        // `mode` and `reason` are not on the allowlist (09 §9.2).
        #expect(harness.telemetry.entries == [
            RecordingTelemetry.Entry(level: "event", name: "photo_captured", payload: ["source": .string("camera")]),
            RecordingTelemetry.Entry(level: "event", name: "photo_captured", payload: ["source": .string("camera")]),
            RecordingTelemetry.Entry(level: "event", name: "recognition_unusable", payload: [:]),
            RecordingTelemetry.Entry(level: "error", name: "fast_capture_failed", payload: ["source": .string("camera")]),
        ])
    }

    @Test("when every shot failed the set unlocks again, and ✕ just goes back")
    func allFailed() async {
        let harness = CaptureModelHarness()
        let model = harness.model(CaptureRoute(containerId: "c1", mode: .fast))
        await model.shutterPressed { captureShot }
        await harness.pipeline.latch.waitForArrivals(1)
        await harness.pipeline.finish(.failure(CaptureTestError()))
        await model.waitForPipelines()
        #expect(model.captured == 0)
        #expect(!model.isLocked)
        #expect(model.offersTypeInstead)
        #expect(model.droppedNotice != nil)
        model.close()
        #expect(harness.navigation.destinations == [.back])
    }

    @Test("no free space: noRoom before the shot, and the camera is not asked")
    func noRoom() async {
        let harness = CaptureModelHarness()
        harness.photos.hasRoom = false
        let model = harness.model(CaptureRoute(containerId: "c1", mode: .fast))
        var asked = 0
        await model.shutterPressed { asked += 1; return captureShot }
        #expect(asked == 0)
        #expect(model.error == "There is not enough free space on this phone for a photo. Free some space, or type it instead.")
        #expect(model.captured == 0)
    }

    @Test("a capture that throws shows noPhoto; the next good shot clears it")
    func captureThrows() async {
        let harness = CaptureModelHarness()
        let model = harness.model(CaptureRoute(containerId: "c1", mode: .fast))
        await model.shutterPressed { throw CaptureTestError() }
        #expect(model.error == "The camera did not take the photo. Try again, or type it instead.")
        #expect(model.captured == 0)
        #expect(!model.shooting)
        await model.shutterPressed { captureShot }
        #expect(model.error == nil)
        #expect(model.captured == 1)
    }

    @Test("the shutter is busy while the camera takes a shot: a second press is ignored and drawn dimmed")
    func shutterBusy() async {
        let harness = CaptureModelHarness()
        let model = harness.model(CaptureRoute(containerId: "c1", mode: .fast))
        var presses = 0
        await model.shutterPressed {
            presses += 1
            #expect(model.shooting)
            #expect(!model.isShutterEnabled)
            await model.shutterPressed { presses += 1; return captureShot }
            return captureShot
        }
        #expect(presses == 1)
        #expect(model.captured == 1)
        #expect(!model.shooting)
    }

    @Test("Done with shots invalidates and opens the review with the session start and the count")
    func doneOpensReview() async {
        let harness = CaptureModelHarness()
        let model = harness.model(CaptureRoute(containerId: DropZone.containerId, mode: .fast))
        await model.shutterPressed { captureShot }
        await model.shutterPressed { captureShot }
        model.finishFast()
        model.finishFast()
        model.close()
        #expect(harness.invalidator.count == 1)
        #expect(harness.navigation.destinations == [.review(QuickSnapReviewRoute(containerId: DropZone.containerId, since: CaptureModelHarness.now, expected: 2))])
    }

    @Test("✕ on a set with shots also ends on the review")
    func closeOpensReview() async {
        let harness = CaptureModelHarness()
        let model = harness.model(CaptureRoute(containerId: "c1", mode: .fast))
        await model.shutterPressed { captureShot }
        model.close()
        #expect(harness.navigation.destinations == [.review(QuickSnapReviewRoute(containerId: "c1", since: CaptureModelHarness.now, expected: 1))])
    }

    @Test("Done before the first shot just goes back")
    func doneWithoutShots() {
        let harness = CaptureModelHarness()
        let model = harness.model(CaptureRoute(containerId: "c1", mode: .fast))
        model.finishFast()
        #expect(harness.invalidator.count == 1)
        #expect(harness.navigation.destinations == [.back])
    }

    @Test("Keep shooting continues the set: same start, and the review still expects the earlier photos (U6)")
    func keepShootingKeepsCount() async {
        let harness = CaptureModelHarness()
        let since: Int64 = 1_700_000_000_000
        let model = harness.model(CaptureRoute(containerId: DropZone.containerId, mode: .fast, since: since, expectedBase: 3))
        await model.shutterPressed { captureShot }
        await model.shutterPressed { captureShot }
        model.finishFast()
        #expect(harness.navigation.destinations == [.review(QuickSnapReviewRoute(containerId: DropZone.containerId, since: since, expected: 5))])
        // The pill and Done count this camera's shots only.
        #expect(model.captured == 2)
    }

    @Test("pipelines outlive the camera: one finishing after Done still invalidates")
    func pipelinesOutliveCamera() async {
        let harness = CaptureModelHarness()
        let model = harness.model(CaptureRoute(containerId: "c1", mode: .fast))
        await model.shutterPressed { captureShot }
        model.finishFast()
        model.disappeared()
        #expect(harness.invalidator.count == 1)
        await harness.pipeline.latch.waitForArrivals(1)
        await harness.pipeline.finish(.success(.recognized(itemId: "i1", name: "Drill")))
        await model.waitForPipelines()
        #expect(harness.invalidator.count == 2)
    }

    @Test("the session start is stamped at the first press, before the photo exists, even when there is no room")
    func sessionStartStamped() async {
        let harness = CaptureModelHarness()
        harness.photos.hasRoom = false
        let model = harness.model(CaptureRoute(containerId: "c1", mode: .fast))
        await model.shutterPressed { captureShot }
        harness.photos.hasRoom = true
        await model.shutterPressed { captureShot }
        model.finishFast()
        #expect(harness.navigation.destinations == [.review(QuickSnapReviewRoute(containerId: "c1", since: CaptureModelHarness.now, expected: 1))])
    }
}
