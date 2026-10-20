import InventoryAppModels
import InventoryStrings
import SwiftUI
import UIKit

/// The one camera-permission screen, for capturing and for scanning (RN `CameraPermission`,
/// 05 §16.1, 06 §8.5).
///
/// Before the system prompt it says what the camera is for (and, for photos, where they go);
/// after a "no" it points to Settings. A way on without the camera is always one tap away:
/// "Choose a photo instead" and "Type it instead" for capture, "Type a code instead" for the
/// scanner, offered when the host passes the callback. The content scrolls, so at the largest
/// text sizes nothing is pushed off screen. The status is read again whenever the app becomes
/// active, so a change made in Settings shows at once.
struct CameraPermissionView: View {
    let model: CameraPermissionModel
    /// A household session exists: the capture rationale says photos are shared with it.
    var isPaired = false
    /// Capture only: pick a library photo instead (`camera-library`).
    var onLibrary: (() -> Void)?
    /// Type the item (capture) or the label code (scan) instead (`camera-manual`).
    var onManual: (() -> Void)?
    /// Closes the camera screen (`strings.camera.close`); the Scan tab has nothing to close.
    var onCancel: (() -> Void)?
    /// The close button's identifier; each camera screen names its own (RN `closeTestID`).
    var closeIdentifier = "camera-close"
    /// Capture: a library photo picked from this screen is being stored. RN showed nothing here
    /// while a large photo took seconds to process; 05 §4.8 asks for progress, so the buttons
    /// pause and "Saving your photo…" shows under them (the close button stays).
    var isProcessing = false

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = CameraPermissionLayout(
            copy: model.copy(isPaired: isPaired, offersLibrary: onLibrary != nil, offersManual: onManual != nil),
            purpose: model.purpose
        )
        GeometryReader { proxy in
            ScrollView {
                content(layout)
                    .frame(maxWidth: 640)
                    .padding(.horizontal, 24)
                    .padding(.top, onCancel == nil ? 32 : 72)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .overlay(alignment: .topLeading) {
            if let onCancel {
                Button(action: onCancel) {
                    Label(L10n.Camera.close, systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityShowsLargeContentViewer {
                    Label(L10n.Camera.close, systemImage: "xmark")
                }
                .padding(.leading, 12)
                .padding(.top, 8)
                .accessibilityIdentifier(closeIdentifier)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refresh() }
        }
    }

    private func content(_ layout: CameraPermissionLayout) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "camera")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(layout.title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(layout.body)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                ForEach(layout.buttons) { button in
                    permissionButton(button)
                }
            }
            .disabled(isProcessing)
            .padding(.top, 8)

            if isProcessing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(L10n.Capture.saving)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("camera-processing")
                .onAppear {
                    ComponentAnnouncer.announce(L10n.Capture.saving)
                }
            }
        }
    }

    @ViewBuilder
    private func permissionButton(_ button: CameraPermissionLayout.Entry) -> some View {
        let action = { perform(button.action) }
        let label = Group {
            if let systemImage = button.systemImage {
                Label(button.label, systemImage: systemImage)
            } else {
                Text(button.label)
            }
        }
        switch button.style {
        case .primary:
            // The accent is ink, light in dark mode: the label takes the background colour so it
            // stays readable on it in both schemes (RN `onInk`).
            Button(action: action) {
                label
                    .foregroundStyle(Color(.systemBackground))
                    .frame(maxWidth: 320)
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .buttonBorderShape(borderShape)
                .accessibilityIdentifier(button.id)
        case .secondary:
            Button(action: action) { label.frame(maxWidth: 320) }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .buttonBorderShape(borderShape)
                .accessibilityIdentifier(button.id)
        case .quiet:
            Button(action: action) { label }
                .buttonStyle(.borderless)
                .accessibilityIdentifier(button.id)
        }
    }

    /// A capsule around a label that wraps to three lines at the largest sizes is an oval.
    private var borderShape: ButtonBorderShape {
        dynamicTypeSize.isAccessibilitySize ? .roundedRectangle : .automatic
    }

    private func perform(_ action: CameraPermissionLayout.Action) {
        switch action {
        case .allow:
            Task { await model.allow() }
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        case .choosePhoto:
            onLibrary?()
        case .manual:
            onManual?()
        }
    }
}

/// What the permission screen shows, decided from `CameraPermissionCopy` (RN
/// `CameraPermission.tsx:83-170`): the words, then the buttons in RN's order with their styles and
/// identifiers.
struct CameraPermissionLayout {
    enum Style: Hashable {
        /// Allow camera / Open Settings.
        case primary
        /// Choose a photo instead, Type a code instead.
        case secondary
        /// Capture's Type it instead, under the others.
        case quiet
    }

    enum Action: Hashable {
        case allow
        case openSettings
        case choosePhoto
        case manual
    }

    struct Entry: Identifiable, Hashable {
        /// Also the accessibility identifier (RN testID).
        let id: String
        let label: String
        let systemImage: String?
        let style: Style
        let action: Action
    }

    let title: String
    let body: String
    let buttons: [Entry]

    init(copy: CameraPermissionCopy, purpose: CameraPermissionPurpose) {
        title = copy.title
        body = copy.body
        var buttons: [Entry] = []
        switch copy.primaryAction {
        case .allow:
            buttons.append(Entry(id: "camera-allow", label: copy.primaryLabel, systemImage: nil, style: .primary, action: .allow))
        case .openSettings:
            buttons.append(Entry(id: "camera-open-settings", label: copy.primaryLabel, systemImage: nil, style: .primary, action: .openSettings))
        }
        for alternative in copy.alternatives {
            switch alternative {
            case .choosePhoto:
                buttons.append(Entry(id: "camera-library", label: alternative.label, systemImage: "photo.on.rectangle", style: .secondary, action: .choosePhoto))
            case .typeItem:
                buttons.append(Entry(id: "camera-manual", label: alternative.label, systemImage: "keyboard", style: .quiet, action: .manual))
            case .typeCode:
                buttons.append(Entry(id: "camera-manual", label: alternative.label, systemImage: "keyboard", style: .secondary, action: .manual))
            }
        }
        self.buttons = buttons
    }
}

#Preview("Capture, can ask") {
    CameraPermissionView(
        model: CameraPermissionModel(purpose: .capture, readAuthorization: { .notDetermined }, requestAccess: { false }),
        onLibrary: {},
        onManual: {},
        onCancel: {}
    )
}

#Preview("Capture, storing a library photo") {
    CameraPermissionView(
        model: CameraPermissionModel(purpose: .capture, readAuthorization: { .notDetermined }, requestAccess: { false }),
        onLibrary: {},
        onManual: {},
        onCancel: {},
        isProcessing: true
    )
}

#Preview("Capture, blocked") {
    CameraPermissionView(
        model: CameraPermissionModel(purpose: .capture, readAuthorization: { .denied }, requestAccess: { false }),
        isPaired: true,
        onLibrary: {},
        onCancel: {}
    )
}

#Preview("Scan, can ask") {
    CameraPermissionView(
        model: CameraPermissionModel(purpose: .scan, readAuthorization: { .notDetermined }, requestAccess: { false }),
        onManual: {}
    )
}

#Preview("Scan, blocked") {
    CameraPermissionView(
        model: CameraPermissionModel(purpose: .scan, readAuthorization: { .restricted }, requestAccess: { false }),
        onManual: {},
        onCancel: {}
    )
}
