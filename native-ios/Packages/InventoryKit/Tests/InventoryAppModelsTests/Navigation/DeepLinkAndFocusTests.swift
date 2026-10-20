import Foundation
import InventoryCore
import Testing
@testable import InventoryAppModels

// Deep links (06 §3.6, DECISIONS U5), queueing until the main shell shows, and the focus rules
// (09 §5, 00-index §5). Names carry the Navigation prefix.

@Suite("Deep links")
struct NavigationDeepLinkParsingTests {
    @Test("parses the QR label link in both schemes and both forms", arguments: [
        ("inventory://c/0123456789abcdef0123456789abcdef", "0123456789abcdef0123456789abcdef"),
        ("com.wystudio.inventory://c/0123456789abcdef0123456789abcdef", "0123456789abcdef0123456789abcdef"),
        ("inventory:///c/abc", "abc"),
        ("com.wystudio.inventory:///c/abc", "abc"),
        ("INVENTORY://c/abc", "abc"),
        ("inventory://C/abc", "abc"),
        ("inventory://c/abc/", "abc"),
        // Percent-decoded, then trimmed as RN tokenParam does.
        ("inventory://c/%20abc%20", "abc"),
        ("inventory://c/ABCDEF", "ABCDEF"),
        // A repeated parameter: the path's comes first and wins.
        ("inventory://c/abc?token=def", "abc"),
        ("inventory:///c/abc?token=def&token=ghi", "abc"),
        // Blank still opens the label screen, which says it is not one of ours (RN routed it too).
        ("inventory://c/%20%20", ""),
    ])
    func parses(url: String, token: String) throws {
        let link = DeepLink(url: try #require(URL(string: url)))
        #expect(link == .label(token: token))
    }

    @Test("ignores every other link", arguments: [
        "inventory://c/",
        "inventory://c",
        "inventory:///c",
        "inventory:///c/",
        "inventory://c/abc/extra",
        "inventory:///c/abc/extra",
        "inventory://item/abc",
        "inventory:///item/abc",
        "inventory:///?q=drill",
        "inventory://",
        "https://c/abc",
        "https://inventory.wystudio.be/c/abc",
        "exp://c/abc",
    ])
    func ignores(url: String) throws {
        #expect(DeepLink(url: try #require(URL(string: url))) == nil)
    }
}

@Suite("Router › external requests")
@MainActor
struct NavigationExternalRequestTests {
    @Test("a cold-start deep link waits for the main shell, then opens the label on Home with Home underneath")
    func coldStart() throws {
        let router = Router()
        #expect(router.open(try #require(URL(string: "inventory://c/abc"))))
        #expect(router.pendingExternalRequest == .deepLink(.label(token: "abc")))
        #expect(router.path(.home).isEmpty)

        router.setAcceptsNavigation(true)
        #expect(router.pendingExternalRequest == nil)
        #expect(router.selectedTab == .home)
        #expect(router.path(.home).map(\.route) == [.label(token: "abc")])
        #expect(router.isFocused(router.path(.home)[0].address))
        #expect(!router.isFocused(.tabRoot(.home)))
    }

    @Test("a link that arrives while onboarding is pending is delivered once onboarding completes, newest first")
    func duringOnboarding() throws {
        let router = Router()
        router.setAcceptsNavigation(false)
        router.open(try #require(URL(string: "inventory://c/old")))
        router.open(try #require(URL(string: "inventory://c/new")))
        #expect(router.modals.isEmpty)
        router.setAcceptsNavigation(true)
        #expect(router.path(.home).map(\.route) == [.label(token: "new")])
    }

    @Test("an unknown link is refused and nothing waits")
    func unknown() throws {
        let router = Router()
        #expect(!router.open(try #require(URL(string: "inventory://item/abc"))))
        #expect(router.pendingExternalRequest == nil)
    }

    @Test("a warm link closes what is presented and opens the label on the current tab")
    func warm() throws {
        let router = Router()
        router.setAcceptsNavigation(true)
        router.selectTab(.spaces)
        router.push(.space(id: "s1"))
        router.present(.sheet(.addItem(AddParams())))
        router.open(try #require(URL(string: "inventory://c/abc")))
        #expect(router.modals.isEmpty)
        #expect(router.path(.spaces).map(\.route) == [.space(id: "s1"), .label(token: "abc")])
    }

    @Test("the Quick Snap quick action waits like a link, then opens the camera over a cleared stack")
    func quickAction() {
        let router = Router()
        #expect(router.performQuickAction(type: AppQuickAction.quickSnap.rawValue))
        #expect(!router.performQuickAction(type: "com.example.unknown"))
        #expect(router.pendingExternalRequest == .quickAction(.quickSnap))
        router.setAcceptsNavigation(true)
        #expect(router.modals.map(\.route) == [.cover(.capture(.quickSnap, request: nil))])

        router.present(.sheet(.addItem(AddParams())))
        router.performQuickAction(type: AppQuickAction.quickSnap.rawValue)
        #expect(router.modals.map(\.route) == [.cover(.capture(.quickSnap, request: nil))])
    }

    @Test("leaving the main shell (How it works) resets navigation to a fresh Home")
    func replayResets() {
        let router = Router()
        router.setAcceptsNavigation(true)
        router.selectTab(.spaces)
        router.push(.space(id: "s1"))
        router.present(.sheet(.spaceEdit(id: "s1")))
        router.setAcceptsNavigation(false)
        #expect(router.state == RouterState())
    }
}

@Suite("Router › focus rules")
struct NavigationFocusTests {
    private static let a = PushEntry(id: 1, route: .settings)
    private static let b = PushEntry(id: 2, route: .household)
    private static let s = PushEntry(id: 3, route: .space(id: "s1"))
    private static let sheet = ModalEntry(id: 10, screenID: 11, route: .sheet(.addItem(AddParams())))
    private static let cover = ModalEntry(
        id: 20, screenID: 21, route: .cover(.capture(.quickSnap, request: nil)),
        path: [PushEntry(id: 22, route: .quickSnapReview(QuickSnapReviewRoute(containerId: "drop-zone", since: 0, expected: 1)))])

    typealias FocusCase = (state: RouterState, position: ScreenPosition, focused: Bool)

    static let cases: [FocusCase] = [
        // Nothing pushed or presented: only the selected tab's root.
        (state: RouterState(), position: ScreenPosition.tabRoot(.home), focused: true),
        (state: RouterState(), position: .tabRoot(.spaces), focused: false),
        (state: RouterState(selectedTab: .spaces), position: .tabRoot(.spaces), focused: true),
        // A push covers the root; only the top of the stack is focused.
        (state: RouterState(paths: [.home: [a, b]]), position: .tabRoot(.home), focused: false),
        (state: RouterState(paths: [.home: [a, b]]), position: .tabPush(.home, index: 0), focused: false),
        (state: RouterState(paths: [.home: [a, b]]), position: .tabPush(.home, index: 1), focused: true),
        (state: RouterState(paths: [.home: [a, b]]), position: .tabPush(.home, index: 2), focused: false),
        // Another tab's stack is not focused, even its top.
        (state: RouterState(paths: [.spaces: [s]]), position: .tabPush(.spaces, index: 0), focused: false),
        (state: RouterState(paths: [.spaces: [s]]), position: .tabRoot(.home), focused: true),
        // A sheet unfocuses everything under it.
        (state: RouterState(modals: [sheet]), position: .tabRoot(.home), focused: false),
        (state: RouterState(paths: [.home: [a]], modals: [sheet]), position: .tabPush(.home, index: 0), focused: false),
        (state: RouterState(modals: [sheet]), position: .modalRoot(level: 0), focused: true),
        // A cover over the sheet; the review pushed inside the cover is the one in front.
        (state: RouterState(modals: [sheet, cover]), position: .modalRoot(level: 0), focused: false),
        (state: RouterState(modals: [sheet, cover]), position: .modalRoot(level: 1), focused: false),
        (state: RouterState(modals: [sheet, cover]), position: .modalPush(level: 1, index: 0), focused: true),
        (state: RouterState(modals: [sheet, cover]), position: .modalPush(level: 0, index: 0), focused: false),
        (state: RouterState(modals: [sheet]), position: .modalRoot(level: 1), focused: false),
        ]

    @Test("the table of positions", arguments: cases)
    func table(state: RouterState, position: ScreenPosition, focused: Bool) {
        #expect(state.isFocused(position) == focused)
    }

    @Test("addresses resolve to positions; the front screen is the only focused one")
    func addresses() {
        let state = RouterState(paths: [.home: [Self.a], .spaces: [Self.s]], modals: [Self.sheet, Self.cover])
        #expect(state.position(of: Self.a.address) == .tabPush(.home, index: 0))
        #expect(state.position(of: Self.s.address) == .tabPush(.spaces, index: 0))
        #expect(state.position(of: Self.sheet.address) == .modalRoot(level: 0))
        #expect(state.position(of: .push(22)) == .modalPush(level: 1, index: 0))
        #expect(state.position(of: .push(99)) == nil)
        #expect(state.position(of: .tabRoot(.add)) == nil)
        #expect(state.frontAddress == .push(22))
        let focused = state.orderedAddresses.filter(state.isFocused)
        #expect(focused == [.push(22)])
        #expect(state.modalLevel(containing: .push(22)) == 1)
        #expect(state.modalLevel(containing: Self.a.address) == nil)
    }

    @Test("the tab shell counts as in front whenever nothing is presented")
    func tabShell() {
        #expect(RouterState().isTabShellFocused)
        #expect(RouterState(paths: [.home: [Self.a]]).isTabShellFocused)
        #expect(!RouterState(modals: [Self.sheet]).isTabShellFocused)
    }

    @Test("canDismiss is RN's: something pushed on the selected tab or presented")
    func canDismiss() {
        #expect(!RouterState().canDismiss)
        #expect(!RouterState(paths: [.spaces: [Self.s]]).canDismiss)
        #expect(RouterState(paths: [.home: [Self.a]]).canDismiss)
        #expect(RouterState(modals: [Self.sheet]).canDismiss)
    }

    @Test("the router reports focus from its state")
    @MainActor
    func router() {
        let router = Router()
        #expect(router.isFocused(.tabRoot(.home)))
        let settings = router.push(.settings)
        #expect(router.isFocused(settings.address))
        #expect(router.isTabShellFocused)
        let sheet = router.present(.sheet(.spaceNew(request: nil)))
        #expect(!router.isFocused(settings.address))
        #expect(router.isFocused(sheet.address))
        #expect(!router.isTabShellFocused)
    }
}
