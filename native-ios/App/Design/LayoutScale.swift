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

extension View {
    /// Measures this view's width as the window width for ``LayoutScale``. Apply once, at the
    /// root of a window.
    func measuresLayoutWindowWidth() -> some View {
        modifier(WindowWidthReader())
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
