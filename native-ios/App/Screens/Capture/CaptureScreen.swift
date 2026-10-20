import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryServices
import InventoryStrings

/// The camera, full screen (RN `app/capture/index.tsx`, 05 §4): single, request (with `request`,
/// the Add sheet waiting for one photo) or fast (Quick Snap), the permission gate, library import
/// and the full chrome.
///
/// `CaptureModel` holds the flow; this view builds it once, owns the camera for the screen's life
/// and maps the model's exits onto the router through `CaptureNavigator` (back closes the cover,
/// the Add sheet replaces it, the review is pushed inside it). `disappeared()` runs from the
/// router's removal hook, never `onDisappear`. The session runs only while this screen is in
/// front, so it stops while the review is pushed over the camera.
struct CaptureScreen: View {
    let route: CaptureRoute
    let request: RouteRequest<StoredImage>?
    /// Previews: a given camera and permission instead of `CaptureCameraSource`'s.
    private let feedOverride: (any CaptureCameraFeed)?
    private let permissionOverride: CameraPermissionModel?

    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address
    @Environment(\.isScreenFocused) private var isScreenFocused
    @State private var parts: CaptureScreenParts?
    @State private var picking = false

    init(route: CaptureRoute, request: RouteRequest<StoredImage>?) {
        self.route = route
        self.request = request
        feedOverride = nil
        permissionOverride = nil
    }

    init(route: CaptureRoute, request: RouteRequest<StoredImage>?, feed: any CaptureCameraFeed, permission: CameraPermissionModel? = nil) {
        self.route = route
        self.request = request
        feedOverride = feed
        permissionOverride = permission
    }

    var body: some View {
        Group {
            if let parts {
                screen(parts)
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        // A container carries the screen's id; on the bare tree it would replace every control's.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen-capture")
        // Once, at the root: the library button and "Choose a photo instead" both open it, and
        // every presentation is answered (cancelled included), which unlocks the model's guard.
        .captureLibraryPicker(isPresented: $picking) { result in
            await parts?.model.finishLibraryPick(result)
        }
        .onAppear(perform: build)
    }

    @ViewBuilder
    private func screen(_ parts: CaptureScreenParts) -> some View {
        let model = parts.model
        Group {
            if model.permission.isGranted {
                CaptureCameraView(model: model, feed: parts.feed, runs: isScreenFocused) {
                    openLibrary(model)
                }
            } else {
                CameraPermissionView(
                    model: model.permission,
                    isPaired: app.household.session != nil,
                    onLibrary: { openLibrary(model) },
                    onManual: model.permissionOffersManual ? { model.continueManually() } : nil,
                    onCancel: { model.close() },
                    closeIdentifier: "capture-close",
                    isProcessing: model.processing
                )
            }
        }
        .inventoryQuery(parts.into)
        .onChange(of: parts.into.data, initial: true) { _, place in
            model.intoLoaded(place ?? nil)
        }
        // RN forced light status text over the camera (`<StatusBar style="light" />`): in light mode
        // the dark text vanished over the picture. Natively the status bar goes, as in the system
        // Camera, while the live camera is in front; the permission screen and the review pushed
        // over the camera keep it. (A `.preferredColorScheme(.dark)` here would also turn the
        // status text light, but setting it back to nil does not undo it, so the review stayed
        // dark; `.toolbarColorScheme` does nothing while the bar is hidden.)
        .statusBarHidden(model.permission.isGranted && isScreenFocused)
    }

    private func openLibrary(_ model: CaptureModel) {
        if model.beginLibraryPick() { picking = true }
    }

    /// Builds the model, the camera and the Into pill's read, once per screen.
    private func build() {
        guard parts == nil else { return }
        let router = app.router
        let navigator = address.map { CaptureNavigator(router: router, address: $0) }
        let results = router.results
        var deliver: (@MainActor @Sendable (StoredImage) -> Bool)?
        if let request {
            deliver = { photo in results.deliver(request, photo) }
        }
        let model = CaptureModel(
            route: route,
            deliverPhoto: deliver,
            permission: permissionOverride ?? CaptureCameraSource.makePermission(app: app),
            photos: app.imageStore,
            fastCapture: app.fastCapture,
            items: app.repositories.items,
            invalidator: app.database,
            toasts: app.toasts,
            haptics: app.platform.haptics,
            telemetry: app.telemetry,
            clock: app.clock,
            now: app.now,
            navigate: { navigator?.navigate($0) }
        )
        let feed = feedOverride ?? CaptureCameraSource.makeFeed()
        feed.reportEvents(to: model)

        let repositories = app.repositories
        let containerId = route.containerId
        let into = InventoryQuery<CaptureIntoPlace?>(key: "capture-into:\(containerId)", revision: app.database.revision) {
            try await CaptureIntoPlace.read(containerId: containerId, containers: repositories.containers, spaces: repositories.spaces)
        }
        if let address {
            // Dismissed, replaced or reset: a photo still being stored is no longer wanted.
            router.onRemoval(of: address) { model.disappeared() }
        }
        parts = CaptureScreenParts(model: model, feed: feed, into: into)
    }
}

/// What a capture screen builds once: the model, its camera and the Into pill's read.
@MainActor
final class CaptureScreenParts {
    let model: CaptureModel
    let feed: any CaptureCameraFeed
    let into: InventoryQuery<CaptureIntoPlace?>

    init(model: CaptureModel, feed: any CaptureCameraFeed, into: InventoryQuery<CaptureIntoPlace?>) {
        self.model = model
        self.feed = feed
        self.into = into
    }
}

/// The live camera and its chrome (05 §4.10): Close, the Into pill and Flash on top; the notices,
/// the status pill, the mode picker, the shutter row and the hint at the bottom.
struct CaptureCameraView: View {
    let model: CaptureModel
    let feed: any CaptureCameraFeed
    /// The screen is in front (the session stops under the review).
    let runs: Bool
    let onLibrary: () -> Void

    var body: some View {
        ScreenFrame(.camera) {
            ZStack {
                feed.preview(runs: runs, focus: model.focus)
                    .ignoresSafeArea()
                CaptureReticle()
                    .ignoresSafeArea()
                CaptureShutterFlash(trigger: model.shotSerial)
                VStack(spacing: 0) {
                    topRow
                        .layoutPriority(1)
                    notices
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    controls
                        .layoutPriority(1)
                }
                // RN's camera text (meta, caption, name) stops at 2×; past AX1 the notices and
                // the controls would not fit. Controls keep the large content viewer.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
        }
    }

    private var topRow: some View {
        HStack(alignment: .center, spacing: 8) {
            CameraGlassIconButton(systemImage: Glyph.close.systemName, label: L10n.Capture.close, identifier: "capture-close") {
                model.close()
            }
            Group {
                if model.showsIntoPill {
                    CaptureIntoPill(place: model.into, accessibilityLabel: model.intoAccessibilityLabel)
                }
            }
            .frame(maxWidth: .infinity)
            // The glyph shows the state the flash is in now, not the one a tap would choose.
            CameraGlassIconButton(
                systemImage: model.flashOn ? "bolt.fill" : Glyph.flashOff.systemName,
                label: model.flashLabel,
                isSelected: model.flashOn,
                identifier: "capture-flash"
            ) {
                model.toggleFlash()
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    /// The notices and the status pill, just over the controls. Where they do not fit between the
    /// top row and the controls (a 667 pt phone at the largest text sizes, with both notices up)
    /// they scroll, rather than squeezing the controls until Done loses its count and the hint
    /// its words.
    private var notices: some View {
        ViewThatFits(in: .vertical) {
            noticeStack
            ScrollView {
                noticeStack
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.bottom)
        }
        .padding(.top, 16)
    }

    private var noticeStack: some View {
        VStack(spacing: 16) {
            if let error = model.error {
                CameraPanel(
                    tone: .error,
                    message: error,
                    actions: model.offersTypeInstead
                        ? [CameraPanelAction(id: "capture-error-manual", label: L10n.Capture.manual, systemImage: Glyph.keyboard.systemName) {
                            model.continueManually()
                        }]
                        : [],
                    systemImage: Glyph.warning.systemName
                )
                .accessibilityIdentifier("capture-error")
            }
            if let dropped = model.droppedNotice {
                CameraPanel(tone: .error, message: dropped, systemImage: Glyph.warning.systemName)
                    .accessibilityIdentifier("capture-dropped")
            }
            if let status = model.fastStatus {
                CameraTitlePill(
                    text: status.text,
                    systemImage: status.settled ? Glyph.check.systemName : nil,
                    updatesFrequently: true,
                    identifier: "capture-status",
                    announces: true
                )
                .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    /// The mode picker, the shutter row and the hint, always at their full height.
    private var controls: some View {
        VStack(spacing: 16) {
            if model.showsModePicker {
                modePicker
                    .frame(maxWidth: 320)
                    // Room above the shutter row, so a thumb aiming for the shutter does not switch.
                    .padding(.bottom, 4)
            }
            shutterRow
            Text(model.hint)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .allowsHitTesting(false)
                .accessibilityIdentifier("capture-hint")
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var modePicker: some View {
        SegmentedChoice(
            options: [
                SegmentOption(value: CaptureMode.single, label: L10n.Capture.modeSingle, glyph: .camera, identifier: "capture-mode-single"),
                SegmentOption(value: CaptureMode.fast, label: L10n.Capture.modeFast, glyph: .layers, identifier: "capture-mode-fast"),
            ],
            selection: Binding(get: { model.mode }, set: { model.selectMode($0) }),
            accessibilityLabel: L10n.Capture.modeLabel,
            onCamera: true,
            // Also while a single photo is saved: its hand-over would carry off a fast set begun
            // meanwhile.
            isDisabled: !model.canChangeMode,
            accessibilityHint: model.modePickerHint
        )
        // The model plays `.choice` for a real change; the picker's own would play it twice.
        .environment(\.haptics) { _ in }
    }

    private var shutterRow: some View {
        HStack(spacing: 0) {
            leadingSlot
                .frame(maxWidth: .infinity, alignment: .leading)
            CaptureShutter(
                isBusy: !model.isFast && model.processing,
                isDimmed: model.isFast && model.shooting,
                isEnabled: model.isSessionRunning
            ) {
                let feed = feed
                let model = model
                Task {
                    await model.shutterPressed { try await feed.capturePhoto(flashOn: model.flashOn) }
                }
            }
            trailingSlot
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var leadingSlot: some View {
        if model.isFast {
            CaptureLastShotTile(photo: model.lastShot, serial: model.shotSerial, count: model.captured)
        } else {
            CameraGlassIconButton(systemImage: Glyph.gallery.systemName, label: L10n.Capture.library, identifier: "capture-library") {
                onLibrary()
            }
            .disabled(!model.isLibraryEnabled)
            .opacity(model.isLibraryEnabled ? 1 : 0.5)
        }
    }

    @ViewBuilder
    private var trailingSlot: some View {
        if model.isFast {
            CaptureDoneButton(count: model.captured, accessibilityLabel: model.doneAccessibilityLabel) {
                model.finishFast()
            }
        } else if model.isRequest {
            CaptureSideSpacer()
        } else {
            CameraGlassIconButton(systemImage: Glyph.keyboard.systemName, label: L10n.Capture.manual, identifier: "capture-manual") {
                model.continueManually()
            }
        }
    }
}

#if DEBUG
#Preview("Single") {
    ShellPreviewHost {
        NavigationStack {
            CaptureScreen(route: CaptureRoute(containerId: DropZone.containerId), request: nil, feed: CaptureStandInFeed())
        }
    }
}

#Preview("Quick Snap, shots landing") {
    ShellPreviewHost {
        NavigationStack {
            CaptureScreen(
                route: .quickSnap,
                request: nil,
                feed: CaptureStandInFeed(script: CaptureStandInFeed.Script(shots: [.photo, .photo, .unreadable]))
            )
        }
    }
}

#Preview("Camera did not start") {
    ShellPreviewHost {
        NavigationStack {
            CaptureScreen(route: .quickSnap, request: nil, feed: CaptureStandInFeed(script: CaptureStandInFeed.Script(failsToStart: true)))
        }
    }
}

#Preview("Permission gate") {
    ShellPreviewHost {
        NavigationStack {
            CaptureScreen(
                route: .quickSnap,
                request: nil,
                feed: CaptureStandInFeed(),
                permission: CaptureStandInPermission(.notDetermined).model(telemetry: .shared)
            )
        }
    }
}

#Preview("Permission blocked, request") {
    ShellPreviewHost {
        NavigationStack {
            CaptureScreen(
                route: CaptureRoute(containerId: DropZone.containerId),
                request: RouteRequest(id: "preview"),
                feed: CaptureStandInFeed(),
                permission: CaptureStandInPermission(.denied).model(telemetry: .shared)
            )
        }
    }
}
#endif
