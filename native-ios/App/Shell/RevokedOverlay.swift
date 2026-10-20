import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// The one thing a removed phone sees, over every screen and sheet, instead of an error on each
/// of them (RN `RevokedLayer`, ConnectionBanner.tsx:43-120; 04 §9.6, 09 §7.6).
///
/// When it appears it closes everything presented and pops every stack, so leaving it lands on a
/// tab root, and announces its title. "Join again" forgets the session without telling the home
/// server (the token is already dead), refreshes every list and opens Household; "Use this phone
/// on its own" does the same without opening anything. It leaves by itself once the connection
/// is no longer revoked. While it shows, the rest of the app is hidden from VoiceOver and every
/// touch lands on it (the overlay window captures them).
struct RevokedOverlay: View {
    @Environment(AppContainer.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BrandMark()
                Text(L10n.Revoked.title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.Revoked.body)
                    .foregroundStyle(.secondary)
                VStack(spacing: 8) {
                    LoadingButton(label: L10n.Revoked.join, fullWidth: true, identifier: "revoked-join", action: joinAgain)
                    LoadingButton(label: L10n.Revoked.local, variant: .quiet, fullWidth: true, identifier: "revoked-local", action: carryOnAlone)
                }
                .controlSize(.large)
                .padding(.top, 8)
            }
            .frame(maxWidth: DesignMetrics.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 64)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(.systemBackground).ignoresSafeArea())
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("revoked")
        .onAppear {
            app.router.dismissAll()
            app.platform.announce(L10n.Revoked.title)
        }
    }

    private func joinAgain() {
        leave()
        app.router.push(.household)
    }

    private func carryOnAlone() {
        leave()
    }

    private func leave() {
        app.household.disconnect(revokeDevice: false)
        app.database.invalidate()
    }
}

#if DEBUG
// DEBUG only (previews, the demo, tests): kept out of Release builds.
#Preview {
    ShellPreviewHost {
        RevokedOverlay()
    }
}
#endif
