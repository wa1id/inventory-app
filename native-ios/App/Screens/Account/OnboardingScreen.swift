import SwiftUI
import InventoryAppModels
import InventoryStrings

/// Onboarding (06 §11): the root while onboarding is pending, not dismissible. Completing it flips
/// the gate to the main shell (no navigation call). Placeholder: the screen wave replaces the body.
struct OnboardingScreen: View {
    @Environment(AppContainer.self) private var app

    var body: some View {
        ScreenFrame(.detail, background: .plain) {
            ShellPlaceholderContent(title: L10n.Onboarding.title, systemImage: "shippingbox") {
                Button(L10n.Onboarding.start) { app.onboarding.complete() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("onboarding-start")
            }
        }
        .accessibilityIdentifier("screen-onboarding")
    }
}

#Preview {
    ShellPreviewHost(onboardingCompleted: false) { OnboardingScreen() }
}
