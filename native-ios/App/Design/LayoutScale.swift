import SwiftUI

extension EnvironmentValues {
    /// The window's width (RN `useWindowDimensions().width`), which decides whether layouts
    /// stack on the narrowest windows (iPad Slide Over, split view). Set at the root of each
    /// window with `measuresLayoutWindowWidth()`; infinite until then, so nothing stacks for
    /// width alone in previews.
    @Entry var layoutWindowWidth: CGFloat = .infinity
}

/// Whether layouts should stack instead of sitting side by side (RN `useLayoutScale`,
/// src/hooks/useLayoutScale.ts; 08 §9.2 item 14).
///
/// RN stacked at font scale ≥ 1.35 or window width < 360. With RN's iOS multipliers that is
/// exactly Dynamic Type `xxxLarge` and up. A row's control, a two-button bar or a wide stepper
/// then goes under its text instead of squeezing it into a column a few letters wide. Use it as
/// a stored property of a view: `private let layout = LayoutScale()`.
struct LayoutScale: DynamicProperty {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutWindowWidth) private var windowWidth

    init() {}

    /// Rows, bars and steppers stack.
    var isStacked: Bool { Self.isStacked(dynamicTypeSize: dynamicTypeSize, windowWidth: windowWidth) }

    /// The window is narrower than 360 pt (the type grid drops to three columns).
    var isNarrow: Bool { windowWidth < DesignMetrics.narrowWidth }

    /// The rule itself: `xxxLarge` and up, or a window narrower than 360 pt.
    static func isStacked(dynamicTypeSize: DynamicTypeSize, windowWidth: CGFloat) -> Bool {
        dynamicTypeSize >= .xxxLarge || windowWidth < DesignMetrics.narrowWidth
    }
}

private struct WindowWidthReader: ViewModifier {
    @State private var width: CGFloat = .infinity

    func body(content: Content) -> some View {
        content
            .environment(\.layoutWindowWidth, width)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

private struct WindowSizeReader: ViewModifier {
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .environment(\.layoutWindowWidth, size.width > 0 ? size.width : .infinity)
            .environment(\.shellWindowSize, size)
            .onGeometryChange(for: CGSize.self) { proxy in
                CGSize(
                    width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                    height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
                )
            } action: { size = $0 }
    }
}

extension View {
    /// Measures this view's width as the window width for ``LayoutScale``. Apply once, at the
    /// root of a window.
    func measuresLayoutWindowWidth() -> some View {
        modifier(WindowWidthReader())
    }

    /// Measures this view as the window, for roots outside `RootView` (the galleries): sets both
    /// `\.layoutWindowWidth` and the shell's `\.shellWindowSize`, which the bottom bar and the
    /// camera notices size themselves by.
    func measuresComponentWindow() -> some View {
        modifier(WindowSizeReader())
    }
}

/// Two pieces on one line, the first at the leading edge and the second at the trailing edge, or
/// the second under the first (both leading) when they do not fit side by side: what a
/// `ViewThatFits { HStack; VStack }` draws, without swapping one copy of the views for another.
/// A swap rebuilds the views when the text grows, which loses VoiceOver's place and makes Xcode's
/// Dynamic Type audit lose track of every text inside ("partially unsupported").
struct ComponentFitOrStack: Layout {
    var horizontalSpacing: CGFloat = 12
    var verticalSpacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return subviews.first?.sizeThatFits(proposal) ?? .zero }
        let first = subviews[0].sizeThatFits(.unspecified), second = subviews[1].sizeThatFits(.unspecified)
        let sideBySide = first.width + horizontalSpacing + second.width
        guard let width = proposal.width else {
            return CGSize(width: sideBySide, height: max(first.height, second.height))
        }
        if sideBySide <= width + WrappingHStack.fitTolerance {
            return CGSize(width: width, height: max(first.height, second.height))
        }
        let narrow = ProposedViewSize(width: width, height: nil)
        let stackedFirst = subviews[0].sizeThatFits(narrow), stackedSecond = subviews[1].sizeThatFits(narrow)
        return CGSize(width: width, height: stackedFirst.height + verticalSpacing + stackedSecond.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            return
        }
        let first = subviews[0].sizeThatFits(.unspecified), second = subviews[1].sizeThatFits(.unspecified)
        if first.width + horizontalSpacing + second.width <= bounds.width + WrappingHStack.fitTolerance {
            let height = max(first.height, second.height)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + (height - first.height) / 2), proposal: ProposedViewSize(first))
            subviews[1].place(at: CGPoint(x: bounds.maxX - second.width, y: bounds.minY + (height - second.height) / 2), proposal: ProposedViewSize(second))
            return
        }
        let narrow = ProposedViewSize(width: bounds.width, height: nil)
        let stackedFirst = subviews[0].sizeThatFits(narrow), stackedSecond = subviews[1].sizeThatFits(narrow)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: min(stackedFirst.width, bounds.width), height: stackedFirst.height))
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + stackedFirst.height + verticalSpacing),
            proposal: ProposedViewSize(width: min(stackedSecond.width, bounds.width), height: stackedSecond.height)
        )
    }
}

/// Side by side, or stacked when ``LayoutScale`` says so: the shape bottom bars, a row's control
/// and the stepper's Done button share.
struct AdaptiveStack<Content: View>: View {
    var horizontalAlignment: HorizontalAlignment
    var verticalAlignment: VerticalAlignment
    var spacing: CGFloat?
    /// Forces the stacked layout (a caller that knows better, e.g. a narrower container).
    var forceStacked: Bool
    @ViewBuilder var content: Content

    private let layout = LayoutScale()

    init(
        horizontalAlignment: HorizontalAlignment = .leading,
        verticalAlignment: VerticalAlignment = .center,
        spacing: CGFloat? = nil,
        forceStacked: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.horizontalAlignment = horizontalAlignment
        self.verticalAlignment = verticalAlignment
        self.spacing = spacing
        self.forceStacked = forceStacked
        self.content = content()
    }

    var body: some View {
        let stacked = forceStacked || layout.isStacked
        let shape = stacked
            ? AnyLayout(VStackLayout(alignment: horizontalAlignment, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: verticalAlignment, spacing: spacing))
        shape { content }
    }
}
