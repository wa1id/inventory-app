#if DEBUG
import InventoryAppModels
import InventoryStrings
import SwiftUI

/// Debug-only gallery of the camera, scanner and QR views (see DebugGallery). One state per page,
/// so each can be screenshotted on the simulator: `-gallery media -galleryPage <n>`.
struct MediaGallery: View {
    let page: Int

    static let pages: [(title: String, view: @MainActor () -> AnyView)] = [
        ("Permission: capture, can ask", { AnyView(MediaGalleryPermission(purpose: .capture, authorization: .notDetermined)) }),
        ("Permission: capture, blocked", { AnyView(MediaGalleryPermission(purpose: .capture, authorization: .denied)) }),
        ("Scanner: permission, Scan tab", { AnyView(MediaGalleryScanner(state: .permission(.notDetermined), closes: false)) }),
        ("Scanner: blocked, sticker cover", { AnyView(MediaGalleryScanner(state: .permission(.denied), closes: true)) }),
        ("Scanner: no camera (simulator)", { AnyView(MediaGalleryScanner(state: .realCamera, closes: true)) }),
        ("Scanner: hint footer", { AnyView(MediaGalleryScanner(state: .hint, closes: false)) }),
        ("Scanner: torch on, locked, opening", { AnyView(MediaGalleryScanner(state: .lockedTorch, closes: false)) }),
        ("Scanner: not ours, cover title", { AnyView(MediaGalleryScanner(state: .notOurs, closes: true)) }),
        ("QR label card and share", { AnyView(MediaGalleryQrCard()) }),
        ("Label share picture", { AnyView(MediaGallerySharePicture()) }),
        ("Camera preview and focus", { AnyView(MediaGalleryCameraPreview()) }),
        ("Permission: capture, storing a library photo", { AnyView(MediaGalleryPermission(purpose: .capture, authorization: .notDetermined, isProcessing: true)) }),
    ]

    var body: some View {
        Group {
            if Self.pages.indices.contains(page) {
                Self.pages[page].view()
            } else {
                List(Self.pages.indices, id: \.self) { index in
                    Text(verbatim: "\(index). \(Self.pages[index].title)")
                }
            }
        }
        .measuresComponentWindow()
    }
}

private struct MediaGalleryPermission: View {
    let purpose: CameraPermissionPurpose
    let authorization: CameraAuthorization
    var isProcessing = false

    var body: some View {
        CameraPermissionView(
            model: CameraPermissionModel(purpose: purpose, readAuthorization: { authorization }, requestAccess: { false }),
            onLibrary: purpose == .capture ? {} : nil,
            onManual: {},
            onCancel: {},
            closeIdentifier: "capture-close",
            isProcessing: isProcessing
        )
    }
}

private struct MediaGalleryScanner: View {
    enum State {
        case permission(CameraAuthorization)
        case realCamera
        case hint
        case lockedTorch
        case notOurs
    }

    let state: State
    let closes: Bool

    @SwiftUI.State private var model: QrScannerModel

    init(state: State, closes: Bool) {
        self.state = state
        self.closes = closes
        let authorization: CameraAuthorization = if case .permission(let value) = state { value } else { .authorized }
        _model = SwiftUI.State(initialValue: QrScannerModel(
            title: closes ? L10n.Link.title(label: "Tool chest") : L10n.Scan.title,
            permission: CameraPermissionModel(purpose: .scan, readAuthorization: { authorization }, requestAccess: { false })
        ))
    }

    var body: some View {
        scanner
            .task {
                guard case .lockedTorch = state else { return }
                // Lock the reticle and keep it locked: the hand-over never finishes here.
                model.onScan = { _ in try? await Task.sleep(for: .seconds(3600)) }
                try? await Task.sleep(for: .milliseconds(300))
                model.toggleTorch()
                await model.codeDetected("inventory://c/0123456789abcdef0123456789abcdef")
            }
    }

    @ViewBuilder private var scanner: some View {
        switch state {
        case .permission:
            QrScannerView(model: model, onManual: {}, onClose: closes ? {} : nil)
        case .realCamera:
            // A camera session with no camera found: the real failure path, without the system
            // prompt a simulator camera would raise.
            QrScannerView(model: model, onManual: {}, onClose: closes ? {} : nil, makeFeed: {
                CameraController(use: .qrCodes, discover: { nil })
            })
        case .hint:
            QrScannerView(model: model, onManual: {}, makeFeed: { StandInQrScannerFeed() }) {
                CameraPanel(ScanPanel(tone: .hint, title: nil, message: L10n.Scan.hint, actions: [.typeCode])) { _ in }
            }
        case .lockedTorch:
            QrScannerView(model: model, onManual: {}, makeFeed: { StandInQrScannerFeed() }) {
                CameraPanel(ScanPanel(tone: .busy, title: nil, message: L10n.Scan.opening, actions: [])) { _ in }
            }
        case .notOurs:
            QrScannerView(model: model, onManual: {}, onClose: {}, closeIdentifier: "link-close", makeFeed: { StandInQrScannerFeed() }) {
                CameraPanel(ScanPanel(
                    tone: .error,
                    title: L10n.Scan.invalidTitle,
                    message: L10n.Scan.invalidBody,
                    actions: [.scanAgain, .typeCode]
                )) { _ in }
            }
        }
    }
}

private struct MediaGalleryQrCard: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    QrLabelCard(token: "0123456789abcdef0123456789abcdef", name: "Tool chest", shortCode: "CAB-J92R")
                    Text(L10n.Qr.hint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    QrLabelShareLink(token: "0123456789abcdef0123456789abcdef", name: "Tool chest", shortCode: "CAB-J92R")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(L10n.Qr.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct MediaGallerySharePicture: View {
    @State private var url: URL?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 12) {
            if let url, let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .border(Color.red, width: 1)
                    // Gallery only: the picture the share sheet would get.
                    .accessibilityLabel(Text(verbatim: "Share picture of the label CAB-J92R"))
                Text(verbatim: "\(url.lastPathComponent) · \(Int(image.size.width * image.scale))×\(Int(image.size.height * image.scale)) px")
                    .font(.footnote.monospaced())
            } else if failed {
                Text(verbatim: "render failed")
            }
        }
        .padding()
        .task {
            do {
                url = try QrLabelPicture.write(
                    payload: "inventory://c/0123456789abcdef0123456789abcdef",
                    shortCode: "CAB-J92R",
                    cardSize: QrLabelGeometry.card(windowWidth: 393).size
                )
            } catch {
                failed = true
            }
        }
    }
}

private struct MediaGalleryCameraPreview: View {
    @State private var camera = CameraController(use: .photo, discover: { nil })
    @State private var focus = TapToFocusModel()
    @State private var flashOn = false
    @State private var event: CameraFeedEvent?

    var body: some View {
        ZStack {
            CameraPreview(camera: camera, focus: focus)
                .ignoresSafeArea()
            VStack {
                HStack(spacing: 8) {
                    CameraGlassIconButton(systemImage: "xmark", label: L10n.Capture.close, identifier: "capture-close") {}
                    CameraTitlePill(text: L10n.Capture.into, systemImage: "tray")
                        .frame(maxWidth: .infinity)
                    CameraGlassIconButton(
                        systemImage: flashOn ? "bolt.fill" : "bolt.slash",
                        label: L10n.Capture.flash(on: flashOn),
                        isSelected: flashOn,
                        identifier: "capture-flash"
                    ) { flashOn.toggle() }
                }
                .padding(.horizontal, 8)
                Spacer()
                CameraTitlePill(text: event.map { "\($0)" } ?? "…", systemImage: "camera")
                    .padding(.bottom, 24)
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            camera.deliverEvents { event = $0 }
        }
        .task {
            // Keep the 700 ms focus square up for the screenshot.
            while !Task.isCancelled {
                focus.tap(at: CGPoint(x: 200, y: 420))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}

#Preview("Gallery index") {
    MediaGallery(page: -1)
}
#endif
