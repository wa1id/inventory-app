import SwiftUI
import UIKit

/// The tab roots' scrolling that SwiftUI's `List` does not offer reliably: whether the list is
/// scrolled away from its top, a scroll back to the very top (large title included, as a tap on
/// the status bar does), and the visible part of the list for revealing a row.
///
/// Attach ``HomeListScrollAnchor`` as the background of the list (or the scroll view in its
/// place); the scroller finds the screen's scroll view from there when asked. Keep one per
/// screen in `@State`.
@MainActor
final class HomeListScroller {
    fileprivate(set) weak var anchor: UIView?

    /// The list's scroll view, if it is on screen. Looked up at each use (a re-tap, a chip): the
    /// list and the state views that stand in for it replace each other.
    var scrollView: UIScrollView? {
        let attached = anchor.flatMap { $0.window == nil ? nil : $0 }
        return attached.flatMap(Self.scrollView(near:)) ?? Self.frontScrollView(in: attached?.window ?? Self.keyWindow)
    }

    /// The largest scroll view of the screen in front of the selected tab: the screen calling
    /// is in front (its re-tap, its chip), so that is its list.
    static func frontScrollView(in window: UIWindow?) -> UIScrollView? {
        guard let root = window?.rootViewController else { return nil }
        var controllers: [UIViewController] = [root]
        var tabs: UITabBarController?
        while !controllers.isEmpty {
            let controller = controllers.removeFirst()
            if let found = controller as? UITabBarController {
                tabs = found
                break
            }
            controllers += controller.children
        }
        guard var front = tabs?.selectedViewController else { return nil }
        while let navigation = front as? UINavigationController, let top = navigation.topViewController { front = top }
        guard let view = front.viewIfLoaded, view.window != nil else { return nil }
        var best: UIScrollView?
        var queue: [UIView] = [view]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            if current.isHidden || current.alpha < 0.01 { continue }
            if let scroll = current as? UIScrollView, !(scroll is UITextView),
               best.map({ $0.bounds.width * $0.bounds.height < scroll.bounds.width * scroll.bounds.height }) ?? true {
                best = scroll
            }
            queue += current.subviews
        }
        return best
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    /// Scrolled away from the top (RN `scrollY > 1`).
    var isScrolledDown: Bool {
        guard let scrollView else { return false }
        return scrollView.contentOffset.y + scrollView.adjustedContentInset.top > 1
    }

    /// Back to the top, the large title expanded again.
    func scrollToTop(animated: Bool) {
        guard let scrollView else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: -scrollView.adjustedContentInset.top), animated: animated)
        settleAtTop(scrollView, passes: 3, after: animated ? 0.45 : 0.05, animated: animated)
    }

    /// The large title comes back on the way up, which moves the top (the bar's inset grows):
    /// once the scroll has ended, go the rest of the way, animated only as the scroll was (never
    /// under Reduce Motion). Never while she is touching the list.
    private func settleAtTop(_ scrollView: UIScrollView, passes: Int, after delay: TimeInterval, animated: Bool) {
        guard passes > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak scrollView] in
            guard let self, let scrollView, scrollView.window != nil,
                  !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating else { return }
            let top = -scrollView.adjustedContentInset.top
            guard scrollView.contentOffset.y - top > 1 else { return }
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: top), animated: animated)
            self.settleAtTop(scrollView, passes: passes - 1, after: animated ? 0.45 : 0.15, animated: animated)
        }
    }

    /// The part of the list not under the bars, in window coordinates.
    var visibleRect: CGRect? {
        guard let scrollView, scrollView.window != nil else { return nil }
        let frame = scrollView.convert(scrollView.bounds, to: nil)
        return frame.inset(by: scrollView.adjustedContentInset)
    }

    /// Scrolls just enough for `rect` (in window coordinates) to be entirely on screen, with
    /// `margin` below it (RN `revealExpanded`: the row's bottom plus `space.md`). Does nothing
    /// when it already is.
    func reveal(_ rect: CGRect, margin: CGFloat, animated: Bool) {
        guard let scrollView, let visible = visibleRect else { return }
        var delta: CGFloat = 0
        if rect.maxY + margin > visible.maxY {
            delta = rect.maxY + margin - visible.maxY
        } else if rect.minY < visible.minY {
            delta = rect.minY - visible.minY
        }
        guard abs(delta) > 0.5 else { return }
        let top = -scrollView.adjustedContentInset.top
        let bottom = max(top, scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height)
        let target = min(max(scrollView.contentOffset.y + delta, top), bottom)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: target), animated: animated)
    }

    /// The scroll view the anchor sits behind: the nearest one, going up from `view` one
    /// ancestor at a time, whose frame holds the anchor's centre. Other tabs' lists may cover the
    /// same part of the window, but they sit under a farther ancestor.
    static func scrollView(near view: UIView) -> UIScrollView? {
        guard view.window != nil else { return nil }
        let centre = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        var ancestor: UIView? = view.superview
        while let current = ancestor {
            if let found = scrollView(in: current, holding: centre) { return found }
            ancestor = current.superview
        }
        return nil
    }

    /// The first scroll view in `root`'s subtree, breadth first, that is shown and holds `point`.
    private static func scrollView(in root: UIView, holding point: CGPoint) -> UIScrollView? {
        var queue: [UIView] = [root]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            if current.isHidden || current.alpha < 0.01 { continue }
            if let scroll = current as? UIScrollView, !(scroll is UITextView), scroll.window != nil,
               scroll.convert(scroll.bounds, to: nil).contains(point) {
                return scroll
            }
            queue += current.subviews
        }
        return nil
    }
}

/// Where ``HomeListScroller`` starts looking for the list: a zero-size view behind it.
struct HomeListScrollAnchor: UIViewRepresentable {
    let scroller: HomeListScroller

    func makeUIView(context: Context) -> HomeListScrollAnchorView {
        let view = HomeListScrollAnchorView()
        view.scroller = scroller
        return view
    }

    func updateUIView(_ view: HomeListScrollAnchorView, context: Context) {
        view.scroller = scroller
        if view.window != nil { scroller.anchor = view }
    }
}

/// The anchor's view. It becomes the scroller's anchor when it lands in a window, so a list
/// replacing a state view (or the other way round) hands over, whatever order SwiftUI makes
/// and removes them in.
final class HomeListScrollAnchorView: UIView {
    weak var scroller: HomeListScroller?

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
        if window != nil { scroller?.anchor = self }
    }
}

extension View {
    /// Lets `scroller` find this list's scroll view.
    func homeListScroller(_ scroller: HomeListScroller) -> some View {
        background {
            HomeListScrollAnchor(scroller: scroller)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}
