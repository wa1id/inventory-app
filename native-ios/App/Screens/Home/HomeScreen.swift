import SwiftUI
import InventoryAppModels
import InventoryStrings

/// Home (06 §5). Placeholder: the screen wave replaces the body.
struct HomeScreen: View {
    @Environment(AppContainer.self) private var app

    var body: some View {
        ScreenFrame(.tabRoot) {
            ShellPlaceholderContent(title: L10n.Home.title, systemImage: AppTab.home.systemImage) {
                Button(L10n.Home.DropZone.sort) { app.router.goToTab(.dropZone) }
                Button(L10n.Home.DropZone.quickSnap) { app.router.openQuickSnap() }
                Button(L10n.DeepLink.title) { app.router.push(.label(token: "0123456789abcdef0123456789abcdef")) }
                #if DEBUG
                Button(L10n.Common.undo) {
                    app.toasts.show(ToastOptions(
                        message: L10n.Move.movedTo(container: "Tool chest", space: "Garage"),
                        action: ToastAction(label: L10n.Common.undo) {}))
                }
                .accessibilityIdentifier("debug-toast")
                Button(L10n.Move.failed) {
                    app.toasts.show(ToastOptions(message: L10n.Move.failed, tone: .error))
                }
                .accessibilityIdentifier("debug-toast-error")
                // For the UI tests: how many re-taps of Home reached the screen.
                Text(verbatim: "\(app.router.reselections[.home] ?? 0)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("debug-home-reselections")
                #endif
            }
        }
        .navigationTitle(L10n.Home.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    app.router.push(.settings)
                } label: {
                    Label(L10n.Home.settings, systemImage: "gearshape")
                }
                .accessibilityIdentifier("home-settings")
            }
        }
        .accessibilityIdentifier("screen-home")
    }
}

#Preview {
    ShellPreviewHost { NavigationStack { HomeScreen() } }
}
