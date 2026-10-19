import InventoryCore
import InventoryStrings
import Observation

/// `AVAuthorizationStatus` for video, without AVFoundation (05 §16.1). The app target maps
/// `AVCaptureDevice.authorizationStatus(for: .video)` onto it.
public enum CameraAuthorization: String, Sendable, Hashable, CaseIterable {
    case notDetermined
    case restricted
    case denied
    case authorized
}

/// What the camera is for: the capture screen or the Scan tab (and the sticker-link cover).
public enum CameraPermissionPurpose: String, Sendable, Hashable {
    case capture
    case scan
}

/// Which screen the permission gate shows (05 §16.1, 06 §8.5).
///
/// RN read the permission asynchronously and showed a black wait first; AVFoundation answers
/// synchronously, so that state does not exist natively.
public enum CameraPermissionScreen: String, Sendable, Hashable {
    /// Not asked yet (expo `canAskAgain`): the rationale with Allow camera.
    case rationale
    /// Denied or restricted (expo `!canAskAgain`): the blocked screen with Open Settings.
    case blocked
    /// The camera itself.
    case granted

    /// expo-camera's mapping: `.denied` and `.restricted` cannot ask again, `.notDetermined` can.
    // RN: node_modules/expo-camera/ios/Common/CameraPermissionsRequester.swift:32-50
    public init(_ authorization: CameraAuthorization) {
        switch authorization {
        case .notDetermined: self = .rationale
        case .denied, .restricted: self = .blocked
        case .authorized: self = .granted
        }
    }
}

/// The permission screen's words and buttons (RN `CameraPermission`).
public struct CameraPermissionCopy: Sendable, Hashable {
    /// The primary button.
    public enum PrimaryAction: String, Sendable, Hashable {
        /// Ask the system (`strings.permissions.grant`).
        case allow
        /// Open the app's page in Settings (`strings.permissions.openSettings`).
        case openSettings
    }

    /// A way on without the camera, in the order RN draws them.
    public enum Alternative: String, Sendable, Hashable {
        /// Capture: pick a library photo (`strings.permissions.choosePhotoInstead`, secondary).
        case choosePhoto
        /// Capture: open the Add sheet without a photo (`strings.permissions.typeItInstead`, quiet).
        case typeItem
        /// Scan: type the label code (`strings.permissions.typeCodeInstead`, secondary).
        case typeCode

        public var label: String {
            switch self {
            case .choosePhoto: L10n.Permissions.choosePhotoInstead
            case .typeItem: L10n.Permissions.typeItInstead
            case .typeCode: L10n.Permissions.typeCodeInstead
            }
        }
    }

    public var title: String
    public var body: String
    public var primaryAction: PrimaryAction
    public var alternatives: [Alternative]

    public init(title: String, body: String, primaryAction: PrimaryAction, alternatives: [Alternative]) {
        self.title = title
        self.body = body
        self.primaryAction = primaryAction
        self.alternatives = alternatives
    }

    public var primaryLabel: String {
        switch primaryAction {
        case .allow: L10n.Permissions.grant
        case .openSettings: L10n.Permissions.openSettings
        }
    }

    /// The copy for a screen that is not ``CameraPermissionScreen/granted`` (RN
    /// `CameraPermission.tsx:83-170`).
    ///
    /// - Parameters:
    ///   - blocked: Denied for good (`!canAskAgain`).
    ///   - isPaired: A household session exists (the capture rationale says photos are shared).
    ///   - offersLibrary: Capture's "Choose a photo instead" (always offered by the camera).
    ///   - offersManual: "Type it instead" / "Type a code instead" (never in request mode).
    // RN: src/ui/components/CameraPermission.tsx:83-170
    public static func make(
        purpose: CameraPermissionPurpose,
        blocked: Bool,
        isPaired: Bool,
        offersLibrary: Bool,
        offersManual: Bool
    ) -> CameraPermissionCopy {
        let scan = purpose == .scan
        let body = if blocked {
            scan ? L10n.Permissions.offBodyScan : L10n.Permissions.offBodyCapture
        } else if scan {
            L10n.Permissions.scanBody
        } else {
            isPaired ? L10n.Permissions.captureBodyPaired : L10n.Permissions.captureBodyLocal
        }
        var alternatives: [Alternative] = []
        if scan {
            if offersManual { alternatives.append(.typeCode) }
        } else {
            if offersLibrary { alternatives.append(.choosePhoto) }
            if offersManual { alternatives.append(.typeItem) }
        }
        return CameraPermissionCopy(
            title: blocked ? L10n.Permissions.cameraDeniedTitle : L10n.Permissions.cameraRationaleTitle,
            body: body,
            primaryAction: blocked ? .openSettings : .allow,
            alternatives: alternatives
        )
    }
}

/// The camera permission as one screen sees it: the gate for capture and scan, and the Allow
/// button (RN `useCameraPermissions` plus `CameraPermission.allow`).
///
/// The screen owns its model, so a grant swaps it straight to the camera. Re-read with
/// ``refresh()`` when the app becomes active (the person may have changed it in Settings).
@MainActor
@Observable
public final class CameraPermissionModel {
    public let purpose: CameraPermissionPurpose
    /// The last status read.
    public private(set) var authorization: CameraAuthorization

    private let readAuthorization: @MainActor @Sendable () -> CameraAuthorization
    private let requestAccess: @Sendable () async -> Bool
    private let telemetry: TelemetryReporter
    @ObservationIgnored private var asking = false

    /// - Parameters:
    ///   - readAuthorization: `AVCaptureDevice.authorizationStatus(for: .video)`, mapped.
    ///   - requestAccess: `await AVCaptureDevice.requestAccess(for: .video)`.
    public init(
        purpose: CameraPermissionPurpose,
        readAuthorization: @escaping @MainActor @Sendable () -> CameraAuthorization,
        requestAccess: @escaping @Sendable () async -> Bool,
        telemetry: TelemetryReporter = .shared
    ) {
        self.purpose = purpose
        self.readAuthorization = readAuthorization
        self.requestAccess = requestAccess
        self.telemetry = telemetry
        authorization = readAuthorization()
    }

    /// Which screen to show.
    public var screen: CameraPermissionScreen { CameraPermissionScreen(authorization) }

    /// RN `permission.granted`.
    public var isGranted: Bool { authorization == .authorized }

    /// The rationale or blocked copy for this purpose.
    public func copy(isPaired: Bool, offersLibrary: Bool, offersManual: Bool) -> CameraPermissionCopy {
        CameraPermissionCopy.make(
            purpose: purpose,
            blocked: screen == .blocked,
            isPaired: isPaired,
            offersLibrary: offersLibrary,
            offersManual: offersManual
        )
    }

    /// Reads the status again (on becoming active).
    public func refresh() {
        authorization = readAuthorization()
    }

    /// Allow camera: asks the system, logs `permission_result {permission: camera, outcome:
    /// granted | denied}`, then reads the status the answer left (RN `allow`). A second press
    /// while the prompt is up does nothing.
    // RN: src/ui/components/CameraPermission.tsx:95-101
    public func allow() async {
        guard !asking else { return }
        asking = true
        defer { asking = false }
        let granted = await requestAccess()
        telemetry.event("permission_result", [
            "permission": .string("camera"),
            "outcome": .string(granted ? "granted" : "denied"),
        ])
        authorization = readAuthorization()
    }
}
