import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Inventory
import InventoryAppModels
import InventoryCore
import InventoryStorage

/// The home area's wiring that is easy to get wrong (06 §3.5, §7.2): the end of a pop on Home's
/// own stack answers a waiting search-focus request, and the Drop zone's File… goes through the
/// router for a `MoveResult` and hides the filed row.
@Suite("Home screens (hosted)", .serialized)
@MainActor
struct HomeScreensHostedTests {
    // MARK: The pop probe

    @Test("the probe reports the end of a pop on its navigation stack")
    func probeReportsThePop() async throws {
        let state = HomeProbeHarnessState(path: [1])
        let host = try ShellTestWindow(HomeProbeHarness(state: state))
        defer { host.close() }
        try await Task.sleep(for: .milliseconds(600))

        state.path = []
        state.waiting = true
        #expect(state.ended == 0)
        await ShellTestWait.until("the pop's end", timeout: .seconds(3)) { state.ended == 1 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(state.ended == 1)
    }

    @Test("with no transition running the probe says nothing (the fallback still applies)")
    func probeWithoutTransition() async throws {
        let state = HomeProbeHarnessState(path: [])
        let host = try ShellTestWindow(HomeProbeHarness(state: state))
        defer { host.close() }
        try await Task.sleep(for: .milliseconds(300))

        state.waiting = true
        try await Task.sleep(for: .milliseconds(800))
        #expect(state.ended == 0)
    }

    @Test("a search button on a screen pushed on Home focuses the field once the pop ends, not after the fallback")
    func searchAfterPopOnHome() async throws {
        let directory = URL.temporaryDirectory.appending(path: "home-hosted-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The fallback never fires on this clock: only the probe can answer the request.
        let app = AppContainer.test(
            resolver: PhotoPathResolver(
                documents: directory.appending(path: "Documents", directoryHint: .isDirectory),
                caches: directory.appending(path: "Caches", directoryHint: .isDirectory)),
            preferences: InMemoryPreferences([PreferenceKey.onboardingCompleted: "true"]),
            clock: HomeFrozenClock())
        let host = try ShellTestWindow(RootView().shellEnvironment(app))
        defer { host.close() }
        await ShellTestWait.until("the main shell") { app.boot.phase == .main && app.router.acceptsNavigation }

        app.router.push(.settings)
        try await Task.sleep(for: .milliseconds(800))
        let before = app.router.searchFocus.focusRequests

        app.router.focusSearch()
        #expect(app.router.path(.home).isEmpty)
        await ShellTestWait.until("the field focused after the pop", timeout: .seconds(3)) {
            app.router.searchFocus.focusRequests == before + 1
        }
        #expect(!app.router.searchFocus.isWaitingForTransition)
    }

    @Test("a new Home over the kept model starts with the field let go (replaying onboarding)")
    func newHomeLetsGoOfTheField() async throws {
        let app = AppContainer.preview()
        // The Home before the replay left its field focused; the model outlives it.
        app.home.setFieldFocused(true)
        #expect(app.home.isCompact)
        let host = try ShellTestWindow(RootView().shellEnvironment(app))
        defer { host.close() }
        await ShellTestWait.until("the main shell") { app.boot.phase == .main && app.router.acceptsNavigation }
        await ShellTestWait.until("the title lines back") { !app.home.isCompact }
    }

    // MARK: Re-taps

    @Test("the scroller finds the list it sits behind")
    func scrollerFindsItsList() async throws {
        let scroller = HomeListScroller()
        let host = try ShellTestWindow(
            NavigationStack {
                List { ForEach(0..<80, id: \.self) { Text(verbatim: "Row \($0)") } }
                    .homeListScroller(scroller)
            }
        )
        defer { host.close() }
        try await Task.sleep(for: .milliseconds(500))
        let anchor = try #require(scroller.anchor)
        #expect(anchor.window != nil)
        #expect(HomeListScroller.scrollView(near: anchor) != nil)
        let list = try #require(scroller.scrollView)
        #expect(!scroller.isScrolledDown)
        list.setContentOffset(CGPoint(x: 0, y: list.contentOffset.y + 500), animated: false)
        #expect(scroller.isScrolledDown)
        scroller.scrollToTop(animated: false)
        #expect(!scroller.isScrolledDown)
    }

    @Test("re-tapping a tab at its root scrolls its list back to the top", arguments: [AppTab.home, .spaces, .dropZone])
    func reTapScrollsToTop(tab: AppTab) async throws {
        let app = AppContainer.preview()
        let host = try ShellTestWindow(RootView().shellEnvironment(app))
        defer { host.close() }
        await ShellTestWait.until("the main shell") { app.boot.phase == .main && app.router.acceptsNavigation }
        // Enough rows to scroll on every tab.
        for index in 0..<30 {
            let space = try await app.repositories.spaces.create(CreateSpaceInput(name: "Room \(index)", icon: "📦", color: "#81B29A"))
            _ = try await app.repositories.items.create(ItemDraft(containerId: DropZone.containerId, name: "Thing in \(space.name)"))
        }
        app.database.invalidate()
        if tab != .home { app.router.selectTab(tab) }
        try await Task.sleep(for: .seconds(1))

        let list = try #require(HomeHostedSupport.largestScrollView(in: host.window))
        await ShellTestWait.until("a long list") { list.contentSize.height > list.bounds.height + 300 }
        let top = -list.adjustedContentInset.top
        list.setContentOffset(CGPoint(x: 0, y: top + 600), animated: false)
        try await Task.sleep(for: .milliseconds(200))

        #expect(list.contentOffset.y + list.adjustedContentInset.top > 100)

        app.router.selectTab(tab)
        // At the top as the bars stand now (the large title comes back as it gets there).
        await ShellTestWait.until("back at the top") { list.contentOffset.y + list.adjustedContentInset.top < 1 }
    }

    // MARK: Drop zone

    @Test("File… opens the move sheet (not a filing run) for a result; a filed item's row leaves at once")
    func dropZoneFiling() async throws {
        let app = AppContainer.preview()
        await app.boot.run()
        app.dropZone.focusChanged(true, revision: app.database.revision)
        await ShellTestWait.until("the drop zone") { !app.dropZone.items.isEmpty }
        let model = DropZoneScreen.makeModel(app: app)
        let item = try #require(model.rows.first)
        let count = model.rows.count

        let filing = Task { await model.file(item.id) }
        await ShellTestWait.until("the move sheet") { app.router.modals.count == 1 }
        guard case .sheet(.move(let itemId, let filingRun, let request))? = app.router.modals.last?.route else {
            Issue.record("expected the move sheet, got \(String(describing: app.router.modals.last?.route))")
            return
        }
        #expect(itemId == item.id)
        #expect(!filingRun)
        #expect(request != nil)

        // The move sheet moves the item, answers and closes itself, as MoveSheet does.
        let containers = try await app.repositories.containers.listAllWithSpace()
        let target = try #require(containers.first)
        let moved = try await app.repositories.items.update(item.id, UpdateItemInput(containerId: target.id))
        #expect(app.router.results.deliver(request, MoveResult(itemId: item.id, from: DropZone.containerId, to: target.id, updatedAt: moved?.updatedAt ?? 0)))
        if let modal = app.router.modals.last { app.router.close(modal.address) }
        await filing.value

        #expect(!model.rows.contains { $0.id == item.id })
        #expect(model.rows.count == count - 1)
    }

    @Test("closing the move sheet keeps the row")
    func dropZoneFilingClosed() async throws {
        let app = AppContainer.preview()
        await app.boot.run()
        app.dropZone.focusChanged(true, revision: app.database.revision)
        await ShellTestWait.until("the drop zone") { !app.dropZone.items.isEmpty }
        let model = DropZoneScreen.makeModel(app: app)
        let ids = model.rows.map(\.id)
        let item = try #require(model.rows.first)

        let filing = Task { await model.file(item.id) }
        await ShellTestWait.until("the move sheet") { app.router.modals.count == 1 }
        if let modal = app.router.modals.last { app.router.close(modal.address) }
        await filing.value
        #expect(model.rows.map(\.id) == ids)
    }

    // MARK: Reduce Motion

    @Test("a layout change animates over 180 ms, and happens at once under Reduce Motion (08 §8.3)")
    func layoutMotion() {
        #expect(HomeLayoutMotion.animation(reduceMotion: false) == .easeInOut(duration: 0.18))
        #expect(HomeLayoutMotion.animation(reduceMotion: true) == nil)
    }

    @Test("a scroll to the top without animation (Reduce Motion) gets there at once and stays")
    func scrollToTopWithoutAnimation() async throws {
        let scroller = HomeListScroller()
        let host = try ShellTestWindow(
            NavigationStack {
                List { ForEach(0..<80, id: \.self) { Text(verbatim: "Row \($0)") } }
                    .homeListScroller(scroller)
                    .navigationTitle("Title")
            }
        )
        defer { host.close() }
        try await Task.sleep(for: .milliseconds(500))
        let list = try #require(scroller.scrollView)
        list.setContentOffset(CGPoint(x: 0, y: list.contentOffset.y + 900), animated: false)
        try await Task.sleep(for: .milliseconds(200))
        scroller.scrollToTop(animated: false)
        #expect(!scroller.isScrolledDown)
        #expect(list.layer.animationKeys()?.isEmpty ?? true)
        // The settling passes (the large title coming back) never animate either.
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(100))
            #expect(list.layer.animationKeys()?.isEmpty ?? true)
        }
        #expect(!scroller.isScrolledDown)
    }

    @Test("RN's font scale per Dynamic Type size picks the drop zone's thumbnail")
    func fontScale() {
        #expect(DropZoneScreen.fontScale(.large) == 1)
        #expect(DropZoneScreen.fontScale(.xSmall) < 1)
        #expect(DropZoneScreen.fontScale(.xLarge) > 1)
        #expect(DropZoneScreenModel.thumbSize(windowWidth: 402, fontScale: DropZoneScreen.fontScale(.large), stacked: false) == 76)
        #expect(DropZoneScreenModel.thumbSize(windowWidth: 402, fontScale: DropZoneScreen.fontScale(.xLarge), stacked: false) == 56)
    }
}

/// A navigation stack with the probe at its root, driven by the test.
@MainActor
@Observable
final class HomeProbeHarnessState {
    var path: [Int]
    var waiting = false
    var ended = 0

    init(path: [Int]) {
        self.path = path
    }
}

private struct HomeProbeHarness: View {
    @Bindable var state: HomeProbeHarnessState

    var body: some View {
        NavigationStack(path: $state.path) {
            Color.clear
                .background {
                    HomeTransitionProbe(isWaiting: state.waiting) { state.ended += 1 }
                }
                .navigationDestination(for: Int.self) { value in
                    Text(verbatim: "\(value)")
                }
        }
    }
}

enum HomeHostedSupport {
    /// The largest scroll view shown in `window` (the selected tab's list).
    @MainActor
    static func largestScrollView(in window: UIWindow) -> UIScrollView? {
        window.shellDescendants
            .compactMap { $0 as? UIScrollView }
            .filter { !($0 is UITextView) && !$0.isHidden && $0.window != nil && isShown($0) }
            .max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    @MainActor
    private static func isShown(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let view = current {
            if view.isHidden || view.alpha < 0.01 { return false }
            current = view.superview
        }
        return true
    }
}

/// A clock whose sleeps outlast any test, so timeouts and fallbacks on it never fire.
struct HomeFrozenClock: Clock {
    typealias Instant = ContinuousClock.Instant

    var now: Instant { ContinuousClock.now }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try await Task.sleep(for: .seconds(3600))
    }
}
