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
            // RN: a warning `Banner` with the cloud-off icon and Retry, `live="off"`.
            BannerView(
                tone: .warning,
                glyph: .cloudOff,
                message: L10n.Connection.reconnecting,
                primary: BannerAction(label: L10n.Connection.retry, action: retry),
                live: .off,
                identifier: "banner-connection"
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
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
