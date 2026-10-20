import SwiftUI
import InventoryAppModels
import InventoryStrings

/// What shows while the database opens, onboarding is read and the household session comes back
/// (RN BootScreen.tsx; 09 §7.1). Usually a blink, so the caption only appears after
/// `Motion.delay.bootCaption` (400 ms), in a line reserved from the start so the mark never moves.
/// Nothing is announced (RN's live region was Android-only).
struct BootView: View {
    @State private var caption = DelayedFlag(delay: .milliseconds(Motion.delay.bootCaption))

    var body: some View {
        VStack(spacing: 24) {
            ShellBrandMark()
            Text(L10n.Boot.opening)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .opacity(caption.value ? 1 : 0)
                .accessibilityHidden(!caption.value)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .onAppear { caption.setActive(true) }
        .onDisappear { caption.setActive(false) }
        .accessibilityIdentifier("boot")
    }
}

/// The database could not be opened (RN app/_layout.tsx:142-152; 09 §7.2): the reassurance and
/// Try again, which reopens it. The title is announced when it appears. The raw failure is never
/// shown.
struct BootFailedView: View {
    let retry: () -> Void
    @Environment(\.shellAnnounce) private var announce

    var body: some View {
        ContentUnavailableView {
            Label(L10n.Boot.failedTitle, systemImage: "arrow.clockwise")
        } description: {
            Text(L10n.Boot.failedBody)
        } actions: {
            Button(L10n.Common.tryAgain, action: retry)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("boot-retry")
        }
        .background(Color(.systemBackground))
        .onAppear { announce(L10n.Boot.failedTitle) }
        .accessibilityIdentifier("boot-failed")
    }
}

#Preview("Booting") {
    BootView()
}

#Preview("Boot failed") {
    BootFailedView(retry: {})
}
