import SwiftUI
import InventoryAppModels

/// The bar that holds a screen's primary action, pinned under the content by ``ScreenFrame``
/// (RN BottomBar.tsx; 09 §7.8): in reach of the thumb and never hidden by the keyboard, which is
/// why forms put Save here rather than in the toolbar.
///
/// One or two buttons, secondary first and primary last, so the primary sits on the trailing
/// side under the thumb. Side by side the secondary takes 1 part and the primary 1.4, or with
/// `primaryFit` the primary sizes to its label (at least 120 pt) and the secondary takes the
/// rest; both are as tall as the taller. At large text (`.xxxLarge` and up) or in a window
/// narrower than 360 pt they stack, primary on top. While its screen is focused the bar registers
/// its height, so toasts float above it.
struct BottomBar<Secondary: View, Primary: View>: View {
    private let primaryFit: Bool
    private let stackOnLarge: Bool
    private let secondary: Secondary?
    private let primary: Primary

    @Environment(AppContainer.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.shellWindowSize) private var windowSize
    @Environment(\.isScreenFocused) private var isScreenFocused
    @State private var height: Double = 0
    @State private var chrome: ToastCenter.ChromeRegistration?

    /// Two buttons: `secondary` first, `primary` last.
    init(
        primaryFit: Bool = false,
        stackOnLarge: Bool = true,
        @ViewBuilder secondary: () -> Secondary,
        @ViewBuilder primary: () -> Primary
    ) {
        self.primaryFit = primaryFit
        self.stackOnLarge = stackOnLarge
        self.secondary = secondary()
        self.primary = primary()
    }

    /// The largest text size the bar's labels take (RN `button` maxScale 1.6; 08 §6).
    static var maximumTextSize: DynamicTypeSize { .xxxLarge }

    /// RN `stacked`: font scale ≥ 1.35 (`.xxxLarge`) or a window narrower than 360 pt
    /// (``LayoutScale``'s rule; a width of 0 is not measured yet).
    static func isStacked(dynamicTypeSize: DynamicTypeSize, windowWidth: CGFloat) -> Bool {
        LayoutScale.isStacked(dynamicTypeSize: dynamicTypeSize, windowWidth: windowWidth > 0 ? windowWidth : .infinity)
    }

    private var stacks: Bool {
        stackOnLarge && secondary != nil && Self.isStacked(dynamicTypeSize: dynamicTypeSize, windowWidth: windowSize.width)
    }

    var body: some View {
        buttons
            .buttonSizing(.flexible)
            .controlSize(.large)
            // Pinned chrome, like a toolbar: the labels stop growing at RN's button cap
            // (`button` maxScale 1.6, `.xxxLarge`; 08 §6), so at the largest sizes two stacked
            // buttons take a fifth of the screen rather than two fifths and the content keeps the
            // room. Long-pressing a button shows its label in the Large Content Viewer, as the
            // system bars do.
            .dynamicTypeSize(...Self.maximumTextSize)
            .frame(maxWidth: DesignMetrics.contentMaxWidth)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: Double.self) { proxy in
                Double(proxy.frame(in: .global).minY)
            } action: { top in
                height = windowSize.height > 0 ? max(0, Double(windowSize.height) - top) : 0
                updateChrome()
            }
            .onChange(of: isScreenFocused, initial: true) { updateChrome() }
            .onDisappear { release() }
    }

    @ViewBuilder
    private var buttons: some View {
        if let secondary {
            // One tree for both shapes, so a change of text size keeps the buttons (and
            // VoiceOver's place on them) rather than building new ones.
            BottomBarRow(primaryFit: primaryFit, stacked: stacks) {
                secondary.accessibilityShowsLargeContentViewer()
                primary.accessibilityShowsLargeContentViewer()
            }
        } else {
            primary.accessibilityShowsLargeContentViewer()
        }
    }

    private func updateChrome() {
        release()
        guard isScreenFocused, height > 0 else { return }
        chrome = app.toasts.registerChrome(height: height)
    }

    private func release() {
        if let chrome { app.toasts.unregisterChrome(chrome) }
        chrome = nil
    }
}

extension BottomBar where Secondary == EmptyView {
    /// One button.
    init(@ViewBuilder primary: () -> Primary) {
        primaryFit = false
        stackOnLarge = true
        secondary = nil
        self.primary = primary()
    }
}

/// Two cells side by side: 1 : 1.4, or the second sized to fit (at least 120 pt) and the first
/// taking the rest; both proposed the taller one's height. Stacked, the second (the primary) sits
/// on top and each takes the full width (RN's `column-reverse`). The secondary is first in the
/// tree in both shapes, as in RN, so VoiceOver meets the buttons in the same order either way.
private struct BottomBarRow: Layout {
    var primaryFit: Bool
    var stacked = false
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else {
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }
        if stacked {
            let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
            let width = proposal.width ?? sizes.map(\.width).max() ?? 0
            return CGSize(width: width, height: sizes[0].height + spacing + sizes[1].height)
        }
        let width = proposal.width ?? (subviews[0].sizeThatFits(.unspecified).width + spacing + subviews[1].sizeThatFits(.unspecified).width)
        let (first, second) = widths(width, subviews)
        let height = max(
            subviews[0].sizeThatFits(ProposedViewSize(width: first, height: nil)).height,
            subviews[1].sizeThatFits(ProposedViewSize(width: second, height: nil)).height
        )
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            return
        }
        if stacked {
            let width = ProposedViewSize(width: bounds.width, height: nil)
            let primaryHeight = subviews[1].sizeThatFits(width).height
            subviews[1].place(at: bounds.origin, proposal: width)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + primaryHeight + spacing), proposal: width)
            return
        }
        let (first, second) = widths(bounds.width, subviews)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: first, height: bounds.height))
        subviews[1].place(
            at: CGPoint(x: bounds.minX + first + spacing, y: bounds.minY),
            proposal: ProposedViewSize(width: second, height: bounds.height)
        )
    }

    private func widths(_ total: CGFloat, _ subviews: Subviews) -> (CGFloat, CGFloat) {
        let available = max(0, total - spacing)
        if primaryFit {
            let fitted = max(120, subviews[1].sizeThatFits(.unspecified).width)
            let second = min(fitted, available)
            return (available - second, second)
        }
        return (available / 2.4, available * 1.4 / 2.4)
    }
}

#if DEBUG
// DEBUG only (previews, the demo, tests): kept out of Release builds.
#Preview("Two buttons") {
    ShellPreviewHost {
        VStack {
            Spacer()
            BottomBar {
                LoadingButton(label: AppTab.spaces.title, variant: .secondary, fullWidth: true) {}
            } primary: {
                LoadingButton(label: AppTab.home.title, fullWidth: true) {}
            }
        }
    }
}

#Preview("Primary fit, stacked at large text") {
    ShellPreviewHost {
        VStack {
            Spacer()
            BottomBar(primaryFit: true) {
                LoadingButton(label: AppTab.add.accessibilityLabel(), variant: .secondary, fullWidth: true) {}
            } primary: {
                LoadingButton(label: AppTab.home.title, fullWidth: true) {}
            }
        }
    }
    .environment(\.dynamicTypeSize, .accessibility2)
}
#endif
