import SwiftUI
import InventoryAppModels
import InventoryStrings

/// Privacy and your data (RN app/privacy.tsx; 06 §13), pushed from Settings: the in-app notice
/// on camera and gallery data, backup and suggestions. What it says follows this build (a backup
/// service, photo suggestions) and this phone (joined or not), so it never promises something
/// untrue (``AccountPrivacyContent``).
struct PrivacyScreen: View {
    @Environment(AppContainer.self) private var app

    var body: some View {
        ScreenFrame(.detail, background: .plain) {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    ForEach(app.accountPrivacyParts) { part in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: part.title)
                                .textRole(.heading, header: true)
                            ForEach(part.paragraphs, id: \.self) { paragraph in
                                Text(verbatim: paragraph)
                                    .textRole(.body)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle(L10n.Privacy.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen-privacy")
    }
}

#if DEBUG
#Preview("This phone only") {
    AccountPreviewHost(.backupOff) { NavigationStack { PrivacyScreen() } }
}

#Preview("Joined") {
    AccountPreviewHost(.paired) { NavigationStack { PrivacyScreen() } }
}

#Preview("No backup service or suggestions") {
    AccountPreviewHost(.backupUnavailable) { NavigationStack { PrivacyScreen() } }
}
#endif
