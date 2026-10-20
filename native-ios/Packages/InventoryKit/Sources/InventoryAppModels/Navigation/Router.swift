import Foundation
import InventoryCore
import InventoryServices
import Observation

/// The app's navigation: the selected tab, one stack per tab, the modal stack, route results,
/// the one-shot search-focus request, re-tap signals and queued external requests
/// (RN src/ui/navigation.ts, routeResult.ts, searchFocus.ts and the expo-router stack; 06 §3-4,
/// DECISIONS U5).
///
/// **Stacks.** Pushes go on the stack in front: the top modal's own stack while anything is
/// presented, else the selected tab's. Modals stack: a sheet over a sheet (Add → New container →
/// New space), a cover over a sheet (Add → camera), and a modal may be replaced by another (the
/// Add sheet by the camera). The views bind to ``state`` and report what the system did
/// (a back swipe, a sheet swiped away) through ``setPath(_:for:)``, ``setModalPath(_:modal:)``
/// and ``modalDismissedBySystem(_:)``.
///
/// **Removal hooks.** A screen whose model must hear that it is gone (the label screen's
/// `LabelLinkModel.close()`, the camera's `CaptureModel.disappeared()`) registers with
/// ``onRemoval(of:perform:)``. The router calls the hook when the screen's route is removed:
/// popped, dismissed, replaced, reset, never merely covered or scrolled off (SwiftUI's
/// `onDisappear` fires for both, so it is not used for this).
///
/// **Results.** ``presentForResult(_:_:)`` presents a modal with a fresh request and returns its
/// value, or nil once the modal is removed without one; it resumes exactly once. Answering screens
/// call ``results`` (`RouteResults.deliver`). Removing a modal abandons its request, so a camera
/// dismissed without a photo resumes the waiting Add sheet with nil.
///
/// **External requests.** A deep link (``open(_:)``) or a Home Screen quick action waits in
/// ``pendingExternalRequest`` until the main shell shows (``setAcceptsNavigation(_:)``): while
/// boot runs or onboarding is pending, the newest one waits and is delivered after.
@MainActor
@Observable
public final class Router {
    /// How long after a long press on Add (its start, then its end) the tab bar's own selection of
    /// Add is ignored, in case the system still selects the item when the finger lifts.
    public nonisolated static let addLongPressSuppression: Duration = .seconds(1)

    /// What is shown.
    public private(set) var state: RouterState
    /// Bumped each time a tab is selected while already selected and at its root: Home scrolls
    /// to the top or focuses search, Spaces and Drop zone scroll to the top, Scan returns to the
    /// camera (06 §4.2).
    public private(set) var reselections: [AppTab: Int] = [:]
    /// A deep link or quick action waiting for the main shell.
    public private(set) var pendingExternalRequest: ExternalRequest?
    /// Whether the main shell is showing, so external requests are delivered at once.
    public private(set) var acceptsNavigation = false

    /// Home's one-shot search-focus request (RN searchFocus.ts).
    public let searchFocus: HomeSearchFocus
    /// Pending results between screens (RN routeResult.ts).
    public let results: RouteResults

    @ObservationIgnored private let haptics: HapticPlayer
    @ObservationIgnored private let stopwatch: Stopwatch
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var removalHandlers: [ScreenAddress: [@MainActor () -> Void]] = [:]
    @ObservationIgnored private var closeGuards: [ScreenAddress: @MainActor () async -> Bool] = [:]
    @ObservationIgnored private var addLongPressedAt: Duration?

    /// - Parameters:
    ///   - results: the app's one result registry.
    ///   - searchFocus: Home's search-focus request.
    ///   - haptics: plays the Add tab's `tap` and `longPress`.
    ///   - clock: measures the long-press suppression.
    public init(
        results: RouteResults = RouteResults(),
        searchFocus: HomeSearchFocus = HomeSearchFocus(),
        haptics: @escaping HapticPlayer = { _ in },
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        state = RouterState()
        self.results = results
        self.searchFocus = searchFocus
        self.haptics = haptics
        stopwatch = Stopwatch(clock)
    }

    // MARK: Reading

    public var selectedTab: AppTab { state.selectedTab }
    public var modals: [ModalEntry] { state.modals }

    public func path(_ tab: AppTab) -> [PushEntry] { state.path(tab) }

    public func modal(_ id: Int) -> ModalEntry? { state.modal(id) }

    /// Whether the screen at `address` is in front.
    public func isFocused(_ address: ScreenAddress) -> Bool { state.isFocused(address) }

    /// Whether the tab shell counts as in front (no sheet or cover over it).
    public var isTabShellFocused: Bool { state.isTabShellFocused }

    /// The sheet presented at `level` of the modal stack, if that modal is a sheet.
    public func sheet(atLevel level: Int) -> ModalEntry? {
        guard state.modals.indices.contains(level), state.modals[level].isSheet else { return nil }
        return state.modals[level]
    }

    /// The cover presented at `level` of the modal stack, if that modal is a cover.
    public func cover(atLevel level: Int) -> ModalEntry? {
        guard state.modals.indices.contains(level), !state.modals[level].isSheet else { return nil }
        return state.modals[level]
    }

    // MARK: Tabs

    /// The tab bar's selection (the `TabView` binding's setter).
    ///
    /// - Add presents the Add sheet with no params and plays `tap`, leaving the selected tab alone
    ///   (RN TabBar.tsx:168-171).
    /// - The selected tab again: at its root, a re-tap signal (``reselections``); otherwise back
    ///   to its root, as the system does.
    /// - Another tab: selected, its stack kept.
    public func selectTab(_ tab: AppTab) {
        if tab == .add {
            if let pressedAt = addLongPressedAt, stopwatch.now - pressedAt < Self.addLongPressSuppression {
                addLongPressedAt = nil
                return
            }
            haptics(.tap)
            present(.sheet(.addItem(AddParams())))
            return
        }
        if tab == state.selectedTab {
            if state.path(tab).isEmpty {
                reselections[tab, default: 0] += 1
            } else {
                var next = state
                next.paths[tab] = []
                commit(next)
            }
            return
        }
        var next = state
        next.selectedTab = tab
        commit(next)
    }

    /// The Add tab was long-pressed (or its "Quick Snap" accessibility action ran): `longPress`,
    /// then Quick Snap (RN TabBar.tsx:173-176,186-189).
    public func addLongPressed() {
        addLongPressedAt = stopwatch.now
        haptics(.longPress)
        openQuickSnap()
    }

    /// The long press on Add ended (the finger lifted): the suppression of the tab bar's own Add
    /// selection runs from now, so a selection made on release is ignored however long the press.
    public func addLongPressEnded() {
        guard addLongPressedAt != nil else { return }
        addLongPressedAt = stopwatch.now
    }

    /// Goes to a tab's root, closing whatever is presented (RN `goToTab`). The other tabs keep
    /// their stacks (per-tab stacks, 06 Q2).
    public func goToTab(_ tab: AppTab) {
        guard tab.isDestination else { return }
        var next = state
        next.modals = []
        next.selectedTab = tab
        next.paths[tab] = []
        commit(next)
    }

    /// Opens a container; the drop zone's is the Drop zone tab (RN `openContainer`).
    public func openContainer(_ id: String) {
        if id == DropZone.containerId {
            goToTab(.dropZone)
        } else {
            push(.container(id: id))
        }
    }

    /// Opens a space; the drop zone's system space is the Drop zone tab (RN `openSpace`).
    public func openSpace(_ id: String) {
        if id == DropZone.spaceId {
            goToTab(.dropZone)
        } else {
            push(.space(id: id))
        }
    }

    /// The search buttons: Home with the keyboard up. When screens are closed on the way, Home
    /// waits for the transition before focusing (RN `focusSearch`).
    public func focusSearch() {
        searchFocus.request(afterTransition: state.canDismiss)
        goToTab(.home)
    }

    /// Quick Snap: fast capture into the drop zone (RN `openQuickSnap`).
    public func openQuickSnap() {
        present(.cover(.capture(.quickSnap, request: nil)))
    }

    // MARK: Stacks

    /// Pushes `route` on the stack in front and returns its entry.
    @discardableResult
    public func push(_ route: PushRoute) -> PushEntry {
        let entry = PushEntry(id: makeID(), route: route)
        var next = state
        if let top = next.modals.indices.last {
            next.modals[top].path.append(entry)
        } else {
            next.paths[next.selectedTab, default: []].append(entry)
        }
        commit(next)
        return entry
    }

    /// Replaces the pushed screen at `address` with `route`, only while it is still the top of
    /// its stack (RN `router.replace` from the label screen, guarded by "still open").
    @discardableResult
    public func replace(_ address: ScreenAddress, with route: PushRoute) -> Bool {
        guard case .push = address, let position = state.position(of: address) else { return false }
        var next = state
        let entry = PushEntry(id: makeID(), route: route)
        switch position {
        case .tabPush(let tab, let index):
            guard index == next.path(tab).count - 1 else { return false }
            next.paths[tab]?[index] = entry
        case .modalPush(let level, let index):
            guard index == next.modals[level].path.count - 1 else { return false }
            next.modals[level].path[index] = entry
        case .tabRoot, .modalRoot:
            return false
        }
        commit(next)
        return true
    }

    /// The stack binding's setter for `tab` (a back swipe, the back button, a re-tap pop).
    public func setPath(_ path: [PushEntry], for tab: AppTab) {
        guard tab.isDestination, path != state.path(tab) else { return }
        var next = state
        next.paths[tab] = path
        commit(next)
    }

    /// The stack binding's setter inside the modal with presentation id `modal`.
    public func setModalPath(_ path: [PushEntry], modal id: Int) {
        guard let level = state.modals.firstIndex(where: { $0.id == id }), state.modals[level].path != path else { return }
        var next = state
        next.modals[level].path = path
        commit(next)
    }

    // MARK: Modals

    /// Presents `route` over everything and returns its entry.
    @discardableResult
    public func present(_ route: ModalRoute) -> ModalEntry {
        let entry = ModalEntry(id: makeID(), screenID: makeID(), route: route)
        var next = state
        next.modals.append(entry)
        commit(next)
        return entry
    }

    public func present(_ sheet: SheetRoute) {
        present(.sheet(sheet))
    }

    public func present(_ cover: CoverRoute) {
        present(.cover(cover))
    }

    /// Presents `make(request)` and waits for its value: the value on delivery, nil once the
    /// modal is removed without one (RN `openForResult`). Resumes exactly once.
    public func presentForResult<Value: Sendable>(
        _ type: Value.Type = Value.self,
        _ make: (RouteRequest<Value>) -> ModalRoute
    ) async -> Value? {
        let value = try? await results.open(Value.self) { request in
            _ = present(make(request))
        }
        return value ?? nil
    }

    /// Replaces the top modal with `route` (the Add sheet by the camera). A route of the same kind
    /// keeps the presentation and gets a new root (and an empty stack); another kind dismisses the
    /// modal and presents the new one. Returns nil when nothing is presented.
    @discardableResult
    public func replaceTopModal(with route: ModalRoute) -> ModalEntry? {
        guard let top = state.modals.indices.last else { return nil }
        return replaceModal(atLevel: top, with: route)
    }

    /// Replaces the modal whose root or stack holds `address` with `route`, only while that modal
    /// is the top one (a screen replacing itself: Snap several, Keep shooting, the camera handing
    /// a photo to a new Add sheet).
    @discardableResult
    public func replaceModal(containing address: ScreenAddress, with route: ModalRoute) -> ModalEntry? {
        guard let level = state.modalLevel(containing: address), level == state.modals.count - 1 else { return nil }
        return replaceModal(atLevel: level, with: route)
    }

    private func replaceModal(atLevel level: Int, with route: ModalRoute) -> ModalEntry {
        let old = state.modals[level]
        let sameKind = old.isSheet == route.isSheet
        let entry = ModalEntry(id: sameKind ? old.id : makeID(), screenID: makeID(), route: route)
        var next = state
        next.modals[level] = entry
        next.modals.removeSubrange((level + 1)...)
        commit(next)
        return entry
    }

    /// Closes the top modal.
    public func dismissTop() {
        guard !state.modals.isEmpty else { return }
        var next = state
        next.modals.removeLast()
        commit(next)
    }

    /// Closes the screen at `address` (RN `router.back()` from that screen): a pushed screen is
    /// popped with everything above it; a modal's root dismisses the modal and everything
    /// presented over it. Tab roots stay.
    public func close(_ address: ScreenAddress) {
        guard let position = state.position(of: address) else { return }
        var next = state
        switch position {
        case .tabRoot:
            return
        case .tabPush(let tab, let index):
            next.paths[tab]?.removeSubrange(index...)
        case .modalRoot(let level):
            next.modals.removeSubrange(level...)
        case .modalPush(let level, let index):
            next.modals[level].path.removeSubrange(index...)
            next.modals.removeSubrange((level + 1)...)
        }
        commit(next)
    }

    /// The sheet chrome's Cancel: asks the screen's close guard (a dirty form's "Discard your
    /// changes?"), then closes it, exactly as a swipe-down would have.
    public func requestClose(_ address: ScreenAddress) async {
        if let guardClose = closeGuards[address], !(await guardClose()) { return }
        close(address)
    }

    /// Registers what Cancel asks before closing the screen at `address`; nil removes it.
    public func setCloseGuard(for address: ScreenAddress, _ guardClose: (@MainActor () async -> Bool)?) {
        closeGuards[address] = guardClose
    }

    /// Closes every modal and every pushed screen (the removed-phone layer, RN `dismissAll`).
    public func dismissAll() {
        var next = state
        next.modals = []
        next.paths = [:]
        commit(next)
    }

    /// A sheet or cover went away through the system (swiped down, `dismiss()` from inside):
    /// it and everything over it are removed. Unknown ids are ignored, so a late report about a
    /// modal the router already replaced does nothing.
    public func modalDismissedBySystem(_ id: Int) {
        guard let level = state.modals.firstIndex(where: { $0.id == id }) else { return }
        var next = state
        next.modals.removeSubrange(level...)
        commit(next)
    }

    /// A sheet or cover finished animating away: a search-focus request waiting for the
    /// transition may focus now (RN `transitionEnd`).
    public func modalDismissalFinished() {
        searchFocus.transitionEnded()
    }

    // MARK: Removal hooks

    /// Calls `handler` once, when the screen at `address` is removed. A screen that is already
    /// gone is told at once.
    public func onRemoval(of address: ScreenAddress, perform handler: @escaping @MainActor () -> Void) {
        guard state.addresses.contains(address) else {
            handler()
            return
        }
        removalHandlers[address, default: []].append(handler)
    }

    // MARK: External requests

    /// Opens a deep link (`.onOpenURL`). False when the app does not handle the URL.
    @discardableResult
    public func open(_ url: URL) -> Bool {
        guard let link = DeepLink(url: url) else { return false }
        handle(.deepLink(link))
        return true
    }

    /// A Home Screen quick action. False for an unknown type.
    @discardableResult
    public func performQuickAction(type: String) -> Bool {
        guard let action = AppQuickAction(rawValue: type) else { return false }
        handle(.quickAction(action))
        return true
    }

    /// Delivers `request` now when the main shell shows, else keeps it (the newest wins) until it does.
    public func handle(_ request: ExternalRequest) {
        if acceptsNavigation {
            deliver(request)
        } else {
            pendingExternalRequest = request
        }
    }

    /// The root view's gate: true while the main shell shows. Turning it on delivers the request
    /// that waited; turning it off (Settings › How it works replays onboarding) resets the
    /// navigation, as RN swapped the whole tree and came back to a fresh Home.
    public func setAcceptsNavigation(_ accepts: Bool) {
        guard accepts != acceptsNavigation else { return }
        acceptsNavigation = accepts
        if accepts {
            if let request = pendingExternalRequest {
                pendingExternalRequest = nil
                deliver(request)
            }
        } else {
            reset()
        }
    }

    /// Back to Home with nothing pushed or presented; every removal hook runs, tab roots' too.
    public func reset() {
        let tabRootHandlers = AppTab.destinations.flatMap { removalHandlers.removeValue(forKey: .tabRoot($0)) ?? [] }
        commit(RouterState())
        for handler in tabRootHandlers { handler() }
    }

    private func deliver(_ request: ExternalRequest) {
        switch request {
        case .deepLink(.label(let token)):
            // A cold start lands on Home with nothing pushed, so Home is underneath (RN anchor).
            var next = state
            next.modals = []
            next.paths[next.selectedTab, default: []].append(PushEntry(id: makeID(), route: .label(token: token)))
            commit(next)
        case .quickAction(.quickSnap):
            var next = state
            next.modals = []
            commit(next)
            openQuickSnap()
        }
    }

    // MARK: Committing

    private func makeID() -> Int {
        nextID += 1
        return nextID
    }

    /// Applies `next`, then abandons the requests of removed modals and runs removed screens' hooks.
    private func commit(_ next: RouterState) {
        let previous = state
        guard next != previous else { return }
        let kept = next.addresses
        // Top first, as the screens go.
        let removed = previous.orderedAddresses.reversed().filter { !kept.contains($0) }
        let keptModalScreens = Set(next.modals.map(\.screenID))
        let removedModals = previous.modals.reversed().filter { !keptModalScreens.contains($0.screenID) }
        state = next
        for modal in removedModals {
            modal.route.abandonRequest(in: results)
        }
        guard !removed.isEmpty else { return }
        var handlers: [@MainActor () -> Void] = []
        for address in removed {
            closeGuards[address] = nil
            handlers += removalHandlers.removeValue(forKey: address) ?? []
        }
        for handler in handlers {
            handler()
        }
    }
}
