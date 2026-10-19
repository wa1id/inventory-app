import InventoryAppModels
import InventoryStrings
import SwiftUI

/// Where the scanner's frames come from: the camera (``CameraController`` with
/// ``CameraUse/qrCodes``) or a stand-in for previews and tests.
@MainActor
protocol QrScannerFeed: AnyObject {
    var onEvent: (@MainActor (CameraFeedEvent) -> Void)? { get set }
    var onCodes: (@MainActor ([String]) -> Void)? { get set }
    func setRunning(_ running: Bool)
    func setTorch(_ on: Bool)
    /// The picture behind the scanner chrome.
    func makePreview() -> AnyView
}

extension CameraController: QrScannerFeed {
    func makePreview() -> AnyView {
        AnyView(CameraPreviewLayerView(camera: self))
    }
}

/// Connects a `QrScannerModel` to its feed (06 §8.4): the camera runs only while the model says
/// so (focused, active, permitted) and the app is not in the background; the torch follows the
/// model; a camera that does not start shows the failure panel; and every payload goes to
/// `QrScannerModel.codeDetected(_:)` on the main actor, where the scan guard lets one through per
/// arming.
@MainActor
final class QrScannerBridge {
    let model: QrScannerModel
    let feed: any QrScannerFeed

    init(model: QrScannerModel, feed: any QrScannerFeed) {
        self.model = model
        self.feed = feed
        feed.onEvent = { [weak model] event in
            if event == .failedToStart { model?.cameraFailedToStart() }
        }
        feed.onCodes = { [weak model] codes in
            guard let model else { return }
            for code in codes {
                Task { await model.codeDetected(code) }
            }
        }
    }

    /// Runs the camera when the model wants it, the scanner is on screen and the scene is not in
    /// the background (RN mounted the camera only while focused and active; 05 §8.3).
    func update(isShown: Bool, sceneIsBackground: Bool) {
        feed.setRunning(model.cameraRuns && isShown && !sceneIsBackground)
    }

    /// The torch button changed.
    func syncTorch() {
        feed.setTorch(model.torchOn)
    }
}

/// The QR scanner shared by the Scan tab and the sticker-link cover (RN `QrScanner`, 06 §8.4).
///
/// Full prop surface of RN's component: the model carries `active`, the title, `onScan` and the
/// torch label overrides; the view takes `title` (when it changes after the model was made),
/// `onManual` (permission screen and failure panel), `onClose` (a close button, absent on the Scan
/// tab), `closeIdentifier` (`scanner-close` here, `camera-close` on the permission screen unless
/// set), `torchIdentifier` (default `scanner-torch`) and a `footer` drawn over the bottom of the
/// picture only while the camera is up and has not failed.
///
/// The view reports focus to the model itself (on screen and `isScreenFocused`), unless
/// `managesFocus` is false because the host's model does it (the Scan tab's `ScanModel`).
struct QrScannerView<Footer: View>: View {
    let model: QrScannerModel
    var title: String?
    var onManual: (() -> Void)?
    var onClose: (() -> Void)?
    var closeIdentifier: String?
    var torchIdentifier = "scanner-torch"
    var managesFocus = true
    var makeFeed: @MainActor () -> any QrScannerFeed = { CameraController(use: .qrCodes) }
    @ViewBuilder var footer: () -> Footer

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isScreenFocused) private var isScreenFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bridge: QrScannerBridge?
    @State private var isShown = false

    var body: some View {
        Group {
            if model.permission.isGranted {
                camera
            } else {
                CameraPermissionView(
                    model: model.permission,
                    onManual: onManual,
                    onCancel: onClose,
                    closeIdentifier: closeIdentifier ?? "camera-close"
                )
            }
        }
        .onAppear {
            isShown = true
            if bridge?.model !== model {
                bridge = QrScannerBridge(model: model, feed: makeFeed())
            }
            update()
        }
        .onDisappear {
            isShown = false
            update()
        }
        .onChange(of: model.cameraRuns) { update() }
        .onChange(of: scenePhase) { update() }
        .onChange(of: model.torchOn) { bridge?.syncTorch() }
        .onChange(of: reduceMotion, initial: true) { _, reduced in
            model.reduceMotion = reduced
        }
        .onChange(of: isShown && isScreenFocused, initial: true) { _, focused in
            guard managesFocus else { return }
            if focused {
                model.focusGained()
            } else {
                model.focusLost()
            }
        }
    }

    private func update() {
        bridge?.update(isShown: isShown, sceneIsBackground: scenePhase == .background)
    }

    private var camera: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            if let bridge {
                bridge.feed.makePreview()
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
            ScannerReticle(isLocked: model.isLocked)
            VStack(spacing: 0) {
                topRow
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                Spacer(minLength: 16)
                bottom
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private var topRow: some View {
        HStack(spacing: 8) {
            ZStack {
                if let onClose {
                    CameraGlassIconButton(
                        systemImage: "xmark",
                        label: L10n.Camera.close,
                        identifier: closeIdentifier ?? "scanner-close",
                        action: onClose
                    )
                }
            }
            .frame(width: 48, height: 48)

            CameraTitlePill(text: title ?? model.title)
                .frame(maxWidth: .infinity)

            ZStack {
                // Hidden once the camera failed to start (RN: the torch is the first suspect).
                if model.showsTorch {
                    CameraGlassIconButton(
                        systemImage: model.torchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                        label: model.torchLabel,
                        isSelected: model.torchOn,
                        identifier: torchIdentifier
                    ) {
                        model.toggleTorch()
                    }
                }
            }
            .frame(width: 48, height: 48)
        }
    }

    /// The footer, or the failure panel in its place; it scrolls when large text makes it taller
    /// than the room left under the title, so its buttons stay reachable.
    private var bottom: some View {
        ViewThatFits(in: .vertical) {
            bottomContent
            ScrollView { bottomContent }
                .scrollBounceBehavior(.basedOnSize)
        }
    }

    @ViewBuilder private var bottomContent: some View {
        if model.showsFooter {
            footer()
        } else {
            CameraPanel(
                tone: .error,
                message: L10n.Camera.didNotStartScan,
                actions: onManual.map { manual in
                    [CameraPanelAction(id: "scanner-manual", label: L10n.Permissions.typeCodeInstead, systemImage: "keyboard", perform: manual)]
                } ?? []
            )
        }
    }
}

extension QrScannerView where Footer == EmptyView {
    init(
        model: QrScannerModel,
        title: String? = nil,
        onManual: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        closeIdentifier: String? = nil,
        torchIdentifier: String = "scanner-torch",
        managesFocus: Bool = true,
        makeFeed: @escaping @MainActor () -> any QrScannerFeed = { CameraController(use: .qrCodes) }
    ) {
        self.init(
            model: model,
            title: title,
            onManual: onManual,
            onClose: onClose,
            closeIdentifier: closeIdentifier,
            torchIdentifier: torchIdentifier,
            managesFocus: managesFocus,
            makeFeed: makeFeed,
            footer: { EmptyView() }
        )
    }
}

/// A feed with no camera behind it, for previews, the debug gallery and tests: it reports running
/// as soon as it is asked to and draws a stand-in scene, so the chrome over the camera can be
/// looked at on the simulator.
@MainActor
final class StandInQrScannerFeed: QrScannerFeed {
    var onEvent: (@MainActor (CameraFeedEvent) -> Void)?
    var onCodes: (@MainActor ([String]) -> Void)?
    private(set) var runningRequests: [Bool] = []
    private(set) var torchRequests: [Bool] = []
    /// Fails to start instead of running (the failure panel).
    var failsToStart = false

    var isRunning: Bool { runningRequests.last == true && !failsToStart }

    func setRunning(_ running: Bool) {
        guard runningRequests.last != running else { return }
        runningRequests.append(running)
        onEvent?(running ? (failsToStart ? .failedToStart : .running) : .stopped)
    }

    func setTorch(_ on: Bool) {
        torchRequests.append(on)
    }

    /// A frame with these payloads.
    func deliver(_ codes: [String]) {
        onCodes?(codes)
    }

    func makePreview() -> AnyView {
        AnyView(
            LinearGradient(
                colors: [Color(white: 0.92), Color(white: 0.55), Color(white: 0.18)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

#Preview("Scanner, hint footer") {
    QrScannerView(
        model: QrScannerModel(
            title: L10n.Scan.title,
            permission: CameraPermissionModel(purpose: .scan, readAuthorization: { .authorized }, requestAccess: { true })
        ),
        onManual: {},
        makeFeed: { StandInQrScannerFeed() }
    ) {
        CameraPanel(tone: .hint, message: L10n.Scan.hint, actions: [
            CameraPanelAction(id: "scan-type-code", label: L10n.Scan.typeCode, systemImage: "keyboard") {},
        ])
    }
}

#Preview("Scanner, permission") {
    QrScannerView(
        model: QrScannerModel(
            title: L10n.Scan.title,
            permission: CameraPermissionModel(purpose: .scan, readAuthorization: { .notDetermined }, requestAccess: { false })
        ),
        onManual: {}
    )
}

#Preview("Scanner, camera did not start") {
    let feed = StandInQrScannerFeed()
    feed.failsToStart = true
    return QrScannerView(
        model: QrScannerModel(
            title: L10n.Link.titlePlain,
            permission: CameraPermissionModel(purpose: .scan, readAuthorization: { .authorized }, requestAccess: { true })
        ),
        onManual: {},
        onClose: {},
        makeFeed: { feed }
    )
}
