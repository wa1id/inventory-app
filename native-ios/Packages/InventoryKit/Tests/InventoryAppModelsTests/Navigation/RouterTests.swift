import Foundation
import InventoryCore
import InventoryServices
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

// The Router: RN src/ui/navigation.ts helpers (06 §3.3), the tab bar's Add slot (06 §4.3),
// modal-stack semantics, route results (06 §3.4) and removal hooks. Names carry the Navigation
// prefix so they never meet another area's helpers in this target.

@MainActor
private func navigationRouter(haptics: SharedSeamsHapticRecorder? = nil, clock: any Clock<Duration> = ContinuousClock()) -> Router {
    guard let haptics else { return Router(clock: clock) }
    return Router(haptics: haptics.player, clock: clock)
}

private let navigationStoredPhoto = StoredImage(
    uri: "file:///Documents/item-photos/p.webp", thumbUri: "file:///Documents/item-photos/p-thumb.webp",
    width: 646, height: 1400, byteSize: 1234)

@Suite("Router › navigation helpers (RN navigation.ts)")
@MainActor
struct NavigationHelperTests {
    @Test("goToTab closes what is presented, selects the tab and pops it to its root, keeping other tabs' stacks")
    func goToTab() {
        let router = navigationRouter()
        router.push(.settings)
        router.selectTab(.spaces)
        router.push(.space(id: "s1"))
        router.present(.sheet(.spaceEdit(id: "s1")))

        router.goToTab(.home)

        #expect(router.selectedTab == .home)
        #expect(router.modals.isEmpty)
        #expect(router.path(.home).isEmpty)
        #expect(router.path(.spaces).map(\.route) == [.space(id: "s1")])
    }

    @Test("goToTab ignores Add, which has no screen")
    func goToAdd() {
        let router = navigationRouter()
        router.goToTab(.add)
        #expect(router.selectedTab == .home)
        #expect(router.modals.isEmpty)
    }

    @Test("openContainer sends the drop zone to its tab and pushes any other container on the stack in front")
    func openContainer() {
        let router = navigationRouter()
        router.openContainer("c1")
        #expect(router.path(.home).map(\.route) == [.container(id: "c1")])

        router.openContainer(DropZone.containerId)
        #expect(router.selectedTab == .dropZone)
        #expect(router.path(.dropZone).isEmpty)
        #expect(!router.state.paths.values.flatMap { $0 }.contains { $0.route == .container(id: DropZone.containerId) })

        // Inside a cover, the push stays in the cover's own stack.
        router.present(.cover(.capture(.quickSnap, request: nil)))
        router.openContainer("c2")
        #expect(router.modals.last?.path.map(\.route) == [.container(id: "c2")])
        #expect(router.path(.dropZone).isEmpty)
    }

    @Test("openSpace sends the drop zone's system space to its tab and pushes any other space")
    func openSpace() {
        let router = navigationRouter()
        router.openSpace("s1")
        #expect(router.path(.home).map(\.route) == [.space(id: "s1")])
        router.openSpace(DropZone.spaceId)
        #expect(router.selectedTab == .dropZone)
    }

    @Test(
        "focusSearch asks Home to focus after the transition only when screens close on the way",
        arguments: [
            (name: "from another tab's root", setup: 0, afterTransition: false),
            (name: "from a pushed screen", setup: 1, afterTransition: true),
            (name: "from a sheet", setup: 2, afterTransition: true),
        ]
    )
    func focusSearch(name: String, setup: Int, afterTransition: Bool) {
        let router = navigationRouter()
        router.selectTab(.spaces)
        if setup == 1 { router.push(.space(id: "s1")) }
        if setup == 2 { router.present(.sheet(.spaceNew(request: nil))) }

        router.focusSearch()

        #expect(router.searchFocus.pending == HomeSearchFocus.Request(afterTransition: afterTransition))
        #expect(router.selectedTab == .home)
        #expect(router.modals.isEmpty)
    }

    @Test("openQuickSnap presents the camera in fast mode on the drop zone, with nobody waiting")
    func openQuickSnap() {
        let router = navigationRouter()
        router.openQuickSnap()
        #expect(router.modals.map(\.route) == [.cover(.capture(.quickSnap, request: nil))])
        #expect(CaptureRoute.quickSnap == CaptureRoute(containerId: DropZone.containerId, mode: .fast))
    }

    @Test("a finished sheet dismissal lets a waiting search-focus request focus Home")
    func dismissalEndsTransition() async {
        let router = navigationRouter()
        router.present(.sheet(.spaceNew(request: nil)))
        router.focusSearch()
        router.searchFocus.homeFocusChanged(true)
        #expect(router.searchFocus.isWaitingForTransition)
        router.modalDismissalFinished()
        #expect(router.searchFocus.focusRequests == 1)
    }
}

@Suite("Router › the tab bar")
@MainActor
struct NavigationTabBarTests {
    @Test("tapping Add plays tap and presents the Add sheet with no params, without switching tabs")
    func addTap() {
        let haptics = SharedSeamsHapticRecorder()
        let router = navigationRouter(haptics: haptics)
        router.selectTab(.spaces)

        router.selectTab(.add)

        #expect(router.selectedTab == .spaces)
        #expect(router.modals.map(\.route) == [.sheet(.addItem(AddParams()))])
        #expect(haptics.played == [.tap])
    }

    @Test("re-tapping the selected tab at its root sends its re-tap signal; with a stack it pops to the root instead")
    func reselect() {
        let router = navigationRouter()
        router.selectTab(.home)
        #expect(router.reselections[.home] == 1)

        router.push(.settings)
        router.selectTab(.home)
        #expect(router.path(.home).isEmpty)
        #expect(router.reselections[.home] == 1)

        router.selectTab(.home)
        #expect(router.reselections[.home] == 2)
    }

    @Test("selecting another tab keeps each tab's stack")
    func switchTabs() {
        let router = navigationRouter()
        router.push(.settings)
        router.selectTab(.scan)
        router.push(.label(token: "abc"))
        router.selectTab(.home)
        #expect(router.path(.home).map(\.route) == [.settings])
        #expect(router.path(.scan).map(\.route) == [.label(token: "abc")])
        #expect(router.reselections.isEmpty)
    }

    @Test("a long press on Add plays longPress and opens Quick Snap; the tab bar's own Add selection right after is ignored")
    func addLongPress() async throws {
        let haptics = SharedSeamsHapticRecorder()
        let clock = ManualClock()
        let router = navigationRouter(haptics: haptics, clock: clock)

        router.addLongPressed()
        #expect(haptics.played == [.longPress])
        #expect(router.modals.map(\.route) == [.cover(.capture(.quickSnap, request: nil))])

        router.selectTab(.add)
        #expect(router.modals.count == 1)
        #expect(haptics.played == [.longPress])

        router.dismissTop()
        await clock.advance(by: Router.addLongPressSuppression)
        router.selectTab(.add)
        #expect(router.modals.map(\.route) == [.sheet(.addItem(AddParams()))])
        #expect(haptics.played == [.longPress, .tap])
    }

    @Test("a long press held for a while still swallows the selection made when the finger lifts")
    func longHold() async throws {
        let clock = ManualClock()
        let router = navigationRouter(clock: clock)
        router.addLongPressed()
        await clock.advance(by: .seconds(3))
        router.addLongPressEnded()
        await clock.advance(by: .milliseconds(300))
        router.selectTab(.add)
        #expect(router.modals.map(\.route) == [.cover(.capture(.quickSnap, request: nil))])

        // The end of an Add tap that was never a long press changes nothing.
        router.dismissTop()
        router.addLongPressEnded()
        router.selectTab(.add)
        #expect(router.modals.map(\.route) == [.sheet(.addItem(AddParams()))])
    }

    @Test("badge text and labels follow RN's TabBar", arguments: [
        (waiting: 0, badge: nil as String?, label: "Drop zone"),
        (waiting: 3, badge: "3", label: "Drop zone, 3 waiting"),
        (waiting: 99, badge: "99", label: "Drop zone, 99 waiting"),
        (waiting: 100, badge: "99+", label: "Drop zone, 100 waiting"),
    ])
    func badge(waiting: Int, badge: String?, label: String) {
        #expect(AppTab.badgeText(waiting: waiting) == badge)
        #expect(AppTab.dropZone.accessibilityLabel(waiting: waiting) == label)
    }

    @Test("tabs keep RN's order, testIDs and the Add label")
    func tabs() {
        #expect(AppTab.allCases.map(\.accessibilityIdentifier) == ["tab-home", "tab-spaces", "tab-add", "tab-scan", "tab-drop-zone"])
        #expect(AppTab.destinations == [.home, .spaces, .scan, .dropZone])
        #expect(AppTab.add.accessibilityLabel() == "Add an item")
        #expect(AppTab.home.accessibilityLabel(waiting: 5) == "Home")
    }
}

@Suite("Router › stacks and the modal stack")
@MainActor
struct NavigationStackTests {
    @Test("pushes go on the top modal's stack while anything is presented, else on the selected tab's")
    func pushTarget() {
        let router = navigationRouter()
        let settings = router.push(.settings)
        router.present(.sheet(.spaceNew(request: nil)))
        let inSheet = router.push(.household)
        #expect(router.path(.home) == [settings])
        #expect(router.modals[0].path == [inSheet])
        #expect(settings.id != inSheet.id)
    }

    @Test("replace swaps a pushed screen only while it is the top of its stack")
    func replaceOnlyOnTop() {
        let router = navigationRouter()
        let label = router.push(.label(token: "abc"))
        #expect(router.replace(label.address, with: .container(id: "c1")))
        #expect(router.path(.home).map(\.route) == [.container(id: "c1")])
        #expect(router.path(.home).first?.id != label.id)

        let second = router.push(.label(token: "def"))
        router.push(.settings)
        #expect(!router.replace(second.address, with: .container(id: "c2")))
        #expect(!router.replace(label.address, with: .container(id: "c3")))
        #expect(!router.replace(.tabRoot(.home), with: .container(id: "c4")))
    }

    @Test("sheets stack over sheets and covers over sheets, each with its own stack")
    func modalStack() {
        let router = navigationRouter()
        let add = router.present(.sheet(.addItem(AddParams())))
        let container = router.present(.sheet(.containerNew(spaceId: "s1", request: nil)))
        let space = router.present(.sheet(.spaceNew(request: nil)))
        #expect(router.modals.map(\.id) == [add.id, container.id, space.id])
        #expect(router.sheet(atLevel: 2)?.id == space.id)
        #expect(router.cover(atLevel: 2) == nil)

        router.dismissTop()
        let camera = router.present(.cover(.capture(CaptureRoute(containerId: "c1"), request: nil)))
        #expect(router.cover(atLevel: 2)?.id == camera.id)
        #expect(router.sheet(atLevel: 2) == nil)
    }

    @Test("replacing a modal with one of another kind presents anew; with one of the same kind it keeps the presentation")
    func replaceModal() {
        let router = navigationRouter()
        let add = router.present(.sheet(.addItem(AddParams())))
        let camera = router.replaceModal(containing: add.address, with: .cover(.capture(CaptureRoute(containerId: "c1", mode: .fast), request: nil)))
        #expect(camera?.id != add.id)
        #expect(router.modals.count == 1)
        #expect(router.modals[0].route == .cover(.capture(CaptureRoute(containerId: "c1", mode: .fast), request: nil)))

        let review = router.push(.quickSnapReview(QuickSnapReviewRoute(containerId: "c1", since: 10, expected: 2)))
        let again = router.replaceModal(containing: review.address, with: .cover(.capture(CaptureRoute(containerId: "c1", mode: .fast, since: 10, expectedBase: 2), request: nil)))
        #expect(again?.id == camera?.id)
        #expect(again?.screenID != camera?.screenID)
        #expect(router.modals[0].path.isEmpty)
    }

    @Test("a screen can only replace the modal it is in while that modal is on top")
    func replaceModalOnlyOnTop() {
        let router = navigationRouter()
        let add = router.present(.sheet(.addItem(AddParams())))
        router.present(.sheet(.spaceNew(request: nil)))
        #expect(router.replaceModal(containing: add.address, with: .cover(.photo(itemId: "i1"))) == nil)
        #expect(router.modals.count == 2)
        #expect(router.replaceModal(containing: .tabRoot(.home), with: .cover(.photo(itemId: "i1"))) == nil)
    }

    @Test("close pops a pushed screen with what is above it, and dismisses a modal with what is over it")
    func close() {
        let router = navigationRouter()
        let first = router.push(.settings)
        router.push(.household)
        router.close(first.address)
        #expect(router.path(.home).isEmpty)

        let sheet = router.present(.sheet(.addItem(AddParams())))
        router.present(.cover(.capture(CaptureRoute(containerId: "c1"), request: nil)))
        router.close(sheet.address)
        #expect(router.modals.isEmpty)

        router.close(.tabRoot(.home))
        #expect(router.selectedTab == .home)
    }

    @Test("a sheet the system dismissed goes with everything over it; a late report about a replaced one does nothing")
    func systemDismissal() {
        let router = navigationRouter()
        let add = router.present(.sheet(.addItem(AddParams())))
        let space = router.present(.sheet(.spaceNew(request: nil)))
        router.modalDismissedBySystem(space.id)
        #expect(router.modals.map(\.id) == [add.id])

        let camera = router.replaceTopModal(with: .cover(.capture(CaptureRoute(containerId: "c1"), request: nil)))
        router.modalDismissedBySystem(add.id)
        #expect(router.modals.map(\.id) == [camera?.id].compactMap { $0 })
    }

    @Test("dismissAll closes every modal and pops every tab, keeping the selected tab")
    func dismissAll() {
        let router = navigationRouter()
        router.push(.settings)
        router.selectTab(.spaces)
        router.push(.space(id: "s1"))
        router.present(.sheet(.spaceEdit(id: "s1")))
        router.dismissAll()
        #expect(router.modals.isEmpty)
        #expect(AppTab.destinations.allSatisfy { router.path($0).isEmpty })
        #expect(router.selectedTab == .spaces)
    }

    @Test("the stack bindings report back swipes, and an unchanged path changes nothing")
    func bindings() {
        let router = navigationRouter()
        let a = router.push(.settings)
        router.push(.household)
        router.setPath([a], for: .home)
        #expect(router.path(.home) == [a])

        let sheet = router.present(.sheet(.spaceNew(request: nil)))
        let inner = router.push(.space(id: "s1"))
        router.setModalPath([], modal: sheet.id)
        #expect(router.modals[0].path.isEmpty)
        router.setModalPath([inner], modal: 999)
        #expect(router.modals[0].path.isEmpty)
        router.setPath([], for: .add)
        #expect(router.path(.home) == [a])
    }

    @Test("Cancel asks the screen's close guard, and closes only when it agrees")
    func closeGuard() async {
        let router = navigationRouter()
        let sheet = router.present(.sheet(.spaceEdit(id: "s1")))
        let answers = SharedSeamsConfirmScript(answers: [false, true])
        router.setCloseGuard(for: sheet.address) {
            await answers.confirm(ConfirmOptions(title: "Discard?", body: "", confirmLabel: "Discard"))
        }
        await router.requestClose(sheet.address)
        #expect(router.modals.count == 1)
        await router.requestClose(sheet.address)
        #expect(router.modals.isEmpty)
        #expect(answers.asked.count == 2)

        let other = router.present(.sheet(.spaceEdit(id: "s2")))
        await router.requestClose(other.address)
        #expect(router.modals.isEmpty)
    }
}

@Suite("Router › route results (RN routeResult.test.ts over presentations)")
@MainActor
struct NavigationResultTests {
    @Test("presentForResult hands the request to the route and resolves with the delivered value")
    func deliver() async throws {
        let router = navigationRouter()
        let waiting = Task { await router.presentForResult(MoveResult.self) { .sheet(.move(itemId: "i1", filing: false, request: $0)) } }
        await NavigationWait.until { router.modals.count == 1 }
        guard case .sheet(.move(_, _, let request?)) = router.modals[0].route else {
            Issue.record("no request in the route")
            return
        }
        let result = MoveResult(itemId: "i1", from: "a", to: "b", updatedAt: 5)
        #expect(router.results.deliver(request, result))
        #expect(!router.results.deliver(request, result))
        #expect(await waiting.value == result)
        router.close(router.modals[0].address)
    }

    @Test(
        "a modal removed without an answer resolves its opener with nil, exactly once",
        arguments: ["swipe", "close", "dismissAll", "replace", "goToTab", "reset"]
    )
    func dismissedWithoutAnswer(how: String) async throws {
        let router = navigationRouter()
        router.setAcceptsNavigation(true)
        let waiting = Task { await router.presentForResult(NewSpaceResult.self) { .sheet(.spaceNew(request: $0)) } }
        await NavigationWait.until { router.modals.count == 1 }
        let modal = router.modals[0]
        guard case .sheet(.spaceNew(let request?)) = modal.route else {
            Issue.record("no request in the route")
            return
        }
        switch how {
        case "swipe": router.modalDismissedBySystem(modal.id)
        case "close": router.close(modal.address)
        case "dismissAll": router.dismissAll()
        case "replace": router.replaceTopModal(with: .sheet(.spaceEdit(id: "s1")))
        case "goToTab": router.goToTab(.spaces)
        default: router.setAcceptsNavigation(false)
        }
        #expect(await waiting.value == nil)
        #expect(!router.results.deliver(request, NewSpaceResult(spaceId: "s1", name: "Garage")))
        #expect(!router.results.isPending(request))
    }

    @Test("the camera's request is abandoned when its cover is dismissed, resuming the waiting Add sheet with nil")
    func cameraAbandoned() async {
        let router = navigationRouter()
        router.present(.sheet(.addItem(AddParams())))
        let photo = Task { await router.presentForResult(StoredImage.self) { .cover(.capture(CaptureRoute(containerId: "c1"), request: $0)) } }
        await NavigationWait.until { router.modals.count == 2 }
        router.dismissTop()
        #expect(await photo.value == nil)
        #expect(router.modals.count == 1)
    }

    @Test("the camera delivers its photo to the waiting sheet")
    func cameraDelivers() async {
        let router = navigationRouter()
        let photo = Task { await router.presentForResult(StoredImage.self) { .cover(.capture(CaptureRoute(containerId: "c1"), request: $0)) } }
        await NavigationWait.until { router.modals.count == 1 }
        guard case .cover(.capture(_, let request?)) = router.modals[0].route else {
            Issue.record("no request in the route")
            return
        }
        #expect(router.results.deliver(request, navigationStoredPhoto))
        router.dismissTop()
        #expect(await photo.value == navigationStoredPhoto)
    }

    @Test("concurrent requests stay apart")
    func concurrent() async {
        let router = navigationRouter()
        let first = Task { await router.presentForResult(NewContainerResult.self) { .sheet(.containerNew(spaceId: "s1", request: $0)) } }
        await NavigationWait.until { router.modals.count == 1 }
        let second = Task { await router.presentForResult(NewSpaceResult.self) { .sheet(.spaceNew(request: $0)) } }
        await NavigationWait.until { router.modals.count == 2 }
        guard case .sheet(.containerNew(_, let containerRequest?)) = router.modals[0].route,
              case .sheet(.spaceNew(let spaceRequest?)) = router.modals[1].route
        else {
            Issue.record("requests missing")
            return
        }
        #expect(containerRequest.id != spaceRequest.id)
        #expect(router.results.deliver(spaceRequest, NewSpaceResult(spaceId: "s9", name: "Shed")))
        router.dismissTop()
        let container = NewContainerResult(containerId: "c9", name: nil, shortCode: "BOX-4F2A", visualType: .box, spaceId: "s9")
        #expect(router.results.deliver(containerRequest, container))
        router.dismissTop()
        #expect(await second.value == NewSpaceResult(spaceId: "s9", name: "Shed"))
        #expect(await first.value == container)
    }
}

@Suite("Router › removal hooks")
@MainActor
struct NavigationRemovalTests {
    @Test("a popped screen's hook runs once; a covered one's does not")
    func popped() {
        let router = navigationRouter()
        let label = router.push(.label(token: "abc"))
        var closed = 0
        router.onRemoval(of: label.address) { closed += 1 }

        router.push(.settings)
        router.present(.sheet(.spaceNew(request: nil)))
        router.selectTab(.spaces)
        #expect(closed == 0)

        router.selectTab(.home)
        router.dismissTop()
        router.setPath([label], for: .home)
        #expect(closed == 0)
        router.setPath([], for: .home)
        #expect(closed == 1)
        router.push(.settings)
        router.setPath([], for: .home)
        #expect(closed == 1)
    }

    @Test("a replaced screen's hook runs (the label screen replaced by its container)")
    func replaced() {
        let router = navigationRouter()
        let label = router.push(.label(token: "abc"))
        var closed = false
        router.onRemoval(of: label.address) { closed = true }
        router.replace(label.address, with: .container(id: "c1"))
        #expect(closed)
    }

    @Test("dismissing a cover runs its root's hook and the hooks of screens pushed inside it, top first")
    func coverDismissed() {
        let router = navigationRouter()
        let camera = router.present(.cover(.capture(.quickSnap, request: nil)))
        let review = router.push(.quickSnapReview(QuickSnapReviewRoute(containerId: DropZone.containerId, since: 1, expected: 1)))
        var log: [String] = []
        router.onRemoval(of: camera.address) { log.append("camera") }
        router.onRemoval(of: review.address) { log.append("review") }
        router.modalDismissedBySystem(camera.id)
        #expect(log == ["review", "camera"])
    }

    @Test("replacing the camera with a new one in the same cover runs the old camera's hook")
    func inPlaceReplacement() {
        let router = navigationRouter()
        let camera = router.present(.cover(.capture(.quickSnap, request: nil)))
        var disappeared = 0
        router.onRemoval(of: camera.address) { disappeared += 1 }
        let review = router.push(.quickSnapReview(QuickSnapReviewRoute(containerId: DropZone.containerId, since: 1, expected: 1)))
        #expect(disappeared == 0)
        router.replaceModal(containing: review.address, with: .cover(.capture(CaptureRoute(containerId: DropZone.containerId, mode: .fast, since: 1, expectedBase: 1), request: nil)))
        #expect(disappeared == 1)
    }

    @Test("a hook for a screen that is already gone runs at once; reset runs every hook, tab roots' too")
    func goneAndReset() {
        let router = navigationRouter()
        var ran: [String] = []
        router.onRemoval(of: .push(12345)) { ran.append("gone") }
        #expect(ran == ["gone"])

        router.setAcceptsNavigation(true)
        router.onRemoval(of: .tabRoot(.scan)) { ran.append("scan") }
        let pushed = router.push(.settings)
        router.onRemoval(of: pushed.address) { ran.append("settings") }
        router.setAcceptsNavigation(false)
        #expect(ran == ["gone", "settings", "scan"])
        #expect(router.state == RouterState())
    }
}

/// Polls a main-actor condition, yielding to the tasks under test.
enum NavigationWait {
    @MainActor
    static func until(
        timeout: Duration = .seconds(5),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now > deadline {
                Issue.record("timed out", sourceLocation: sourceLocation)
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}
