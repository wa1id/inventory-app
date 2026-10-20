import SwiftUI
import InventoryAppModels
import InventoryStrings

/// "Reconnecting to the home server…", at the top of every screen once household requests have
/// failed for 2.5 s, gone as soon as one succeeds (RN ConnectionBanner.tsx; 04 §9.6, 09 §7.5).
/// Shown only while `offline`: nothing for brief blips, nothing when the phone is not in a
/// household. It never announces itself: `ConnectionModel` announces the change once, where every
/// screen's banner would talk over the others.
struct ConnectionBanner: View {
    let state: ConnectionState
    let retry: () -> Void

    var body: some View {
        if state == .offline {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "icloud.slash")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(L10n.Connection.reconnecting)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.Connection.retry, action: retry)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.orange.opacity(0.14), in: .rect(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("banner-connection")
        }
    }
}

#Preview("Offline") {
    VStack {
        ConnectionBanner(state: .offline, retry: {})
        Spacer()
    }
}

#Preview("Online (nothing)") {
    ConnectionBanner(state: .online, retry: {})
}
