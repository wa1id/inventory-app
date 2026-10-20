import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// The Scan tab, "What's in this box?" (RN `app/(tabs)/scan.tsx`, 06 §8).
///
/// Point the camera at a label and its container opens; a label of ours that is not linked yet
/// goes to the label screen (`.label(token:)`), the one place labels are linked; anything else says
/// plainly it is not ours, and a failed lookup says what went wrong. When a label cannot be read,
/// "Type a code instead" swaps the camera for the place picker (mode `open`) to find the box by
/// the code written on it.
///
/// `ScanModel` owns the rules. This view reports the tab's focus (`\.isScreenFocused`; a screen
/// under a sheet is unfocused, so the camera stops there), a re-tap of Scan
/// (`router.reselections[.scan]`) and the removed-phone layer, and draws the camera phase full
/// bleed (no navigation bar, no connection banner) or the code phase as a tab root with a large
/// title. One camera feed serves the screen's life, so going to the code list and back does not
/// start a second capture session.
struct ScanScreen: View {
    /// Where the camera's frames come from: nil for the back camera. Previews pass a stand-in
    /// (the simulator has no camera), and so does the DEBUG demo (`LabelsDemo`).
    private let makeFeed: (@MainActor () -> any QrScannerFeed)?

    @Environment(AppContainer.self) private var app
    @State private var scan: ScanModel?
    @State private var feed: (any QrScannerFeed)?

    init(makeFeed: (@MainActor () -> any QrScannerFeed)? = nil) {
        self.makeFeed = makeFeed
    }

    var body: some View {
        Group {
            if let scan, let feed {
                ScanScreenContent(scan: scan, feed: feed)
            } else {
                // One frame, until `onAppear` has made the model.
                Color.black
                    .ignoresSafeArea()
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
        .accessibilityIdentifier("screen-scan")
        .onAppear {
            guard scan == nil else { return }
            scan = Self.makeModel(app: app)
            feed = (makeFeed ?? Self.defaultFeed)()
        }
    }

    /// The tab's model, wired to the app: the scan permission, the QR repository in use at each
    /// lookup, the platform's haptics, telemetry and clock, and the router.
    static func makeModel(app: AppContainer) -> ScanModel {
        let repositories = app.repositories
        let router = app.router
        return ScanModel(
            permission: app.makeCameraPermission(purpose: .scan),
            qr: { repositories.qr },
            haptics: app.platform.haptics,
            telemetry: app.telemetry,
            clock: app.clock,
            navigate: { navigate($0, router: router) }
        )
    }

    /// Where a scan or a typed code leads (RN `openContainer`, `router.push('/c/<token>')`): the
    /// drop zone's tab or the container pushed on this tab, or the label screen.
    static func navigate(_ destination: ScanNavigation, router: Router) {
        switch destination {
        case .openContainer(let id): router.openContainer(id)
        case .openLabel(let token): router.push(.label(token: token))
        }
    }

    /// The back camera, or the DEBUG demo's stand-in when `-demoArea labels` asks for one.
    private static var defaultFeed: @MainActor () -> any QrScannerFeed {
        #if DEBUG
        if let demo = LabelsDemo.scannerFeed { return demo }
        #endif
        return { CameraController(use: .qrCodes) }
    }
}

/// The Scan tab once its model exists.
private struct ScanScreenContent: View {
    let scan: ScanModel
    let feed: any QrScannerFeed

    @Environment(AppContainer.self) private var app
    @Environment(\.isScreenFocused) private var isScreenFocused

    var body: some View {
        Group {
            switch scan.phase {
            case .camera: camera
            case .code: codeList
            }
        }
        .navigationTitle(scan.phase == .code ? L10n.Scan.codeTitle : L10n.Scan.title)
        .toolbar(scan.phase == .camera ? .hidden : .automatic, for: .navigationBar)
        // RN turned the status bar light over the camera while the tab was in front; a tab root
        // cannot set its own status bar style (it follows the window's scheme), so it steps
        // aside instead, as over the system camera, rather than draw dark text on the picture.
        .statusBarHidden(isScreenFocused && scan.phase == .camera)
        .onChange(of: isScreenFocused, initial: true) { _, focused in
            if focused {
                scan.focusGained()
                #if DEBUG
                LabelsDemo.scanFocused(scan)
                #endif
            } else {
                scan.focusLost()
            }
        }
        .onChange(of: app.router.reselections[.scan]) { scan.tabReselected() }
        .onChange(of: app.connection.state == .revoked, initial: true) { _, revoked in
            scan.setRevoked(revoked)
        }
    }

    /// The camera, full bleed, with the hint, busy or error panel over the bottom of the picture
    /// (06 §8.2). No close button: the Scan tab has nothing to close.
    private var camera: some View {
        VStack(spacing: 0) {
            ScreenFrame(.camera) {
                QrScannerView(
                    model: scan.scanner,
                    onManual: { scan.typeCode() },
                    torchIdentifier: "scan-torch",
                    managesFocus: false,
                    makeFeed: { [feed] in feed }
                ) {
                    CameraPanel(scan.panel) { action in
                        switch action {
                        case .scanAgain, .tryAgain: scan.scanAgain()
                        case .typeCode: scan.typeCode()
                        }
                    }
                }
            }
            // The scene ends at the tab bar, as in RN: behind the bar is the page, not the
            // picture, so its glass and the ink of the selected tab read as on every other tab
            // (over a dark picture the glass turns dark and the ink would vanish). The page is a
            // one-point strip under the scene that reaches down behind the bar. Being a sibling
            // rather than an overlay, it also keeps the permission screen's scroll view off the
            // bottom edge: a scroll view there becomes the tab bar's content, and the bar took its
            // dark scheme (the selected Scan tab drew grey on grey).
            Color(.systemBackground)
                .frame(height: 1)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        // One container takes the screen's identifier (`screen-scan`); without it, nothing here
        // scrolls to hold it and it would replace the torch's own (`scan-torch`).
        .accessibilityElement(children: .contain)
    }

    /// The typed-code list (06 §8.3): every container by name or by the code on its label, in
    /// the place picker's `open` mode (filter focused, capitals, no "New container in …"). Only a
    /// container pick does anything. "Back to the camera" is pinned above the picker, as RN pinned
    /// it beside the heading, rather than in the navigation bar, which the focused search field
    /// takes over: so it is there while the lists load, when they failed, and however far the list
    /// has scrolled.
    private var codeList: some View {
        ScreenFrame(.tabRoot) {
            PlacePickerHost(mode: .open, placeholder: L10n.Scan.codePlaceholder) { place in
                guard case .container(let option) = place else { return }
                scan.openTyped(containerId: option.id)
            }
            .safeAreaBar(edge: .top, spacing: 0) {
                ScanBackToCamera { scan.backToCamera() }
            }
        }
        .navigationBarTitleDisplayMode(.large)
        // As over the camera: the pinned button sits outside the list's scroll view, so without
        // one container to take the screen's identifier (`screen-scan`) it would replace the
        // button's own (`scan-back-to-camera`).
        .accessibilityElement(children: .contain)
    }
}

/// "Back to the camera" (RN's quiet button beside the code list's heading).
private struct ScanBackToCamera: View {
    let action: () -> Void

    var body: some View {
        LoadingButton(
            label: L10n.Scan.backToCamera,
            glyph: .camera,
            variant: .quiet,
            size: .small,
            identifier: "scan-back-to-camera",
            action: action
        )
        // Pinned above the list, outside its scroll view: past AX1 it would take a quarter of the
        // screen at the largest sizes, as the connection banner would (08 §6).
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

#if DEBUG
#Preview("Camera") {
    ShellPreviewHost {
        NavigationStack { ScanScreen(makeFeed: { StandInQrScannerFeed() }) }
    }
}

#Preview("Typed code") {
    let _ = LabelsDemo.startScanInCodeList()
    ShellPreviewHost {
        NavigationStack { ScanScreen(makeFeed: { StandInQrScannerFeed() }) }
    }
}

#Preview("Camera that did not start") {
    ShellPreviewHost {
        NavigationStack { ScanScreen(makeFeed: { CameraController(use: .qrCodes, discover: { nil }) }) }
    }
}
#endif
