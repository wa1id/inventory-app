import SwiftUI
import InventoryAppModels
import InventoryStrings

/// Where the toast card is on screen, so the overlay window lets touches through everywhere else.
@MainActor
@Observable
final class ShellOverlayState {
    /// The card's frame in window coordinates, or nil when no toast shows.
    var cardFrame: CGRect?
}

/// Draws ``ToastCenter/current`` at the bottom of the overlay window, above the focused screen's
/// tab bar or bottom bar (RN Toast.tsx `ToastHost`; 06 §14, 09 §4.6, §7.7).
struct ToastHost: View {
    let toasts: ToastCenter
    let overlay: ShellOverlayState
    var tabBarChrome: ShellTabBarChrome?

    var body: some View {
        // Laid out inside the safe area, so its bottom inset is known (a reader that ignores the
        // safe area reports none, which put the toast over the home indicator). Chrome heights are
        // measured from the window's bottom edge, so the inset comes off them.
        GeometryReader { geometry in
            let chrome = ShellTabBarChrome.toastChrome(registered: toasts.chromeHeight, tabBar: tabBarChrome?.height)
            let inset = Double(geometry.safeAreaInsets.bottom)
            let bottom = max(0, (chrome ?? inset) - inset) + ToastCenter.Layout.gap
            ZStack(alignment: .bottom) {
                Color.clear
                if let record = toasts.current {
                    ToastCard(record: record, leaving: toasts.leaving, toasts: toasts)
                        .id(record.id)
                        // The card alone, measured before the padding that lifts it: the padding
                        // reaches down over the tab bar and bottom bars, whose touches must pass.
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { overlay.cardFrame = $0 }
                        .onDisappear { overlay.cardFrame = nil }
                        .frame(maxWidth: ToastCenter.Layout.maxWidth)
                        .padding(.horizontal, 16)
                        .padding(.bottom, bottom)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One toast: the message (never truncated), the action button and the close button, on a
/// Liquid Glass card. It fades in with an 8 pt rise and out on leaving (Reduce Motion: no rise,
/// no fade), stands still while touched, and a downward swipe of more than 24 pt dismisses it.
private struct ToastCard: View {
    let record: ToastCenter.Record
    let leaving: Bool
    let toasts: ToastCenter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var appeared = false
    @State private var drag: CGFloat = 0
    @State private var touching = false

    private var isError: Bool { record.tone == .error }

    var body: some View {
        let durations = Motion.duration(reduceMotion: reduceMotion)
        card
            .opacity(leaving ? 0 : (appeared ? 1 : 0))
            .offset(y: (appeared || reduceMotion ? 0 : 8) + drag)
            .animation(.shellCurve(Motion.Easing.exit, ms: durations.toastOut), value: leaving)
            .onAppear {
                withAnimation(.shellCurve(Motion.Easing.out, ms: durations.toastIn)) { appeared = true }
            }
            .simultaneousGesture(touchAndSwipe)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("toast")
    }

    @ViewBuilder
    private var card: some View {
        let layout = dynamicTypeSize >= .xxxLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if isError {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                }
                Text(record.message)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 4) {
                if dynamicTypeSize >= .xxxLarge { Spacer(minLength: 0) }
                if let action = record.action {
                    Button(action.label) { toasts.performAction(of: record.id) }
                        .font(.subheadline.weight(.bold))
                        .buttonStyle(.borderless)
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(leaving)
                        .accessibilityLabel(record.actionAccessibilityLabel ?? action.label)
                        .accessibilityHidden(leaving)
                        .accessibilityIdentifier("toast-action")
                }
                Button {
                    toasts.dismiss(record.id)
                } label: {
                    Label(L10n.A11y.dismissToast, systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("toast-dismiss")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 56)
        .overlay(alignment: .leading) {
            if isError {
                Rectangle()
                    .fill(.red)
                    .frame(width: 4)
                    .accessibilityHidden(true)
            }
        }
        .clipShape(.rect(cornerRadius: 20, style: .continuous))
        .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
    }

    /// Touch down pauses the toast's life, touch up resumes it; a mostly vertical downward drag
    /// past `swipeDismissDistance` dismisses, a shorter one springs back.
    private var touchAndSwipe: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !touching {
                    touching = true
                    toasts.pause()
                }
                let dy = value.translation.height
                if dy > ToastCenter.Layout.dragStartDistance, abs(dy) > abs(value.translation.width) {
                    drag = max(0, dy)
                }
            }
            .onEnded { value in
                touching = false
                let dy = value.translation.height
                if dy > ToastCenter.Layout.swipeDismissDistance, abs(dy) > abs(value.translation.width) {
                    toasts.dismiss(record.id)
                } else if reduceMotion {
                    drag = 0
                } else {
                    withAnimation(.spring) { drag = 0 }
                }
                toasts.resume()
            }
    }
}

extension Animation {
    /// A `Motion.Curve` over `ms` milliseconds (0 under Reduce Motion: no animation).
    static func shellCurve(_ curve: Motion.Curve, ms: Int) -> Animation {
        .timingCurve(curve.x1, curve.y1, curve.x2, curve.y2, duration: Double(ms) / 1000)
    }
}

#Preview("Toasts") {
    @Previewable @State var toasts = ToastCenter()
    @Previewable @State var overlay = ShellOverlayState()
    ZStack {
        VStack(spacing: 12) {
            Button(AppTab.add.title) { toasts.show(ToastOptions(message: L10n.Move.undone)) }
            Button(AppTab.dropZone.title) {
                toasts.show(ToastOptions(
                    message: L10n.Move.movedTo(container: "Tool chest", space: "Garage"),
                    action: ToastAction(label: L10n.Common.undo) {}))
            }
            Button(AppTab.scan.title) { toasts.show(ToastOptions(message: L10n.Move.failed, tone: .error)) }
        }
        ToastHost(toasts: toasts, overlay: overlay)
    }
    .onAppear {
        toasts.show(ToastOptions(
            message: L10n.Move.movedTo(container: "Tool chest", space: "Garage"),
            action: ToastAction(label: L10n.Common.undo) {}))
    }
}
