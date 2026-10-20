import SwiftUI
import InventoryAppModels
import InventoryStrings

/// Off-device backup (03 §10). Placeholder: the screen wave replaces the body.
struct BackupScreen: View {
    var body: some View {
        ScreenFrame(.detail) {
            ShellPlaceholderContent(title: L10n.Backup.title, systemImage: "clock.arrow.circlepath")
        }
        .navigationTitle(L10n.Backup.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen-backup")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { BackupScreen() } }
}
