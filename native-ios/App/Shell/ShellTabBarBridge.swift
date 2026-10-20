import SwiftUI
import UIKit
import InventoryAppModels
import InventoryStrings

/// What SwiftUI's `TabView` cannot do, done on the tab bar UIKit builds for it (06 §4.2-4.3,
/// DECISIONS U4, U5). The same `TabView` shows three bars: the bottom `UITabBar` on an iPhone (and
/// on an iPad in a compact window), and on an iPad the floating tab bar at the top or the
/// sidebar. On each of them:
/// - a 350 ms long press on Add opens Quick Snap (`longPress` haptic), recognised only when the
///   touch is on the Add item, and the bar's own selection waits for it to fail, so a long press
///   never also opens the Add sheet;
/// - the Drop zone badge is yellow tape with ink text (U2: waiting is not an alarm): the
///   `UITabBar` takes it from its item and appearance, while the floating bar's red badge and the
///   sidebar's grey count are recoloured where they are drawn;
/// - the Add item carries RN's "Quick Snap" custom action and long-press hint for VoiceOver;
/// - every `UITabBar` item carries RN's testID as its accessibility identifier (the floating bar
///   and the sidebar read it from the same items);
/// - while the tab shell is in front, the bottom bar's height is the toasts' bottom chrome
///   (``ShellTabBarChrome``); the floating bar and the sidebar leave the bottom edge free.
///
/// (VoiceOver's labels, the Add hint and its "Quick Snap" action are also on the tabs' SwiftUI
/// labels in ``MainShell``.) Items are found by their visible titles (`AppTab.title`) inside the
/// tab bar controller's own chrome, never the content; no private API is called.
struct ShellTabBarBridge: UIViewRepresentable {
    let app: AppContainer
    let chrome: ShellTabBarChrome?
    let waiting: Int
    let shellFocused: Bool
    /// Whether an iPad's top bar and sidebar draw dark (over the Scan tab's camera).
    var darkChrome = false

    func makeCoordinator() -> ShellTabBarCoordinator {
        ShellTabBarCoordinator(app: app, chrome: chrome)
    }

    func makeUIView(context: Context) -> ShellTabBarProbe {
        let probe = ShellTabBarProbe()
        probe.coordinator = context.coordinator
        return probe
    }

    func updateUIView(_ probe: ShellTabBarProbe, context: Context) {
        context.coordinator.update(waiting: waiting, shellFocused: shellFocused, darkChrome: darkChrome)
        context.coordinator.attach(from: probe.window)
    }

    static func dismantleUIView(_ probe: ShellTabBarProbe, coordinator: ShellTabBarCoordinator) {
        coordinator.detach()
    }
}

/// A view in the tab view's background: it tells the coordinator when it lands in a window, when
/// the layout changes (rotation, size classes, the window resized) and when the appearance
/// changes.
final class ShellTabBarProbe: UIView {
    weak var coordinator: ShellTabBarCoordinator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self]) { (probe: ShellTabBarProbe, _) in
            probe.coordinator?.layoutChanged()
        }
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
    /// The badge: tape with the tape's ink in both appearances (08 §4, U2).
    static let tape = UIColor(resource: .tape)
    static let tapeInk = UIColor(resource: .tapeInk)

    private let app: AppContainer
    private let chrome: ShellTabBarChrome?
    private(set) weak var controller: UITabBarController?
    private var longPress: UILongPressGestureRecognizer?
    private var touchWatcher: ShellTouchWatcher?
    private var sidebarObservation: NSKeyValueObservation?
    private var waiting = 0
    private var shellFocused = true
    private var darkChrome = false
    /// The chrome views drawn dark, to give back to the system's style afterwards.
    private let darkenedViews = NSHashTable<UIView>.weakObjects()
    private var attachAttempts = 0
    /// The chrome height reported, so an unchanged bar never reports again (a report re-renders
    /// the toast host).
    private var registeredHeight: Double?
    private var refreshScheduled = false
    private var settleRefresh: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var keyboardObservers: [NSObjectProtocol] = []

    init(app: AppContainer, chrome: ShellTabBarChrome?) {
        self.app = app
        self.chrome = chrome
    }

    var tabBar: UITabBar? { controller?.tabBar }

    func update(waiting: Int, shellFocused: Bool, darkChrome: Bool = false) {
        let countChanged = waiting != self.waiting || darkChrome != self.darkChrome
        self.waiting = waiting
        self.shellFocused = shellFocused
        self.darkChrome = darkChrome
        // The floating bar and the sidebar redraw a new count a moment later, in their colours.
        if countChanged { layoutChanged() } else { refresh() }
        // SwiftUI may replace the bar's items later in the same update, dropping what was set on
        // them: tag them again once it is done.
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    /// The layout or the appearance changed (rotation, size classes, the sidebar shown or
    /// hidden, a touch on a bar): refresh now and every 100 ms while the bars settle, since the
    /// floating bar and the sidebar rebuild their items during their own animations (the
    /// sidebar's rows can appear a second after it starts to open).
    func layoutChanged() {
        refresh()
        settleRefresh?.cancel()
        settleRefresh = Task { @MainActor [weak self] in
            for _ in 0..<Self.settleRefreshes {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    /// How many refreshes follow a change, 100 ms apart.
    private static let settleRefreshes = 15

    /// Finds the tab bar controller in `window` and installs the long press, once. The controller
    /// may not exist yet on the first pass, so it tries again shortly a few times.
    func attach(from window: UIWindow?) {
        guard controller == nil, let window else { return }
        guard let found = Self.tabBarController(in: window.rootViewController) else {
            guard attachAttempts < 20 else { return }
            attachAttempts += 1
            Task { @MainActor [weak self, weak window] in
                try? await Task.sleep(for: .milliseconds(100))
                self?.attach(from: window)
            }
            return
        }
        controller = found
        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        press.minimumPressDuration = Self.longPressDuration
        press.cancelsTouchesInView = true
        press.delegate = self
        found.view.addGestureRecognizer(press)
        longPress = press
        // The bars rebuild their items after a touch (a selection, the sidebar's button or swipe):
        // style them again once they have settled.
        let watcher = ShellTouchWatcher { [weak self] touched in
            guard let self, let touched, let controller = self.controller else { return }
            if Self.tabChromeViews(in: controller).contains(where: { touched.isDescendant(of: $0) }) { self.layoutChanged() }
        }
        found.view.addGestureRecognizer(watcher)
        touchWatcher = watcher
        applyBadgeAppearance(to: found.tabBar)
        // The sidebar shown or hidden (its button, a rotation) builds its rows afresh.
        sidebarObservation = found.sidebar.observe(\.isHidden, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.layoutChanged() }
        }
        // The keyboard coming or going (a sheet's field, a rotation under it) lays the sidebar out
        // again, which rebuilds its rows.
        keyboardObservers = [UIResponder.keyboardDidShowNotification, UIResponder.keyboardDidHideNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutChanged() }
            }
        }
        // Whatever else makes the top bar or the sidebar rebuild its items: style them again
        // within a second. A pass that finds everything styled changes nothing.
        heartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if self.controller?.traitCollection.horizontalSizeClass == .regular { self.refresh() }
            }
        }
        // The bars are still building their items (an iPad opening on the sidebar).
        layoutChanged()
    }

    func detach() {
        if let longPress { longPress.view?.removeGestureRecognizer(longPress) }
        longPress = nil
        if let touchWatcher { touchWatcher.view?.removeGestureRecognizer(touchWatcher) }
        touchWatcher = nil
        sidebarObservation?.invalidate()
        sidebarObservation = nil
        settleRefresh?.cancel()
        heartbeat?.cancel()
        heartbeat = nil
        for observer in keyboardObservers { NotificationCenter.default.removeObserver(observer) }
        keyboardObservers = []
        releaseChrome()
    }

    /// Re-applies the items' identifiers, the badge's colours, the Add item's accessibility and
    /// the toast chrome. Every property is set only when it differs: setting one makes the bar lay
    /// out again.
    func refresh() {
        guard let controller else { return }
        let tabBar = controller.tabBar
        for (index, item) in (tabBar.items ?? []).enumerated() where AppTab.allCases.indices.contains(index) {
            let tab = AppTab.allCases[index]
            if item.accessibilityIdentifier != tab.accessibilityIdentifier { item.accessibilityIdentifier = tab.accessibilityIdentifier }
            switch tab {
            case .dropZone:
                if item.badgeColor != Self.tape {
                    item.badgeColor = Self.tape
                    item.setBadgeTextAttributes([.foregroundColor: Self.tapeInk], for: .normal)
                    item.setBadgeTextAttributes([.foregroundColor: Self.tapeInk], for: .selected)
                }
            case .add:
                applyAddAccessibility(to: item)
            default:
                break
            }
        }
        let chromeViews = Self.tabChromeViews(in: controller)
        let badge = AppTab.badgeText(waiting: waiting)
        let dropZoneLabel = AppTab.dropZone.accessibilityLabel(waiting: waiting)
        for view in chromeViews {
            for item in Self.itemViews(titled: AppTab.dropZone.title, in: view) {
                if let badge { ShellTapeBadge.style(item: item, badgeText: badge) }
                // The sidebar adds the bare count to the row's label ("Drop zone, 4 waiting,
                // 4"): VoiceOver reads RN's label alone, on every bar.
                if item.accessibilityLabel != dropZoneLabel {
                    item.accessibilityLabel = dropZoneLabel
                    item.accessibilityLabelBlock = { dropZoneLabel }
                }
            }
        }
        for view in chromeViews {
            for item in Self.itemViews(titled: AppTab.add.title, in: view) {
                applyAddAccessibility(to: item)
            }
        }
        applyChromeStyle(chromeViews, regular: controller.traitCollection.horizontalSizeClass == .regular)
        updateChrome(tabBar)
    }

    /// Over the Scan tab's camera the floating bar's glass turns dark by itself, but the selected
    /// item keeps the light appearance's ink and vanishes: the top bar and the sidebar take the
    /// dark appearance and its ink there. The bottom bar (an iPhone, a narrow window) keeps its
    /// own look.
    private func applyChromeStyle(_ views: [UIView], regular: Bool) {
        if darkChrome, regular {
            for view in views where view.overrideUserInterfaceStyle != .dark {
                darkenedViews.add(view)
                view.overrideUserInterfaceStyle = .dark
                view.tintColor = Self.darkInk
            }
        } else if darkenedViews.count > 0 {
            for view in darkenedViews.allObjects {
                view.overrideUserInterfaceStyle = .unspecified
                view.tintColor = nil
            }
            darkenedViews.removeAllObjects()
        }
    }

    /// The accent (ink) as the dark appearance draws it.
    static let darkInk = UIColor(named: "AccentColor")?.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)) ?? .white

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
        guard let controller else { return false }
        return Self.addItemFrames(in: controller).contains { $0.contains(touch.location(in: controller.view)) }
    }

    /// The bars' own recognizers (selection, the glass lens, the sidebar's list) wait for the long
    /// press to fail, so a long press on Add never also selects it. A tap ends the long press at
    /// once, so taps are not delayed; touches elsewhere never reach the long press.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        guard let controller, let view = other.view else { return false }
        return Self.tabChromeViews(in: controller).contains { view === $0 || view.isDescendant(of: $0) }
    }

    /// Whether `point` (in the bar's coordinates) is on the bottom bar's Add item.
    static func isOnAddItem(_ point: CGPoint, in tabBar: UITabBar) -> Bool {
        if let add = itemButtons(in: tabBar)[.add] {
            return add.convert(add.bounds, to: tabBar).contains(point)
        }
        // No button found: the middle fifth of the bar, where the third of five items sits.
        let slot = tabBar.bounds.width / 5
        return abs(point.x - tabBar.bounds.midX) <= slot / 2
    }

    /// Where the Add item is on screen now, in the controller view's coordinates: the bottom bar's
    /// button, the floating bar's item or the sidebar's row, whichever shows.
    static func addItemFrames(in controller: UITabBarController) -> [CGRect] {
        let root = controller.view
        var frames: [CGRect] = []
        for view in tabChromeViews(in: controller) {
            for item in itemViews(titled: AppTab.add.title, in: view) where isShowing(item) {
                frames.append(item.convert(item.bounds, to: root))
            }
        }
        let tabBar = controller.tabBar
        if frames.isEmpty, tabBar.window != nil, isShowing(tabBar) {
            if let add = itemButtons(in: tabBar)[.add] {
                frames.append(add.convert(add.bounds, to: root))
            } else {
                let slot = tabBar.bounds.width / 5
                frames.append(tabBar.convert(CGRect(x: tabBar.bounds.midX - slot / 2, y: 0, width: slot, height: tabBar.bounds.height), to: root))
            }
        }
        return frames
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

    /// The tab bar controller's own views around the content: the bottom bar's container, the
    /// floating bar's and the sidebar's. Everything in its view but the selected tab's content.
    static func tabChromeViews(in controller: UITabBarController) -> [UIView] {
        // Until the content exists it cannot be told apart, and there is nothing to find yet.
        guard let content = controller.selectedViewController?.viewIfLoaded else { return [] }
        return controller.view.subviews.filter { subview in
            !(content === subview || content.isDescendant(of: subview))
        }
    }

    /// The item views in `root` whose title is `title`: for each label showing it, the nearest
    /// enclosing collection view cell (the floating bar's items, the sidebar's rows) or control
    /// (the bottom bar's buttons).
    static func itemViews(titled title: String, in root: UIView) -> [UIView] {
        var items: [UIView] = []
        func visit(_ view: UIView) {
            if let label = view as? UILabel, label.text == title, let item = itemContainer(of: label, below: root) {
                if !items.contains(where: { $0 === item }) { items.append(item) }
                return
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return items
    }

    private static func itemContainer(of label: UILabel, below root: UIView) -> UIView? {
        var current: UIView? = label.superview
        while let view = current, view !== root {
            if view is UICollectionViewCell || view is UIControl { return view }
            current = view.superview
        }
        return nil
    }

    /// Whether `view` is on screen: in a window, with no hidden or transparent ancestor.
    static func isShowing(_ view: UIView) -> Bool {
        guard view.window != nil else { return false }
        var current: UIView? = view
        while let candidate = current {
            if candidate.isHidden || candidate.alpha < 0.01 { return false }
            current = candidate.superview
        }
        return true
    }

    /// The bottom bar's item buttons by tab: views labelled with a tab's title (or identified on
    /// an earlier pass); failing that, the bar's controls by position. iOS 26 draws each item
    /// button twice (once per glass layer) and leaves VoiceOver to the bar, so controls are taken
    /// by distinct frame: five frames in a row are the five items, in bar order.
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

    // MARK: Accessibility

    /// RN TabBar.tsx:183-189: the long press's hint and "Quick Snap" as a custom action, on the
    /// Add item whichever bar draws it.
    private func applyAddAccessibility(to target: NSObject) {
        if target.accessibilityHint != L10n.Tabs.addHint { target.accessibilityHint = L10n.Tabs.addHint }
        let name = L10n.Tabs.quickSnapAction
        guard target.accessibilityCustomActions?.map(\.name) != [name] else { return }
        let router = app.router
        target.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: name) { _ in
                MainActor.assumeIsolated { router.addLongPressed() }
                return true
            },
        ]
    }

    // MARK: Badge and chrome

    /// Yellow tape for the bottom bar's Drop zone badge, keeping the system's (Liquid Glass)
    /// background.
    private func applyBadgeAppearance(to tabBar: UITabBar) {
        let appearance = tabBar.standardAppearance.copy()
        for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            for state in [layout.normal, layout.selected] {
                state.badgeBackgroundColor = Self.tape
                state.badgeTextAttributes = [.foregroundColor: Self.tapeInk]
            }
        }
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
    }

    private func updateChrome(_ tabBar: UITabBar) {
        var height: Double?
        if shellFocused, let window = tabBar.window, Self.isShowing(tabBar) {
            let frame = tabBar.convert(tabBar.bounds, to: window)
            let measured = Double(window.bounds.height - frame.minY)
            // Only a bar along the bottom edge lifts the toast.
            if measured > 0, frame.maxY >= window.bounds.height - 1 { height = measured }
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

/// Notices every touch on the tab bar controller's view and reports the view it landed on when
/// it ends, without ever recognising, delaying or cancelling anything: the bars rebuild their
/// items after a touch.
final class ShellTouchWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let touchEnded: @MainActor (UIView?) -> Void

    init(touchEnded: @escaping @MainActor (UIView?) -> Void) {
        self.touchEnded = touchEnded
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        state = .failed
        touchEnded(touches.first?.view)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        state = .failed
        touchEnded(touches.first?.view)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        false
    }
}

/// The Drop zone badge drawn as yellow tape where the floating tab bar and the sidebar draw it
/// themselves: the floating bar's round red badge takes the tape colour, and the sidebar's grey
/// count gets a tape capsule behind it; the number is the tape's ink in both.
enum ShellTapeBadge {
    /// Styles the badge showing `badgeText` inside `item` (a floating bar item or a sidebar row).
    @MainActor
    static func style(item: UIView, badgeText: String) {
        for label in labels(in: item) where label.text == badgeText {
            guard let badge = label.superview, badge !== item else { continue }
            if label.textColor != ShellTabBarCoordinator.tapeInk { label.textColor = ShellTabBarCoordinator.tapeInk }
            if let fill = badge.backgroundColor, fill.cgColor.alpha > 0.01, !(badge is ShellTapeBadgeBackdrop) {
                // The floating bar's own capsule.
                if fill != ShellTabBarCoordinator.tape { badge.backgroundColor = ShellTabBarCoordinator.tape }
            } else {
                if !badge.subviews.contains(where: { $0 is ShellTapeBadgeBackdrop }) {
                    // The sidebar's bare count: a capsule behind it that follows its size.
                    let backdrop = ShellTapeBadgeBackdrop(frame: badge.bounds.insetBy(dx: -ShellTapeBadgeBackdrop.padding, dy: 0))
                    backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    badge.insertSubview(backdrop, at: 0)
                    badge.clipsToBounds = false
                }
                // The row's label already says "4 waiting" (RN); the bare count is not read again.
                if !badge.accessibilityElementsHidden { badge.accessibilityElementsHidden = true }
            }
        }
    }

    @MainActor
    static func labels(in view: UIView) -> [UILabel] {
        view.subviews.flatMap { subview -> [UILabel] in
            (subview as? UILabel).map { [$0] } ?? labels(in: subview)
        }
    }
}

/// The tape capsule behind the sidebar's Drop zone count.
final class ShellTapeBadgeBackdrop: UIView {
    /// How far the capsule reaches beyond the number on each side.
    static let padding: CGFloat = 7

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = ShellTabBarCoordinator.tape
        layer.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.height / 2, 6)
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
    /// From the bar's top edge to the window's bottom edge; nil while the bar is hidden, sits
    /// elsewhere (the iPad's floating bar and sidebar), or something is presented over the tab
    /// shell.
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
