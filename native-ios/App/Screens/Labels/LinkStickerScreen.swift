import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// Linking a sticker printed earlier to a container, full screen over its QR label screen (RN
/// `app/container/[id]/link.tsx`, 07 §3.10): point the camera at the sticker and it is linked,
/// with a question first only when an existing link would stop working, then the camera closes
/// with a toast.
///
/// `LinkStickerModel` owns the rules and its own `QrScannerModel`, which the scanner view runs
/// with its own focus handling (a cover in front is focused; the camera stops while a dialog or
/// another screen covers it). The changing title ("Scan the sticker for Tool chest") goes through
/// `QrScannerView(title:)`. The notice (busy or error, with one action) is drawn over the bottom
/// of whatever the scanner shows, the permission screen included, as RN overlaid it. The model's
/// `close()` runs when the cover goes away (`router.onRemoval`).
struct LinkStickerScreen: View {
    let containerId: String
    /// Where the camera's frames come from: nil for the back camera. Previews pass a stand-in
    /// (the simulator has no camera), and so does the DEBUG demo (`LabelsDemo`).
    private let makeFeed: (@MainActor () -> any QrScannerFeed)?

    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address
    @State private var model: LinkStickerModel?

    init(containerId: String, makeFeed: (@MainActor () -> any QrScannerFeed)? = nil) {
        self.containerId = containerId
        self.makeFeed = makeFeed
    }

    var body: some View {
        ScreenFrame(.camera) {
            if let model {
                LinkStickerContent(model: model, makeFeed: makeFeed ?? Self.defaultFeed, close: close)
                    .inventoryQuery(model)
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        // The cover is always dark over the camera, so its status bar is light (RN `StatusBar
        // style="light"`); a preferred scheme applies to the enclosing presentation only.
        .preferredColorScheme(.dark)
        // One container carries the screen's identifier; without it, the identifier would replace
        // the close button's and the torch's own (`link-close`, `scanner-torch`), as nothing here
        // scrolls to hold it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen-link-sticker")
        // VoiceOver's escape closes the cover, as its close button does.
        .accessibilityAction(.escape) { close() }
        .onAppear {
            guard model == nil else { return }
            let made = Self.makeModel(app: app, containerId: containerId, address: address)
            model = made
            if let address { app.router.onRemoval(of: address) { made.close() } }
        }
    }

    private func close() {
        if let address { app.router.close(address) }
    }

    /// The cover's model, wired to the app: the scan permission, the current repositories, the
    /// revision, the database as invalidator, toasts, the system confirmation, haptics,
    /// telemetry, the clock, and the router through ``navigate(_:router:address:)``.
    static func makeModel(app: AppContainer, containerId: String, address: ScreenAddress?) -> LinkStickerModel {
        let router = app.router
        return LinkStickerModel(
            containerId: containerId,
            permission: app.makeCameraPermission(purpose: .scan),
            repositories: app.repositories,
            revision: app.database.revision,
            invalidator: app.database,
            toasts: app.toasts,
            confirm: app.platform.confirm,
            haptics: app.platform.haptics,
            telemetry: app.telemetry,
            clock: app.clock,
            navigate: { navigate($0, router: router, address: address) }
        )
    }

    /// Where the sticker camera leads: closing itself (only itself: a late answer never closes the
    /// QR screen underneath, since a cover already gone has no position), or the drop zone's tab.
    static func navigate(_ destination: LinkStickerNavigation, router: Router, address: ScreenAddress?) {
        switch destination {
        case .close:
            if let address { router.close(address) }
        case .dropZoneTab:
            router.goToTab(.dropZone)
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

extension LinkStickerModel: ShellFocusDriven {}

/// The sticker camera once its model exists.
private struct LinkStickerContent: View {
    let model: LinkStickerModel
    let makeFeed: @MainActor () -> any QrScannerFeed
    let close: () -> Void

    var body: some View {
        QrScannerView(
            model: model.scanner,
            title: model.title,
            onClose: close,
            closeIdentifier: "link-close",
            makeFeed: makeFeed
        ) {
            // Over the picture, the scanner's own footer: under its title row whatever the title's
            // height (two lines at large sizes), scrolling when it is taller than the room left.
            if let panel = model.panel {
                LinkStickerNotice(panel: panel, placement: .footer) { model.perform($0) }
            }
        }
        .overlay(alignment: .bottom) {
            // The permission screen and a camera that failed draw no footer: over those, as RN
            // overlaid it.
            if let panel = model.panel, !model.scanner.permission.isGranted || !model.scanner.showsFooter {
                LinkStickerNotice(panel: panel, placement: .overlay) { model.perform($0) }
            }
        }
    }
}

/// The notice over the bottom of the sticker camera (RN `Panel`): it scrolls when large text
/// makes it taller than the room under the title, so its button stays reachable.
private struct LinkStickerNotice: View {
    enum Placement {
        /// In the scanner's footer, which places and scrolls it.
        case footer
        /// Over a screen with no footer (the permission screen), clear of its close button.
        case overlay
    }

    let panel: LinkStickerPanel
    let placement: Placement
    let perform: (LinkStickerPanel.Action) -> Void

    var body: some View {
        switch placement {
        case .footer:
            notice
        case .overlay:
            VStack(spacing: 0) {
                // Clear of the close button.
                Spacer(minLength: 72)
                ViewThatFits(in: .vertical) {
                    notice
                    ScrollView { notice }
                        .scrollBounceBehavior(.basedOnSize)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var notice: some View {
        CameraPanel(
            tone: panel.tone == .busy ? .busy : .error,
            title: panel.title,
            message: panel.message,
            actions: panel.action.map { action in
                [CameraPanelAction(id: action.identifier, label: action.label) { perform(action) }]
            } ?? []
        )
    }
}

#if DEBUG
#Preview("Scanning") {
    LinkStickerScreenPreview(name: "Tool chest")
}

#Preview("Drop zone") {
    ShellPreviewHost {
        NavigationStack { LinkStickerScreen(containerId: DropZone.containerId, makeFeed: { StandInQrScannerFeed() }) }
    }
}

#Preview("Gone") {
    ShellPreviewHost {
        NavigationStack { LinkStickerScreen(containerId: "gone", makeFeed: { StandInQrScannerFeed() }) }
    }
}

/// The sticker camera for a seeded container, found by name once the preview has booted.
private struct LinkStickerScreenPreview: View {
    let name: String

    var body: some View {
        ShellPreviewHost {
            LinkStickerScreenPreviewBody(name: name)
        }
    }
}

private struct LinkStickerScreenPreviewBody: View {
    let name: String
    @Environment(AppContainer.self) private var app
    @State private var containerId: String?

    var body: some View {
        NavigationStack {
            if let containerId {
                LinkStickerScreen(containerId: containerId, makeFeed: { StandInQrScannerFeed() })
            } else {
                Color.black
            }
        }
        .task {
            let containers = (try? await app.repositories.containers.listAllWithSpace()) ?? []
            containerId = containers.first { $0.container.name == name }?.container.id
        }
    }
}
#endif
