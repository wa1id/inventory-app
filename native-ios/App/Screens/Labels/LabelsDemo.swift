#if DEBUG
import Foundation
import OSLog
import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStrings

/// DEBUG demo hooks for the labels area: the Scan tab, the label link, the QR label and linking a
/// sticker. Every state can be screenshotted without tapping:
/// `mac.sh run out.png -demo YES -demoArea labels -demoState <state> [-demoRoute <spec>]`.
///
/// The simulator has no camera, so every camera state runs on a stand-in feed with the camera
/// permission granted; a state that scans "reads" its code from that feed 1.5 s after the camera
/// starts, through the real scanner, guard and models. Household states join a household whose
/// fake server is offline, never answers, or answers only for the sticker's container
/// (`demo-chest`). The run hook selects the tab or opens the route the state is about, so
/// `-demoState` alone is enough unless the table says to add a route.
///
/// | State | Shows |
/// |---|---|
/// | `camera` | the Scan tab's camera with the hint and Type a code (stand-in feed) |
/// | `permission`, `blocked` | the Scan tab's permission screen: Allow camera (which grants), or Open Settings |
/// | `noCamera` | the Scan tab's "The camera did not start" panel (a capture session with no camera) |
/// | `scanNotOurs` | a scan of someone else's QR: "Not one of our labels" with Scan again |
/// | `scanOpening` | a scan whose household lookup never answers: "Opening that label…" |
/// | `scanFailed` | a scan whose household lookup fails: the offline words with Try again |
/// | `scanBound` | a scan of the Tool chest's label: the Tool chest opens |
/// | `scanUnknown` | a scan of a label of ours never linked: the label screen's bind picker |
/// | `codeList` | the typed-code list (Type a code instead) |
/// | `codeListFailed` | the typed-code list when the household's lists could not be read (Back to the camera stays) |
/// | `labelResolving`, `labelFailed` | the label screen while its household lookup hangs, or after it failed |
/// | `labelInvalid` | the label screen for a code that is not ours |
/// | `labelDeleted` | a label whose container was deleted: linked to nothing again, so the bind picker |
/// | `qrLoading`, `qrFailed`, `qrGone` | the QR label screen loading (household hangs), failed (offline), or for a deleted container |
/// | `sticker` | the sticker camera for the Tool chest, scanning |
/// | `stickerPermission` | the sticker camera's permission screen, with its close button |
/// | `stickerNotOurs` | the sticker camera after someone else's QR |
/// | `stickerReplace` | an unlinked sticker for the Tool chest, which has a label: "Replace the label on Tool chest?" |
/// | `stickerMove` | the Tool chest's sticker scanned for the Red bin: "Move this sticker to Red bin?" |
/// | `stickerLinked` | an unlinked sticker for the Red bin: linked, back on its QR label screen with the toast |
/// | `stickerAlready` | the Tool chest's own sticker: back on its QR screen with "This sticker already opens Tool chest." |
/// | `stickerChecking`, `stickerFailed` | a household sticker lookup that hangs ("Reading the sticker…"), or fails |
/// | `stickerContainerFailed`, `stickerGone`, `stickerLocked` | the container could not be read, is gone, or is the drop zone |
///
/// Seeded routes need no state: `-demoRoute label` (the bind picker), `label:c0ffee00c0ffee00c0ffee00c0ffee00`
/// (replaced by the Tool chest), `qrLabel:Tool_chest`, `qrLabel:Red_bin` (no label yet),
/// `qrLabel:Drop_zone` (locked).
enum LabelsDemo {
    /// The scanner feed the labels screens use instead of the back camera; nil outside a labels
    /// demo state that needs one.
    @MainActor static var scannerFeed: (@MainActor () -> any QrScannerFeed)?

    /// What the Scan tab does once it is first in front (the code list).
    @MainActor private static var onScanFocused: ((ScanModel) -> Void)?

    /// The codes the stand-in feed reads, one per camera start, in order.
    @MainActor fileprivate static var codes: [String] = []

    static let log = Logger(subsystem: "com.wystudio.inventory", category: "demo")

    /// The container for `state`, or nil for the default demo container (the seeded inventory in
    /// memory, or an empty one with `-demoSeed empty`). Called before anything shows.
    @MainActor
    static func container(state: String, platform: AppPlatform) -> AppContainer? {
        guard let demo = LabelsDemoState(rawValue: state) else {
            let states = LabelsDemoState.allCases.map(\.rawValue).joined(separator: ", ")
            log.error("-demoState \(state, privacy: .public) is not a labels state; use one of \(states, privacy: .public)")
            return nil
        }
        let camera = LabelsDemoCamera(demo.authorization)
        var platform = platform
        platform.cameraAuthorization = { camera.status }
        platform.requestCameraAccess = { await camera.grant() }

        switch demo.feed {
        case .standIn: scannerFeed = { LabelsDemoScannerFeed() }
        case .noCamera: scannerFeed = { CameraController(use: .qrCodes, discover: { nil }) }
        }
        codes = demo.codes
        if demo == .codeList || demo == .codeListFailed { startScanInCodeList() }

        let session = demo.household.map { _ in
            HouseholdSession(origin: "https://box.example", token: "demo-token", deviceId: "demo-device", deviceName: "iPhone", householdName: "Home")
        }
        return AppContainer.preview(
            platform: platform,
            seed: UserDefaults.standard.string(forKey: "demoSeed") != "empty",
            onboardingCompleted: true,
            householdSession: session,
            transport: demo.household.map { LabelsDemoTransport(mode: $0) } ?? ShellOfflineTransport()
        )
    }

    /// Runs once the main shell shows, after `-demoTab` and before `-demoRoute`: selects the tab
    /// or opens the route the state is about.
    @MainActor
    static func run(state: String, app: AppContainer) async {
        guard let demo = LabelsDemoState(rawValue: state) else { return }
        let router = app.router
        switch demo {
        case .camera, .permission, .blocked, .noCamera, .scanNotOurs, .scanOpening, .scanFailed, .scanBound, .scanUnknown, .codeList, .codeListFailed:
            router.selectTab(.scan)
        case .labelResolving, .labelFailed:
            router.push(.label(token: AppContainerPreviewData.unboundLabelToken))
        case .labelInvalid:
            router.push(.label(token: "not-one-of-ours"))
        case .labelDeleted:
            if let token = await deletedContainerLabel(app) { router.push(.label(token: token)) }
        case .qrLoading, .qrFailed:
            router.push(.qrLabel(containerId: LabelsDemoTransport.containerId))
        case .qrGone:
            router.push(.qrLabel(containerId: "gone-container"))
        case .sticker, .stickerPermission, .stickerNotOurs, .stickerReplace, .stickerAlready:
            await openSticker(named: "Tool chest", overQrLabel: demo == .stickerAlready, app: app)
        case .stickerMove:
            await openSticker(named: "Red bin", overQrLabel: false, app: app)
        case .stickerLinked:
            await openSticker(named: "Red bin", overQrLabel: true, app: app)
        case .stickerChecking, .stickerFailed, .stickerContainerFailed:
            router.present(.linkSticker(containerId: LabelsDemoTransport.containerId))
        case .stickerGone:
            router.present(.linkSticker(containerId: "gone-container"))
        case .stickerLocked:
            router.present(.linkSticker(containerId: DropZone.containerId))
        }
    }

    /// The Scan tab opens on its typed-code list once it is first in front (the `codeList` state
    /// and the screen's preview).
    @MainActor
    static func startScanInCodeList() {
        onScanFocused = { $0.typeCode() }
    }

    /// The Scan tab came to the front with its model (once per demo).
    @MainActor
    static func scanFocused(_ scan: ScanModel) {
        guard let action = onScanFocused else { return }
        onScanFocused = nil
        action(scan)
    }

    /// The next scripted code, if any.
    @MainActor
    fileprivate static func takeCode() -> String? {
        codes.isEmpty ? nil : codes.removeFirst()
    }

    /// Opens the sticker camera for the seeded container `name`, over its QR label screen when
    /// asked (so a link that closes the camera lands there).
    @MainActor
    private static func openSticker(named name: String, overQrLabel: Bool, app: AppContainer) async {
        let containers = (try? await app.repositories.containers.listAllWithSpace()) ?? []
        guard let id = containers.first(where: { $0.container.name == name })?.container.id else {
            log.error("labels demo: no container named \(name, privacy: .public)")
            return
        }
        if overQrLabel {
            app.router.push(.qrLabel(containerId: id))
            try? await Task.sleep(for: .milliseconds(700))
        }
        app.router.present(.linkSticker(containerId: id))
    }

    /// A label bound to a container that was then deleted (its binding went with it), so the
    /// label opens as one of ours that is linked to nothing.
    @MainActor
    private static func deletedContainerLabel(_ app: AppContainer) async -> String? {
        let repositories = app.repositories
        do {
            guard let garage = try await repositories.spaces.listWithCounts().first(where: { $0.name == "Garage" }) else { return nil }
            let crate = try await repositories.containers.create(CreateContainerInput(spaceId: garage.id, name: "Old crate", visualType: .crate))
            let token = "deadbeefdeadbeefdeadbeefdeadbeef"
            _ = try await repositories.qr.bind(token: token, containerId: crate.id)
            _ = try await repositories.containers.delete(crate.id)
            app.database.invalidate()
            return token
        } catch {
            log.error("labels demo: could not set up the deleted container's label")
            return nil
        }
    }
}

/// The labels area's demo states (see ``LabelsDemo``).
enum LabelsDemoState: String, CaseIterable {
    case camera, permission, blocked, noCamera, scanNotOurs, scanOpening, scanFailed, scanBound, scanUnknown, codeList, codeListFailed
    case labelResolving, labelFailed, labelInvalid, labelDeleted
    case qrLoading, qrFailed, qrGone
    case sticker, stickerPermission, stickerNotOurs, stickerReplace, stickerMove, stickerLinked, stickerAlready
    case stickerChecking, stickerFailed, stickerContainerFailed, stickerGone, stickerLocked

    enum Feed {
        /// The stand-in picture, reading ``LabelsDemoState/codes``.
        case standIn
        /// A real capture session that finds no camera.
        case noCamera
    }

    var authorization: CameraAuthorization {
        switch self {
        case .permission, .stickerPermission: .notDetermined
        case .blocked: .denied
        default: .authorized
        }
    }

    var feed: Feed { self == .noCamera ? .noCamera : .standIn }

    /// What the camera reads, one code per start.
    var codes: [String] {
        let notOurs = "https://example.com/not-one-of-ours"
        let toolChest = formatQrPayload(AppContainerPreviewData.toolChestLabelToken)
        let unbound = formatQrPayload(AppContainerPreviewData.unboundLabelToken)
        switch self {
        case .scanNotOurs, .stickerNotOurs: return [notOurs]
        case .scanOpening, .scanFailed, .scanBound, .stickerMove, .stickerAlready: return [toolChest]
        case .scanUnknown, .stickerReplace, .stickerLinked, .stickerChecking, .stickerFailed: return [unbound]
        default: return []
        }
    }

    /// The household this state joins, if any.
    var household: LabelsDemoTransport.Mode? {
        switch self {
        case .scanFailed, .codeListFailed, .labelFailed, .qrFailed, .stickerContainerFailed: .offline
        case .scanOpening, .labelResolving, .qrLoading: .hangs
        case .stickerChecking: .stickerContainer(scanHangs: true)
        case .stickerFailed: .stickerContainer(scanHangs: false)
        default: nil
        }
    }
}

/// The demo's camera permission: as the state says, and granted when Allow camera is pressed.
@MainActor
private final class LabelsDemoCamera {
    private(set) var status: CameraAuthorization

    init(_ status: CameraAuthorization) {
        self.status = status
    }

    nonisolated func grant() async -> Bool {
        await MainActor.run { self.status = .authorized }
        return true
    }
}

/// The stand-in camera picture, which reads the demo's next code 1.5 s after it starts running.
@MainActor
private final class LabelsDemoScannerFeed: QrScannerFeed {
    var onEvent: (@MainActor (CameraFeedEvent) -> Void)?
    var onCodes: (@MainActor ([String]) -> Void)?
    private let standIn = StandInQrScannerFeed()
    private var reading: Task<Void, Never>?

    init() {
        standIn.onEvent = { [weak self] event in self?.onEvent?(event) }
    }

    func setRunning(_ running: Bool) {
        standIn.setRunning(running)
        reading?.cancel()
        reading = nil
        guard running else { return }
        reading = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self, let code = LabelsDemo.takeCode() else { return }
            onCodes?([code])
        }
    }

    func setTorch(_ on: Bool) {
        standIn.setTorch(on)
    }

    func makePreview() -> AnyView {
        standIn.makePreview()
    }
}

/// A household server for the demo: offline, never answering, or answering only for the
/// sticker's container (`GET /v1/containers/demo-chest`, an unnamed-label Tool chest) while its
/// sticker lookups hang or fail.
struct LabelsDemoTransport: HTTPTransport {
    enum Mode: Sendable {
        case offline
        case hangs
        case stickerContainer(scanHangs: Bool)
    }

    static let containerId = "demo-chest"

    let mode: Mode

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        switch mode {
        case .offline:
            throw URLError(.notConnectedToInternet)
        case .hangs:
            try await Task.sleep(for: .seconds(3600))
            throw URLError(.timedOut)
        case .stickerContainer(let scanHangs):
            let path = request.url?.path() ?? ""
            if request.httpMethod == "GET", path == "/v1/containers/\(Self.containerId)" {
                return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: Data(Self.container.utf8))
            }
            if path == "/v1/qr/scan", scanHangs {
                try await Task.sleep(for: .seconds(3600))
            }
            throw URLError(.notConnectedToInternet)
        }
    }

    private static let container = #"{"id":"demo-chest","spaceId":"demo-garage","name":"Tool chest","visualType":"cabinet","shortCode":"CAB-J92R","createdAt":1700000000000,"updatedAt":1700000000000,"itemCount":2,"qrToken":null}"#
}
#endif
