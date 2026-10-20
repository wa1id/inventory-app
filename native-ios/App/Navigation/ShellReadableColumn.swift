import SwiftUI
import UIKit

/// The readable column of a navigation stack on iPad (U4: content at most 640 pt wide, centred).
///
/// A stack wider than the column pads each screen's safe area on both sides
/// (`.readableColumnContent()`), so rows and forms sit in the column while the scroll view, the
/// backgrounds and the scroll edge effect still span the window (a list scrolls and refreshes
/// from anywhere, as with UIKit's readable content guide). The navigation bar's large title and
/// search field move onto the same column through the bar's layout margins (``ShellStackProbe``);
/// its buttons stay at the window's edges, where iPadOS puts them beside the floating tab bar
/// (pulled into the column they no longer fit there and fold into a "More" menu). A stack no
/// wider than the column (every iPhone, an iPad app in a narrow window or Split View) gets
/// nothing.
@MainActor
@Observable
final class ShellReadableColumn {
    /// The padding on each side of the stack.
    var inset: CGFloat = 0

    /// The padding on each side that leaves `DesignMetrics.contentMaxWidth` in the middle of a
    /// stack `width` wide (inside its own safe area), in whole points; 0 when it is no wider.
    static func inset(forWidth width: CGFloat) -> CGFloat {
        guard width > DesignMetrics.contentMaxWidth else { return 0 }
        return ((width - DesignMetrics.contentMaxWidth) / 2).rounded(.down)
    }
}

extension View {
    /// Measures this navigation stack for `column` and hands its screens the inset (off for
    /// covers, which are full bleed).
    func measuresReadableColumn(_ column: ShellReadableColumn, enabled: Bool = true) -> some View {
        environment(\.shellReadableColumn, enabled)
            .environment(\.shellColumnInset, enabled ? column.inset : 0)
            .onGeometryChange(for: CGFloat.self) { proxy in
                ShellReadableColumn.inset(forWidth: proxy.size.width)
            } action: { inset in
                column.inset = enabled ? inset : 0
            }
    }

    /// Pads this screen's safe area by the stack's column inset on both sides.
    func readableColumnContent() -> some View {
        modifier(ShellReadableColumnContent())
    }
}

private struct ShellReadableColumnContent: ViewModifier {
    @Environment(\.shellColumnInset) private var inset

    func body(content: Content) -> some View {
        content.safeAreaPadding(.horizontal, inset)
    }
}

/// Sits beside a `NavigationStack` (in its background, so it stays in the window whatever is
/// pushed) and reaches the stack's navigation controller for what SwiftUI cannot say:
/// - the navigation bar's large title and search field move onto the column: the bar's layout
///   margins become the system's plus `inset` on each side;
/// - each time `pops` goes up (the stack's path got shorter), the end of the pop animation that
///   follows calls `onPopEnd`, so a search button pressed on a screen pushed on Home's stack
///   focuses Home's field as soon as Home is back rather than after `HomeSearchFocus`'s 600 ms
///   fallback (RN waited for the root stack's `transitionEnd`, 06 §3.5). With no animation
///   starting within a second, nothing is called and the fallback applies.
struct ShellStackProbe: UIViewRepresentable {
    var inset: CGFloat = 0
    var pops = 0
    var onPopEnd: @MainActor () -> Void = {}

    func makeUIView(context: Context) -> ShellStackProbeView {
        let view = ShellStackProbeView()
        view.pops = pops
        return view
    }

    func updateUIView(_ view: ShellStackProbeView, context: Context) {
        view.onPopEnd = onPopEnd
        view.inset = inset
        view.pops = pops
    }
}

/// The probe's view: it finds the navigation controller among the child view controllers of the
/// controller hosting it.
final class ShellStackProbeView: UIView {
    var inset: CGFloat = 0 {
        didSet { applyMargins() }
    }

    var pops = 0 {
        didSet { if pops > oldValue { watchPop() } }
    }

    var onPopEnd: @MainActor () -> Void = {}

    private weak var cachedNavigationController: UINavigationController?
    private var changedMargins = false
    private var popWatch: Task<Void, Never>?

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
        applyMargins()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A size class change can reset the bar's margins.
        applyMargins()
    }

    /// The stack's navigation controller, once it exists.
    var navigationController: UINavigationController? {
        if let cachedNavigationController { return cachedNavigationController }
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController {
                cachedNavigationController = Self.firstNavigationController(in: controller)
                return cachedNavigationController
            }
            responder = current.next
        }
        return nil
    }

    private func applyMargins() {
        // Never touched while there is no column (an iPhone), only restored after one.
        guard inset > 0 || changedMargins, let navigationController else { return }
        changedMargins = inset > 0
        let bar = navigationController.navigationBar
        let system = navigationController.systemMinimumLayoutMargins
        var margins = bar.directionalLayoutMargins
        margins.leading = system.leading + inset
        margins.trailing = system.trailing + inset
        if bar.directionalLayoutMargins != margins { bar.directionalLayoutMargins = margins }
    }

    /// Waits for the pop SwiftUI starts once it applies the shorter path (a frame or more after
    /// the router changed), then reports its end; a cancelled interactive pop reports nothing.
    private func watchPop() {
        popWatch?.cancel()
        popWatch = Task { @MainActor [weak self] in
            for _ in 0..<Self.popWatchFrames {
                guard let self, !Task.isCancelled else { return }
                if let coordinator = self.navigationController?.transitionCoordinator {
                    coordinator.animate(alongsideTransition: nil) { [weak self] context in
                        guard !context.isCancelled else { return }
                        self?.onPopEnd()
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// About a second of frames.
    private static let popWatchFrames = 60

    static func firstNavigationController(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        for child in controller.children {
            if let found = firstNavigationController(in: child) { return found }
        }
        return nil
    }
}
