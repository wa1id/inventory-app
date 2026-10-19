import CoreGraphics
import Foundation
import InventoryCore
import InventoryServices
import InventoryStrings
import Observation

/// The capture screen without the camera hardware (RN `app/capture/index.tsx`, 05 §4): single,
/// request and fast (Quick Snap) modes, library import, notices and errors, and how the camera
/// leaves.
///
/// The view owns the AVFoundation session and reports to this model:
/// - ``sessionStarted()`` / ``sessionStopped()`` / ``cameraFailedToStart()``;
/// - ``shutterPressed(capture:)`` with a closure that takes the still, so the model's guards hold
///   across the capture as RN's refs did;
/// - ``beginLibraryPick()`` before presenting the picker and ``finishLibraryPick(_:)`` with what it
///   gave;
/// - ``close()``, ``finishFast()`` (Done), ``continueManually()`` (Type it instead) and
///   ``disappeared()``.
///
/// Leaving happens once, through `navigate` (RN `closedRef`). A single photo still being stored
/// when the camera leaves is deleted rather than kept. Fast-mode pipelines outlive the screen: they
/// run in ``FastCapturing`` (app-scoped) and still invalidate when they finish.
///
/// Request mode (`deliverPhoto` set; the Add sheet waiting for one photo) hands the stored photo
/// back at most once and goes back. When the closure answers that nobody is waiting any more, the
/// photo opens a new item instead, so it is never thrown away (RN `deliverResult` false).
@MainActor
@Observable
public final class CaptureModel {
    /// `drop-zone` or a container id.
    public let containerId: String
    /// Opened for one photo (the Add sheet's): single only, no mode picker, no Type it instead.
    public let isRequest: Bool
    /// The permission gate this screen shows while the camera is not granted.
    public let permission: CameraPermissionModel
    /// The focus square over the preview.
    public let focus: TapToFocusModel

    /// Single or fast. Changed with ``selectMode(_:)``.
    public private(set) var mode: CaptureMode
    /// The flash for the next shot (off by default).
    public private(set) var flashOn = false
    /// Single mode: the stored photo is being processed. The shutter spins, the library button and
    /// the mode picker are disabled.
    public private(set) var processing = false
    /// The camera notice (assertive), or nil.
    public private(set) var error: String?
    /// Fast: shutter presses that produced a photo, less those whose pipeline failed.
    public private(set) var captured = 0
    /// Fast: pipelines finished.
    public private(set) var completed = 0
    /// Fast: pipelines that ended with a name.
    public private(set) var recognized = 0
    /// Fast: pipelines that failed to write the photo or the row.
    public private(set) var dropped = 0
    /// Fast: the camera hardware is busy with a shot (the shutter dims).
    public private(set) var shooting = false
    /// Fast: the newest shot, for the last-shot tile (draw it downsampled).
    public private(set) var lastShot: CapturedPhoto?
    /// Fast: bumped on every landed shot; drives the shutter flash.
    public private(set) var shotSerial = 0
    /// The capture session is running; the shutter works only then (05 §19: no `noPhoto` from an
    /// early press).
    public private(set) var isSessionRunning = false
    /// The Into pill's place once loaded (nil for the drop zone or while loading).
    public private(set) var into: CaptureIntoPlace?

    private let route: CaptureRoute
    private let deliverPhoto: (@MainActor @Sendable (StoredImage) -> Bool)?
    private let photos: any PhotoStoring
    private let fastCapture: any FastCapturing
    private let items: any ItemsRepository
    private let invalidator: any InventoryInvalidating
    private let toasts: any ToastPresenting
    private let haptics: HapticPlayer
    private let telemetry: TelemetryReporter
    private let now: @Sendable () -> Int64
    private let navigate: @MainActor @Sendable (CaptureNavigation) -> Void

    // RN refs: guards that do not draw.
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var taking = false
    @ObservationIgnored private var shutterBusy = false
    @ObservationIgnored private var picking = false
    @ObservationIgnored private var sessionStart: Int64?
    @ObservationIgnored private var pipelines: [Task<Void, Never>] = []

    /// - Parameters:
    ///   - route: The container, the asked-for mode, and (after Keep shooting) the set's start and
    ///     the photos already expected.
    ///   - deliverPhoto: Request mode: hands the stored photo to the waiting Add sheet and answers
    ///     whether anybody took it.
    ///   - permission: The screen's camera permission (purpose `capture`).
    ///   - photos: The image store; checked for room before every shot, and where single photos
    ///     are stored and deleted.
    ///   - fastCapture: The app-scoped Quick Snap pipeline.
    ///   - items: The items repository in use now (local, or the household's).
    ///   - invalidator: Bumps the revision when pipelines land and when Done is pressed.
    ///   - toasts: Errors while the permission screen is up go here (it has no notice).
    ///   - haptics: A fast shot that landed plays `.tap`.
    ///   - now: Epoch ms, for the session start.
    ///   - navigate: Called at most once, when the camera leaves.
    public init(
        route: CaptureRoute,
        deliverPhoto: (@MainActor @Sendable (StoredImage) -> Bool)? = nil,
        permission: CameraPermissionModel,
        photos: any PhotoStoring,
        fastCapture: any FastCapturing,
        items: any ItemsRepository,
        invalidator: any InventoryInvalidating,
        toasts: any ToastPresenting,
        haptics: @escaping HapticPlayer,
        telemetry: TelemetryReporter = .shared,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Int64 = { epochMillis() },
        navigate: @escaping @MainActor @Sendable (CaptureNavigation) -> Void
    ) {
        self.route = route
        containerId = route.containerId
        isRequest = deliverPhoto != nil
        self.deliverPhoto = deliverPhoto
        self.permission = permission
        focus = TapToFocusModel(clock: clock)
        // A camera opened for one photo is always single (RN `index.tsx:90-92`).
        mode = route.mode == .fast && deliverPhoto == nil ? .fast : .single
        sessionStart = route.since
        self.photos = photos
        self.fastCapture = fastCapture
        self.items = items
        self.invalidator = invalidator
        self.toasts = toasts
        self.haptics = haptics
        self.telemetry = telemetry
        self.now = now
        self.navigate = navigate
    }

    // MARK: Derived state

    /// Fast mode is on.
    public var isFast: Bool { mode == .fast }

    /// A fast set with a shot can only be finished with Done: the mode picker and Type it instead
    /// go away (RN `locked`).
    public var isLocked: Bool { isFast && captured > 0 }

    /// The mode picker is shown (never in request mode).
    public var showsModePicker: Bool { !isRequest }

    /// The mode picker accepts a change: not while locked, and not while a single photo is saved
    /// (its hand-over would otherwise carry off a fast set begun meanwhile).
    public var canChangeMode: Bool { !isLocked && !processing }

    /// The mode picker's accessibility hint while locked (`strings.capture.finishSetFirst`).
    public var modePickerHint: String? { isLocked ? L10n.Capture.finishSetFirst : nil }

    /// "Type it instead" is offered: on the error notice, and as the single-mode keyboard button.
    public var offersTypeInstead: Bool { !isRequest && !isLocked }

    /// The status pill, shown in fast mode once a shot has landed.
    public var fastStatus: FastStatus? {
        guard isFast, captured > 0 else { return nil }
        return CaptureFlow.fastStatus(FastTallies(captured: captured, completed: completed, recognized: recognized))
    }

    /// The polite second notice once pipelines have failed (`strings.capture.failedSome`).
    public var droppedNotice: String? {
        dropped > 0 ? L10n.Capture.failedSome(count: dropped) : nil
    }

    /// The caption under the shutter row.
    public var hint: String {
        if isFast { return L10n.Capture.fastHint }
        return processing ? L10n.Capture.saving : L10n.Capture.singleHint
    }

    /// The shutter takes a press: the session runs and nothing is in the way. The view still
    /// sends presses; the model ignores the ones that do not count, as RN did.
    public var isShutterEnabled: Bool {
        guard isSessionRunning else { return false }
        return isFast ? !shooting : !processing
    }

    /// Single-mode library button: disabled while a photo is processed.
    public var isLibraryEnabled: Bool { !processing }

    /// Done is dimmed before the first shot, when it just closes the camera.
    public var isDoneDimmed: Bool { captured == 0 }

    /// Done's accessibility label (`strings.capture.doneA11y`).
    public var doneAccessibilityLabel: String { L10n.Capture.doneA11y(count: captured) }

    /// The flash button's label: the state it is in now.
    public var flashLabel: String { L10n.Capture.flash(on: flashOn) }

    /// The Into pill is shown: always for the drop zone, otherwise once the place has loaded.
    public var showsIntoPill: Bool { containerId == DropZone.containerId || into != nil }

    /// The Into pill, spoken.
    public var intoAccessibilityLabel: String { CaptureFlow.intoA11y(containerId: containerId, place: into) }

    /// The permission screen offers "Type it instead" (never in request mode).
    public var permissionOffersManual: Bool { !isRequest }

    // MARK: Inputs from the view

    /// The capture session started running.
    public func sessionStarted() {
        isSessionRunning = true
    }

    /// The capture session stopped (background, interruption, leaving).
    public func sessionStopped() {
        isSessionRunning = false
    }

    /// The camera could not be configured or started (not a `mediaServicesWereReset` restart).
    public func cameraFailedToStart() {
        isSessionRunning = false
        error = L10n.Capture.didNotStart
    }

    /// The Into pill's read finished.
    public func intoLoaded(_ place: CaptureIntoPlace?) {
        into = place
    }

    /// Flips the flash between off and on.
    public func toggleFlash() {
        flashOn.toggle()
    }

    /// Switches mode when the picker allows it, with the `choice` haptic for a real change (RN
    /// `SegmentedControl`; the view adds no feedback of its own).
    public func selectMode(_ next: CaptureMode) {
        guard showsModePicker, canChangeMode, next != mode else { return }
        haptics(.choice)
        mode = next
    }

    /// The shutter: takes a still through `capture` and handles it for the current mode. `capture`
    /// returns nil when the camera gave no photo, and throws when it failed
    /// (`strings.capture.noPhoto`).
    public func shutterPressed(capture: @escaping @MainActor () async throws -> CapturedPhoto?) async {
        switch mode {
        case .single: await takePhoto(capture)
        case .fast: await takeFastPhoto(capture)
        }
    }

    /// The library button (or "Choose a photo instead"): true when the picker may open. False while
    /// a photo is processed or the picker is already open.
    public func beginLibraryPick() -> Bool {
        guard !processing, !picking else { return false }
        picking = true
        return true
    }

    /// The picker closed (RN `pickFromLibrary` after `launchImageLibraryAsync`). A picked photo goes
    /// through the single-photo path, whatever the mode.
    // RN: app/capture/index.tsx:348-373
    public func finishLibraryPick(_ result: CaptureLibraryPick) async {
        picking = false
        switch result {
        case .cancelled:
            return
        case .failed:
            // PHPicker needs no permission, so RN's `libraryDeniedBody` branch cannot happen here.
            report(L10n.Capture.libraryFailed)
        case .picked(let source):
            await handleCaptured(source, cropToAspect: nil, source: "library")
        }
    }

    /// ✕: a fast set with shots ends on its review; otherwise the camera closes (RN `close`).
    // RN: app/capture/index.tsx:321-330
    public func close() {
        guard !closed else { return }
        if CaptureFlow.leaveCamera(mode: mode, captured: captured) == .review {
            finishFast()
            return
        }
        closed = true
        navigate(.back)
    }

    /// Done (RN `finishFast`): invalidates, then goes back with no shots or on to the review.
    ///
    /// The review expects this session's shots plus the photos the set already expected before
    /// Keep shooting (``CaptureRoute/expectedBase``), so photos still in flight from the first
    /// part are waited for (DECISIONS U6; RN passed only this session's count, 05 C7).
    // RN: app/capture/index.tsx:301-318
    public func finishFast() {
        guard !closed else { return }
        closed = true
        invalidator.invalidate()
        if captured == 0 {
            navigate(.back)
            return
        }
        navigate(.review(QuickSnapReviewRoute(
            containerId: containerId,
            // captured > 0 guarantees a shutter press stamped the session start.
            since: sessionStart ?? now(),
            expected: route.expectedBase + captured
        )))
    }

    /// Type it instead: back to the waiting Add sheet in request mode, otherwise the Add sheet for
    /// this container without a photo (RN `continueManually`).
    // RN: app/capture/index.tsx:158-167
    public func continueManually() {
        guard !closed else { return }
        closed = true
        if isRequest {
            navigate(.back)
        } else {
            navigate(.addItem(containerId: containerId, photo: nil))
        }
    }

    /// The screen went away: anything still being stored is no longer wanted.
    public func disappeared() {
        closed = true
        isSessionRunning = false
        focus.reset()
    }

    /// Waits for every Quick Snap pipeline this camera started (tests; the screen never waits).
    public func waitForPipelines() async {
        while !pipelines.isEmpty {
            let running = pipelines
            pipelines.removeAll()
            for task in running { await task.value }
        }
    }

    // MARK: Single mode

    // RN: app/capture/index.tsx:220-231
    private func takePhoto(_ capture: @MainActor () async throws -> CapturedPhoto?) async {
        guard isSessionRunning, !processing, !taking else { return }
        taking = true
        defer { taking = false }
        let photo: CapturedPhoto?
        do {
            photo = try await capture()
        } catch {
            self.error = L10n.Capture.noPhoto
            return
        }
        if let photo {
            await handleCaptured(.data(photo.data), cropToAspect: photo.cropAspect, source: "camera")
        }
    }

    /// Stores a single photo and leaves with it (RN `handleCaptured`, 05 §4.4).
    // RN: app/capture/index.tsx:169-218
    private func handleCaptured(_ image: ImageSource, cropToAspect: CGSize?, source: String) async {
        // Closed while the shutter was still taking it: nothing to save it for.
        guard !closed else { return }
        guard photos.hasRoomForPhoto() else {
            report(L10n.Capture.noRoom)
            return
        }

        processing = true
        error = nil

        let stored: StoredImage
        do {
            stored = try await photos.storeItemPhoto(image, cropToAspect: cropToAspect)
        } catch {
            telemetry.error("photo_capture_failed", ["source": .string(source)])
            // Nothing to say to someone who has already closed the camera.
            guard !closed else { return }
            processing = false
            report(L10n.Capture.notProcessed)
            return
        }
        telemetry.event("photo_captured", [
            "source": .string(source),
            "byteSize": stored.byteSize.map(TelemetryValue.int) ?? .null,
        ])

        // Closed while the photo was being saved: nobody will use it now.
        if closed {
            photos.deleteStoredPhotos([stored.uri, stored.thumbUri])
            return
        }
        closed = true

        // Opened for one photo: hand it back and close. Nobody waiting any more falls through to a
        // new item with this photo, so the photo is never thrown away.
        if let deliverPhoto, deliverPhoto(stored) {
            navigate(.back)
            return
        }
        navigate(.addItem(containerId: containerId, photo: stored))
    }

    // MARK: Fast mode

    /// One tap per item, no form in between (RN `takeFastPhoto`, 05 §4.6). The wait ends at the
    /// shutter; the pipeline runs on its own so the camera is ready for the next thing at once.
    // RN: app/capture/index.tsx:241-299
    private func takeFastPhoto(_ capture: @MainActor () async throws -> CapturedPhoto?) async {
        guard isSessionRunning, !shutterBusy else { return }
        // Before the photo exists, so every row this press creates sorts after it.
        if sessionStart == nil { sessionStart = now() }
        guard photos.hasRoomForPhoto() else {
            error = L10n.Capture.noRoom
            return
        }

        shutterBusy = true
        shooting = true
        var photo: CapturedPhoto?
        do {
            photo = try await capture()
        } catch {
            self.error = L10n.Capture.noPhoto
        }
        shutterBusy = false
        shooting = false

        guard let photo else { return }

        captured += 1
        error = nil
        // Felt, and seen in the flash and the last-shot tile; never holds up the next shot.
        haptics(.tap)
        lastShot = photo
        shotSerial += 1

        let fastCapture = fastCapture
        let items = items
        let containerId = containerId
        pipelines.append(Task { [self] in
            do {
                let outcome = try await fastCapture.capture(
                    containerId: containerId,
                    photo: .data(photo.data),
                    cropToAspect: photo.cropAspect,
                    items: items
                )
                completed += 1
                telemetry.event("photo_captured", ["source": .string("camera"), "mode": .string("fast")])
                switch outcome {
                case .recognized:
                    recognized += 1
                case .unrecognized(_, let reason):
                    telemetry.event("recognition_unusable", ["reason": .string(reason.rawValue)])
                }
                // Keeps the lists behind the camera honest as rows land.
                invalidator.invalidate()
            } catch {
                telemetry.error("fast_capture_failed", ["source": .string("camera")])
                captured = max(0, captured - 1)
                dropped += 1
            }
        })
    }

    // MARK: Notices

    /// Over the camera as a notice; on the permission screen, which has none, as an error toast
    /// (RN `report`).
    // RN: app/capture/index.tsx:153-156
    private func report(_ message: String) {
        if permission.isGranted {
            error = message
        } else {
            toasts.show(ToastOptions(message: message, tone: .error))
        }
    }
}
