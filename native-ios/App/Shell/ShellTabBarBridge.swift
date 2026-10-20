import SwiftUI
import UIKit
import InventoryAppModels

/// What SwiftUI's `TabView` cannot do, done on the `UITabBar` it hosts (06 §4.2-4.3):
/// - a 350 ms long press on Add opens Quick Snap (`longPress` haptic), recognised only when the
///   touch is on the Add item;
/// - every item carries RN's testID as its accessibility identifier;
/// - the Drop zone badge is yellow tape with dark text (U2);
/// - while the tab shell is in front, the bar's height is the toasts' bottom chrome
///   (``ShellTabBarChrome``).
///
/// (VoiceOver's labels, the Add hint and its "Quick Snap" action are on the tabs' SwiftUI labels
/// in ``MainShell``.) The bar is found from the window's view controllers and its item buttons by
/// position (five buttons, Add in the middle). No private API.
struct ShellTabBarBridge: UIViewRepresentable {
    let app: AppContainer
    let chrome: ShellTabBarChrome?
    let waiting: Int
    let shellFocused: Bool

    func makeCoordinator() -> ShellTabBarCoordinator {
        ShellTabBarCoordinator(app: app, chrome: chrome)
    }

    func makeUIView(context: Context) -> ShellTabBarProbe {
        let probe = ShellTabBarProbe()
        probe.coordinator = context.coordinator
        return probe
    }

    func updateUIView(_ probe: ShellTabBarProbe, context: Context) {
        context.coordinator.update(waiting: waiting, shellFocused: shellFocused)
        context.coordinator.attach(from: probe.window)
    }

    static func dismantleUIView(_ probe: ShellTabBarProbe, coordinator: ShellTabBarCoordinator) {
        coordinator.detach()
    }
}

/// A view in the tab view's background: it tells the coordinator when it lands in a window and
/// when the layout changes (rotation, size classes).
final class ShellTabBarProbe: UIView {
    weak var coordinator: ShellTabBarCoordinator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        coordinator?.attach(from: window)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        coordinator?.layoutChanged()
    }
}

@MainActor
final class ShellTabBarCoordinator: NSObject, UIGestureRecognizerDelegate {
    /// RN `delayLongPress`.
    static let longPressDuration: TimeInterval = 0.35
    /// Badge text on tape: the tape's ink in both appearances (08 §4).
    static let tapeInk = UIColor(red: 0x1D / 255, green: 0x1A / 255, blue: 0x0E / 255, alpha: 1)

    private let app: AppContainer
    private let chrome: ShellTabBarChrome?
    private weak var tabBar: UITabBar?
    private var longPress: UILongPressGestureRecognizer?
    private var waiting = 0
    private var shellFocused = true
    private var attachAttempts = 0
    /// The chrome height reported, so an unchanged bar never reports again (a report re-renders
    /// the toast host).
    private var registeredHeight: Double?
    private var lastBarFrame: CGRect = .null
    private var refreshScheduled = false

    init(app: AppContainer, chrome: ShellTabBarChrome?) {
        self.app = app
        self.chrome = chrome
    }

    func update(waiting: Int, shellFocused: Bool) {
        self.waiting = waiting
        self.shellFocused = shellFocused
        refresh()
        // SwiftUI may replace the bar's items later in the same update, dropping what was set on
        // them: tag them again once it is done.
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    /// The layout changed: only the chrome can have (rotation, size classes), and only when the
    /// bar itself moved.
    func layoutChanged() {
        guard let tabBar, let window = tabBar.window else { return }
        let frame = tabBar.convert(tabBar.bounds, to: window)
        guard frame != lastBarFrame else { return }
        lastBarFrame = frame
        updateChrome(tabBar)
    }

    /// Finds the tab bar in `window` and installs the long press, once. The tab bar controller may
    /// not exist yet on the first pass, so it tries again shortly a few times.
    func attach(from window: UIWindow?) {
        guard tabBar == nil, let window else { return }
        guard let controller = Self.tabBarController(in: window.rootViewController) else {
            guard attachAttempts < 20 else { return }
            attachAttempts += 1
            Task { @MainActor [weak self, weak window] in
                try? await Task.sleep(for: .milliseconds(100))
                self?.attach(from: window)
            }
            return
        }
        let tabBar = controller.tabBar
        self.tabBar = tabBar
        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        press.minimumPressDuration = Self.longPressDuration
        press.cancelsTouchesInView = true
        press.delegate = self
        tabBar.addGestureRecognizer(press)
        longPress = press
        applyBadgeAppearance(to: tabBar)
        refresh()
    }

    func detach() {
        if let longPress { longPress.view?.removeGestureRecognizer(longPress) }
        longPress = nil
        releaseChrome()
    }

    /// Re-applies the items' identifiers, the badge's colours and the toast chrome. Every property
    /// is set only when it differs: setting one makes the bar lay out again.
    func refresh() {
        guard let tabBar else { return }
        for (index, item) in (tabBar.items ?? []).enumerated() where AppTab.allCases.indices.contains(index) {
            let tab = AppTab.allCases[index]
            if item.accessibilityIdentifier != tab.accessibilityIdentifier { item.accessibilityIdentifier = tab.accessibilityIdentifier }
            if tab == .dropZone {
                let tape = UIColor(named: "Tape")
                if item.badgeColor != tape {
                    item.badgeColor = tape
                    item.setBadgeTextAttributes([.foregroundColor: Self.tapeInk], for: .normal)
                    item.setBadgeTextAttributes([.foregroundColor: Self.tapeInk], for: .selected)
                }
            }
        }
        updateChrome(tabBar)
    }

    // MARK: Long press

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            app.router.addLongPressed()
        case .ended, .cancelled, .failed:
            // The bar may still select Add when the finger lifts: that selection is ignored.
            app.router.addLongPressEnded()
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let tabBar else { return false }
        return Self.isOnAddItem(touch.location(in: tabBar), in: tabBar)
    }

    /// The bar's own recognizers (selection, the glass lens) wait for the long press to fail, so a
    /// long press on Add never also selects it. A tap ends the long press at once, so taps are not
    /// delayed; touches on the other items never reach the long press.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        guard let tabBar, let view = other.view else { return false }
        return view === tabBar || view.isDescendant(of: tabBar)
    }

    /// Whether `point` (in the bar's coordinates) is on the Add item.
    static func isOnAddItem(_ point: CGPoint, in tabBar: UITabBar) -> Bool {
        if let add = itemButtons(in: tabBar)[.add] {
            return add.convert(add.bounds, to: tabBar).contains(point)
        }
        // No button found: the middle fifth of the bar, where the third of five items sits.
        let slot = tabBar.bounds.width / 5
        return abs(point.x - tabBar.bounds.midX) <= slot / 2
    }

    // MARK: Finding things

    static func tabBarController(in controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children {
            if let found = tabBarController(in: child) { return found }
        }
        return nil
    }

    /// The bar's item buttons by tab: views labelled with a tab's title (or identified on an
    /// earlier pass); failing that, the bar's controls by position. iOS 26 draws each item button
    /// twice (once per glass layer) and leaves VoiceOver to the bar, so controls are taken by
    /// distinct frame: five frames in a row are the five items, in bar order.
    static func itemButtons(in tabBar: UITabBar) -> [AppTab: UIView] {
        var found: [AppTab: UIView] = [:]
        var controls: [UIView] = []
        func visit(_ view: UIView) {
            if let tab = tab(for: view) {
                if found[tab] == nil { found[tab] = view }
                return
            }
            if view is UIControl, !view.isHidden, view.alpha > 0 { controls.append(view) }
            view.subviews.forEach(visit)
        }
        tabBar.subviews.forEach(visit)
        guard found.isEmpty else { return found }
        var byFrame: [(frame: CGRect, view: UIView)] = []
        for control in controls {
            let frame = control.convert(control.bounds, to: tabBar).integral
            if !byFrame.contains(where: { $0.frame == frame }) { byFrame.append((frame, control)) }
        }
        guard byFrame.count == AppTab.allCases.count else { return found }
        let ordered = byFrame.sorted { $0.frame.midX < $1.frame.midX }
        let rightToLeft = tabBar.effectiveUserInterfaceLayoutDirection == .rightToLeft
        for (tab, entry) in zip(AppTab.allCases, rightToLeft ? ordered.reversed() : ordered) { found[tab] = entry.view }
        return found
    }

    private static func tab(for view: UIView) -> AppTab? {
        guard view.isAccessibilityElement else { return nil }
        if let identifier = view.accessibilityIdentifier, let tab = AppTab.allCases.first(where: { $0.accessibilityIdentifier == identifier }) {
            return tab
        }
        guard let label = view.accessibilityLabel else { return nil }
        return AppTab.allCases.first { $0.title == label || $0.accessibilityLabel() == label || label.hasPrefix("\($0.title),") }
    }

    // MARK: Badge and chrome

    /// Yellow tape for the Drop zone badge, keeping the system's (Liquid Glass) background.
    private func applyBadgeAppearance(to tabBar: UITabBar) {
        let tape = UIColor(named: "Tape")
        let appearance = tabBar.standardAppearance.copy()
        for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            for state in [layout.normal, layout.selected] {
                state.badgeBackgroundColor = tape
                state.badgeTextAttributes = [.foregroundColor: Self.tapeInk]
            }
        }
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
    }

    private func updateChrome(_ tabBar: UITabBar) {
        var height: Double?
        if shellFocused, let window = tabBar.window, !tabBar.isHidden {
            let top = tabBar.convert(tabBar.bounds, to: window).minY
            let measured = Double(window.bounds.height - top)
            if measured > 0 { height = measured }
        }
        guard height != registeredHeight else { return }
        registeredHeight = height
        chrome?.height = height
    }

    private func releaseChrome() {
        registeredHeight = nil
        chrome?.height = nil
    }
}

/// The tab bar's height while the tab shell is in front, for the toast's position.
///
/// Kept apart from `ToastCenter`'s chrome registrations, where the newest wins: with per-tab
/// stacks the bar stays on screen under a pushed screen whose bottom bar (measured from the
/// window's bottom, so taller) has registered, and a later report from the bar (it moved, it
/// came back from hiding) must not put the toast down over that bottom bar. The toast floats
/// above the taller of the two.
@MainActor
@Observable
final class ShellTabBarChrome {
    /// From the bar's top edge to the window's bottom edge; nil while the bar is hidden or
    /// something is presented over the tab shell.
    var height: Double?

    /// How far above the window's bottom edge the toast's chrome reaches: the taller of the
    /// focused screen's registered bar and the tab bar, nil when neither is there.
    static func toastChrome(registered: Double?, tabBar: Double?) -> Double? {
        switch (registered, tabBar) {
        case let (registered?, tabBar?): max(registered, tabBar)
        case let (registered?, nil): registered
        case let (nil, tabBar?): tabBar
        case (nil, nil): nil
        }
    }
}
