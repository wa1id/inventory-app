import InventoryCore
import InventoryServices
import InventoryStrings

// RN: the expo-router file tree under app/ and its presentation table in app/_layout.tsx:163-213
// (06 §3.1, 09 §2.5). Every route is a typed value: dependencies never travel in a payload, only
// what the URL carried in RN (ids, flags, the opener's request) plus the capture routes that
// wave 3 already typed.

/// The slots of the tab bar, in order: Home · Spaces · [Add] · Scan · Drop zone
/// (RN src/ui/components/TabBar.tsx:20-28; 06 §4.1, DECISIONS U5).
///
/// ``add`` is an action, not a destination: selecting it presents the Add sheet and leaves the
/// selected tab alone. Each destination has its own navigation stack.
public enum AppTab: String, Sendable, Hashable, CaseIterable {
    case home
    case spaces
    case add
    case scan
    case dropZone

    /// The four tabs that have a screen and a stack, in bar order.
    public static let destinations: [AppTab] = [.home, .spaces, .scan, .dropZone]

    /// Whether the tab has a screen of its own (everything but Add).
    public var isDestination: Bool { self != .add }

    /// The tab's visible label (`strings.tabs.*`).
    public var title: String {
        switch self {
        case .home: L10n.Tabs.home
        case .spaces: L10n.Tabs.spaces
        case .add: L10n.Tabs.add
        case .scan: L10n.Tabs.scan
        case .dropZone: L10n.Tabs.dropZone
        }
    }

    /// The SF Symbol for the tab (08 §5; 06 §4.1).
    public var systemImage: String {
        switch self {
        case .home: "house"
        case .spaces: "square.grid.2x2"
        case .add: "plus"
        case .scan: "qrcode.viewfinder"
        case .dropZone: "tray"
        }
    }

    /// RN's testID, kept as the accessibility identifier so UI tests can find the tab.
    public var accessibilityIdentifier: String {
        switch self {
        case .home: "tab-home"
        case .spaces: "tab-spaces"
        case .add: "tab-add"
        case .scan: "tab-scan"
        case .dropZone: "tab-drop-zone"
        }
    }

    /// The Drop zone badge's text for `waiting` items: none at 0, the number up to 99, then
    /// "99+" (RN TabBar.tsx:93,140-148).
    public static func badgeText(waiting: Int) -> String? {
        guard waiting > 0 else { return nil }
        return waiting > 99 ? "99+" : String(waiting)
    }

    /// The tab's VoiceOver label: the label, or with a badge "Drop zone, 3 waiting"
    /// (RN TabBar.tsx:126-131).
    public func accessibilityLabel(waiting: Int = 0) -> String {
        guard self == .dropZone, waiting > 0 else { return self == .add ? L10n.Tabs.addA11y : title }
        return "\(title), \(L10n.Tabs.waitingA11y(count: waiting))"
    }
}

/// A screen pushed on a navigation stack: a tab's, or the stack inside a sheet or cover
/// (06 §3.1 "push" rows; the Quick Snap review is a push inside the capture cover).
public enum PushRoute: Sendable, Hashable {
    /// `/settings`.
    case settings
    /// `/privacy`.
    case privacy
    /// `/household`.
    case household
    /// `/backup`.
    case backup
    /// `/c/<token>`: a QR label opened from the system Camera or handed over by Scan. The token
    /// is `ScanRules.tokenParam`'s (JS-trimmed); the repository decides whether it is ours.
    case label(token: String)
    /// `/space/<id>`.
    case space(id: String)
    /// `/container/<id>`. Never the drop zone: ``Router/openContainer(_:)`` sends that to its tab.
    case container(id: String)
    /// `/container/<id>/qr`: the container's QR label.
    case qrLabel(containerId: String)
    /// `/item/<id>[?filing=1]`.
    case item(id: String, filing: Bool)
    /// `/capture/review`: pushed inside the capture cover, back button hidden.
    case quickSnapReview(QuickSnapReviewRoute)
}

/// A screen presented as a page sheet with Cancel at the top left (06 §2.1, §3.1 "sheet" rows).
public enum SheetRoute: Sendable, Hashable {
    /// `/item/new`: the Add sheet.
    case addItem(AddParams)
    /// `/space/new[?request=]`.
    case spaceNew(request: RouteRequest<NewSpaceResult>?)
    /// `/space/<id>/edit`.
    case spaceEdit(id: String)
    /// `/container/new?spaceId[&request=]`.
    case containerNew(spaceId: String, request: RouteRequest<NewContainerResult>?)
    /// `/container/<id>/edit`.
    case containerEdit(id: String)
    /// `/item/<id>/edit`.
    case itemEdit(id: String)
    /// `/item/<id>/move[?filing=1][&request=]`.
    case move(itemId: String, filing: Bool, request: RouteRequest<MoveResult>?)
}

/// A screen presented full screen with no header (06 §3.1 "cover" rows).
public enum CoverRoute: Sendable, Hashable {
    /// `/capture?containerId&mode&since[&request=]`: the camera. With a request it is the Add
    /// sheet's single photo, delivered as a `StoredImage`.
    case capture(CaptureRoute, request: RouteRequest<StoredImage>?)
    /// `/item/<id>/photo`: the photo viewer.
    case photo(itemId: String)
    /// `/container/<id>/link`: linking a printed sticker.
    case linkSticker(containerId: String)
}

/// A presented screen: a sheet or a full-screen cover.
public enum ModalRoute: Sendable, Hashable {
    case sheet(SheetRoute)
    case cover(CoverRoute)

    /// Whether this is a sheet (as opposed to a cover).
    public var isSheet: Bool {
        if case .sheet = self { return true }
        return false
    }

    /// The Add sheet draws its own Cancel, which asks before throwing the draft away (06 §2.1,
    /// §10.6); every other sheet gets the shell's.
    public var usesShellCancel: Bool {
        if case .sheet(let sheet) = self, case .addItem = sheet { return false }
        return isSheet
    }

    /// Answers the opener's request, if any, with nothing (RN `abandonResult` on unmount).
    @MainActor
    func abandonRequest(in results: RouteResults) {
        switch self {
        case .sheet(.spaceNew(let request)): results.abandon(request)
        case .sheet(.containerNew(_, let request)): results.abandon(request)
        case .sheet(.move(_, _, let request)): results.abandon(request)
        case .cover(.capture(_, let request)): results.abandon(request)
        case .sheet(.addItem), .sheet(.spaceEdit), .sheet(.containerEdit), .sheet(.itemEdit),
             .cover(.photo), .cover(.linkSticker):
            break
        }
    }
}

/// One screen on a navigation stack. The id tells two pushes of the same route apart, so the
/// router can call the right screen's removal hooks and focus the right one.
public struct PushEntry: Sendable, Hashable, Identifiable {
    public let id: Int
    public let route: PushRoute

    public init(id: Int, route: PushRoute) {
        self.id = id
        self.route = route
    }

    /// Where this screen is, for focus and removal hooks.
    public var address: ScreenAddress { .push(id) }
}

/// One presented sheet or cover with the stack inside it.
public struct ModalEntry: Sendable, Hashable, Identifiable {
    /// The presentation's identity: what `.sheet(item:)` and `.fullScreenCover(item:)` key on.
    /// It stays the same when the root is replaced by a route of the same kind (Keep shooting
    /// replaces the review with a new camera in the same cover), so nothing re-presents.
    public let id: Int
    /// The root screen's identity; a new one whenever the root route is replaced.
    public let screenID: Int
    public var route: ModalRoute
    /// Screens pushed inside the modal (the review over the camera, an item opened from it).
    public var path: [PushEntry]

    public init(id: Int, screenID: Int, route: ModalRoute, path: [PushEntry] = []) {
        self.id = id
        self.screenID = screenID
        self.route = route
        self.path = path
    }

    /// The root screen's address.
    public var address: ScreenAddress { .modal(screenID) }

    public var isSheet: Bool { route.isSheet }
}

/// Where a screen is shown: a tab root, a pushed screen (in a tab's stack or a modal's), or a
/// modal's root. Screens learn theirs from the environment and pass it back to the router to
/// replace or close themselves, register removal hooks and close guards.
public enum ScreenAddress: Sendable, Hashable {
    case tabRoot(AppTab)
    /// A ``PushEntry`` by id.
    case push(Int)
    /// A ``ModalEntry``'s root by its `screenID`.
    case modal(Int)
}

/// A screen position by index, as the focus rules read it (09 §5, 00-index §5).
public enum ScreenPosition: Sendable, Hashable {
    case tabRoot(AppTab)
    /// The screen at `index` in `tab`'s stack (0 is the first push).
    case tabPush(AppTab, index: Int)
    /// The root of the modal at `level` (0 is the first presented).
    case modalRoot(level: Int)
    /// The screen at `index` in the stack inside the modal at `level`.
    case modalPush(level: Int, index: Int)
}

/// A request from outside the app, queued until the main shell shows (DECISIONS U5).
public enum ExternalRequest: Sendable, Hashable {
    case deepLink(DeepLink)
    case quickAction(AppQuickAction)
}

/// The Home Screen quick actions (`UIApplicationShortcutItems` in Info.plist).
public enum AppQuickAction: String, Sendable, Hashable, CaseIterable {
    /// "Quick Snap" (`strings.tabs.quickSnapAction`): fast capture into the drop zone, as the
    /// Add tab's long press.
    case quickSnap = "com.wystudio.inventory.quickSnap"
}
