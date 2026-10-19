import InventoryCore
import InventoryStrings
import Observation

/// The Scan tab's two phases (RN `Phase`): the camera, or the typed-code list that stands in for it.
public enum ScanPhase: String, Sendable, Hashable {
    case camera
    case code
}

/// What happened to the last label the camera read (RN `Result`).
public enum ScanResult: Sendable {
    case idle
    /// Being looked up (over the network when paired); the camera stays on.
    case opening
    /// Not one of our labels.
    case notOurs
    /// The lookup failed; ``describeError(_:context:subject:)`` says what to show.
    case failed(any Error)

    /// The camera takes codes in this state (idle or opening).
    var keepsScanning: Bool {
        switch self {
        case .idle, .opening: true
        case .notOurs, .failed: false
        }
    }

    var isOpening: Bool {
        if case .opening = self { return true }
        return false
    }
}

/// Where the Scan tab sends the person.
public enum ScanNavigation: Sendable, Hashable {
    /// A linked label, or a container picked from the code list (RN `openContainer`: the drop zone
    /// is its tab, anything else is pushed).
    case openContainer(id: String)
    /// A label of ours that is not linked yet: push `/c/<token>` (lowercased token).
    case openLabel(token: String)
}

/// A button on the Scan tab's footer panel.
public enum ScanPanelAction: String, Sendable, Hashable {
    /// After "Not one of our labels" (`strings.scan.scanAgain`).
    case scanAgain
    /// After a failed lookup (`strings.common.tryAgain`, refresh icon).
    case tryAgain
    /// The code list (`strings.scan.typeCode`, keyboard icon).
    case typeCode

    public var label: String {
        switch self {
        case .scanAgain: L10n.Scan.scanAgain
        case .tryAgain: L10n.Common.tryAgain
        case .typeCode: L10n.Scan.typeCode
        }
    }
}

/// The notice over the bottom of the camera picture (RN `ScanPanel`, 06 §8.2).
public struct ScanPanel: Sendable, Hashable {
    public enum Tone: String, Sendable, Hashable {
        /// The standing hint: no live region, no announcement.
        case hint
        /// "Opening that label…" with a spinner: a polite live region.
        case busy
        /// Not ours, or a failed lookup: an assertive live region with the error edge.
        case error
    }

    public var tone: Tone
    public var title: String?
    public var message: String
    public var actions: [ScanPanelAction]

    public init(tone: Tone, title: String?, message: String, actions: [ScanPanelAction]) {
        self.tone = tone
        self.title = title
        self.message = message
        self.actions = actions
    }

    /// What VoiceOver announces when the panel appears: `"<title>. <message>"`, or the message;
    /// nothing for the hint, which is not news.
    public var announcement: String? {
        guard tone != .hint else { return nil }
        return title.map { "\($0). \(message)" } ?? message
    }
}

/// The Scan tab, "What's in this box?" (RN `app/(tabs)/scan.tsx`, 06 §8): point the camera at a
/// label and its container opens; a label of ours that is not linked goes to `/c/<token>`;
/// anything else says plainly it is not ours; a failed lookup says what went wrong.
///
/// The view reports focus (``focusGained()`` / ``focusLost()``), a re-tap of the Scan tab
/// (``tabReselected()``) and the removed-phone layer (``setRevoked(_:)``), and drives ``scanner``.
/// Lookups are numbered: one that finishes after the tab was left, or after a newer one started,
/// changes nothing.
@MainActor
@Observable
public final class ScanModel {
    public private(set) var phase: ScanPhase = .camera
    public private(set) var result: ScanResult = .idle
    /// "Opening that label…" shows only once a lookup has run 180 ms (RN `useDelayedFlag`).
    public private(set) var showsOpening = false
    /// The removed-phone layer is up: the scanner is off under it.
    public private(set) var isRevoked = false
    /// The camera part.
    public let scanner: QrScannerModel

    private let qr: @MainActor @Sendable () -> any QrRepository
    private let haptics: HapticPlayer
    private let telemetry: TelemetryReporter
    private let clock: any Clock<Duration>
    private let navigate: @MainActor @Sendable (ScanNavigation) -> Void

    @ObservationIgnored private var lookupGeneration = 0
    @ObservationIgnored private var isFocused = false
    @ObservationIgnored private var openingTask: Task<Void, Never>?

    /// - Parameters:
    ///   - permission: The tab's camera permission (purpose `scan`).
    ///   - qr: The QR repository in use now (local, or the household's).
    ///   - clock: The reticle lock and the 180 ms busy delay.
    public init(
        permission: CameraPermissionModel,
        qr: @escaping @MainActor @Sendable () -> any QrRepository,
        haptics: @escaping HapticPlayer,
        telemetry: TelemetryReporter = .shared,
        clock: any Clock<Duration> = ContinuousClock(),
        navigate: @escaping @MainActor @Sendable (ScanNavigation) -> Void
    ) {
        self.qr = qr
        self.haptics = haptics
        self.telemetry = telemetry
        self.clock = clock
        self.navigate = navigate
        scanner = QrScannerModel(title: L10n.Scan.title, permission: permission, clock: clock)
        scanner.onScan = { [weak self] raw in await self?.open(raw) }
    }

    // MARK: Derived state

    /// The scanner is on: in the camera phase (RN rendered no `QrScanner` in the code phase), not
    /// under the removed-phone layer, and not while a notice waits for an answer.
    // RN: app/(tabs)/scan.tsx:271-291, :336-338
    public var scannerActive: Bool { phase == .camera && !isRevoked && result.keepsScanning }

    /// The permission screen's copy for the Scan tab, which always offers typing a code instead.
    public func permissionCopy(isPaired: Bool) -> CameraPermissionCopy {
        scanner.permission.copy(isPaired: isPaired, offersLibrary: false, offersManual: true)
    }

    /// The footer panel for the camera phase (06 §8.2).
    public var panel: ScanPanel {
        switch result {
        case .notOurs:
            return ScanPanel(tone: .error, title: L10n.Scan.invalidTitle, message: L10n.Scan.invalidBody, actions: [.scanAgain, .typeCode])
        case .failed(let cause):
            let described = describeError(cause)
            return ScanPanel(tone: .error, title: described.title, message: described.body, actions: [.tryAgain, .typeCode])
        case .idle, .opening:
            if showsOpening {
                return ScanPanel(tone: .busy, title: nil, message: L10n.Scan.opening, actions: [])
            }
            return ScanPanel(tone: .hint, title: nil, message: L10n.Scan.hint, actions: [.typeCode])
        }
    }

    // MARK: Events

    /// The tab came to the front: every visit starts at the camera with nothing in the way.
    // RN: app/(tabs)/scan.tsx:179-189
    public func focusGained() {
        isFocused = true
        showCamera()
        setResult(.idle)
        scanner.focusGained()
    }

    /// The tab left the front: a lookup still in flight is dropped.
    public func focusLost() {
        isFocused = false
        lookupGeneration += 1
        scanner.focusLost()
    }

    /// Scan re-tapped while in front: back to the camera, past a notice; a lookup in flight is left
    /// to finish.
    // RN: app/(tabs)/scan.tsx:191-201
    public func tabReselected() {
        guard isFocused else { return }
        showCamera()
        if result.isOpening {
            syncScanner()
        } else {
            setResult(.idle)
        }
    }

    /// The removed-phone layer came or went (the tab stays focused under it).
    public func setRevoked(_ revoked: Bool) {
        isRevoked = revoked
        syncScanner()
    }

    /// A code the scanner handed over (RN `open`). Ignored unless the camera phase is up and the
    /// tab in front: the scanner hands codes over after its 250 ms lock, and the person may have
    /// left meanwhile.
    // RN: app/(tabs)/scan.tsx:215-251
    public func open(_ raw: String) async {
        guard phase == .camera, isFocused else { return }
        lookupGeneration += 1
        let lookup = lookupGeneration
        setResult(.opening)

        let outcome: ScanOutcome
        do {
            outcome = try await qr().resolveScan(raw)
        } catch {
            guard lookup == lookupGeneration else { return }
            telemetry.error("qr_scan_failed", ["errorClass": .string(describeError(error).kind.rawValue)])
            haptics(.error)
            setResult(.failed(error))
            return
        }
        guard lookup == lookupGeneration else { return }

        switch outcome {
        case .bound(let container, _):
            telemetry.event("qr_scan", ["outcome": .string("bound")])
            haptics(.success)
            setResult(.idle)
            leave(to: .openContainer(id: container.id))
        case .unknown(let token):
            telemetry.event("qr_scan", ["outcome": .string("unknown")])
            setResult(.idle)
            leave(to: .openLabel(token: token))
        case .invalid:
            telemetry.event("qr_scan", ["outcome": .string("invalid")])
            haptics(.error)
            setResult(.notOurs)
        }
    }

    /// "Scan again" or "Try again": re-arms the scanner; the old lookup is not run again.
    public func scanAgain() {
        setResult(.idle)
    }

    /// "Type a code instead": the code list; a label still being looked up must not open over it.
    /// The scanner goes away with the camera phase.
    public func typeCode() {
        lookupGeneration += 1
        phase = .code
        setResult(.idle)
    }

    /// "Back to the camera": a fresh scanner, as RN mounted a new `QrScanner`.
    public func backToCamera() {
        showCamera()
        syncScanner()
    }

    /// A container picked from the code list. Once it opens, this tab is no longer in front, so a
    /// second tap on the row does not push it twice.
    // RN: app/(tabs)/scan.tsx:264-269
    public func openTyped(containerId: String) {
        guard isFocused else { return }
        leave(to: .openContainer(id: containerId))
    }

    // MARK: Internals

    /// Shows the camera phase. Coming back from the code list puts up a fresh scanner (torch off,
    /// new arming): RN unmounted `QrScanner` for the code phase, so a scan accepted before it
    /// (say, during a lookup the code list then dropped) cannot leave the camera disarmed.
    private func showCamera() {
        guard phase != .camera else { return }
        phase = .camera
        scanner.reset()
    }

    /// Navigates away: the pushed screen covers the tab at once, as `navigation.isFocused()` turned
    /// false in RN, so codes and rows that arrive before the view reports it are ignored.
    private func leave(to destination: ScanNavigation) {
        isFocused = false
        navigate(destination)
    }

    private func setResult(_ next: ScanResult) {
        let wasOpening = result.isOpening
        result = next
        if next.isOpening != wasOpening {
            openingTask?.cancel()
            openingTask = nil
            showsOpening = false
            if next.isOpening {
                openingTask = Task { [weak self, clock] in
                    do {
                        try await clock.sleep(for: .milliseconds(Motion.delay.skeleton))
                    } catch {
                        return
                    }
                    // Cancelled after the wait ended but before this ran: the lookup is over.
                    guard !Task.isCancelled else { return }
                    self?.showsOpening = true
                }
            }
        }
        syncScanner()
    }

    private func syncScanner() {
        scanner.setActive(scannerActive)
    }
}
