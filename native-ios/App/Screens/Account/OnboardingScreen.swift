import SwiftUI
import InventoryAppModels
import InventoryStrings

/// Onboarding (RN app/onboarding.tsx; 06 §11): the root while onboarding is pending, never
/// dismissible. Welcome, then joining the household (the shared join form) or using this phone
/// on its own, then "You are in" after a join. Finishing calls `app.onboarding.complete()`, which
/// flips the gate to the main shell by itself (no navigation call).
///
/// The content keeps to a readable column of 480 pt on iPad. What was typed into the join form
/// survives Back → Welcome → Join (``OnboardingFlowModel``).
struct OnboardingScreen: View {
    @Environment(AppContainer.self) private var app
    @State private var flow: OnboardingFlowModel?
    /// The heading VoiceOver moves to when a step is swapped in: the button that was pressed
    /// goes with the step it was on.
    @AccessibilityFocusState private var focusedHeading: OnboardingFlowModel.Step?
    #if DEBUG
    @Environment(\.accountDemoOnboardingStart) private var previewStart
    #endif

    var body: some View {
        NavigationStack {
            if let flow {
                switch flow.step {
                case .welcome:
                    OnboardingWelcomeStep(flow: flow, headingFocus: $focusedHeading)
                        .toolbar(.hidden, for: .navigationBar)
                case .join:
                    if let form = flow.joinForm {
                        AccountJoinForm(
                            model: form,
                            showsConnectionBanner: false,
                            columnWidth: OnboardingLayout.columnWidth,
                            onJoin: { Task { await flow.join() } }
                        ) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(verbatim: L10n.Household.joinHeading)
                                    .textRole(.title, header: true)
                                    .accessibilityFocused($focusedHeading, equals: .join)
                                Text(verbatim: L10n.Household.joinBody)
                                    .textRole(.body)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button { flow.back() } label: {
                                    Label(L10n.Onboarding.back, glyph: .back)
                                }
                                .accessibilityIdentifier("onboarding-back")
                            }
                        }
                        // The step is swapped in, not pushed: VoiceOver's escape goes Back too.
                        .accessibilityAction(.escape) { flow.back() }
                    }
                case .joined:
                    OnboardingJoinedStep(flow: flow, headingFocus: $focusedHeading)
                        .toolbar(.hidden, for: .navigationBar)
                }
            } else {
                // Never an empty view: SwiftUI does not run onAppear on one.
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
        .accessibilityIdentifier("screen-onboarding")
        .onAppear(perform: setUp)
        .onChange(of: flow?.step) { _, step in
            guard let step else { return }
            Task { @MainActor in
                // Once the new step is on screen.
                try? await Task.sleep(for: .milliseconds(150))
                focusedHeading = step
            }
        }
    }

    private func setUp() {
        guard flow == nil else { return }
        let made = app.makeOnboardingFlow()
        flow = made
        #if DEBUG
        switch previewStart ?? AccountDemo.takeOnboardingStart() {
        case .join?: made.showJoin()
        case .joined?: made.joined(HouseholdJoined(householdName: AccountDemoServer.session.householdName, hasImportOffer: false))
        case nil: break
        }
        #endif
    }
}

/// The first step (RN `Welcome`): the mark, the title, the three things the app is for, and the
/// two ways on (or Continue on a phone replaying onboarding after it joined).
private struct OnboardingWelcomeStep: View {
    let flow: OnboardingFlowModel
    let headingFocus: AccessibilityFocusState<OnboardingFlowModel.Step?>.Binding

    /// RN `FACT_ICONS`: search, plus, scan, in the order she will need them.
    private static let factGlyphs: [Glyph] = [.search, .plus, .scan]

    var body: some View {
        ScreenFrame(.detail, banner: false, background: .plain) {
            OnboardingCentredScroll {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        BrandMark(size: .large)
                        Text(verbatim: L10n.Onboarding.brand)
                            .textRole(.section)
                            .fontWeight(.heavy)
                    }
                    Text(verbatim: L10n.Onboarding.title)
                        .textRole(.display, header: true)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityFocused(headingFocus, equals: .welcome)
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(L10n.Onboarding.facts.enumerated()), id: \.offset) { index, fact in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Image(glyph: Self.factGlyphs.indices.contains(index) ? Self.factGlyphs[index] : .info)
                                    .font(.title3)
                                    // An inline icon grows with the text only so far (RN `inlineIconSize`).
                                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                                    .frame(minWidth: 28)
                                    .accessibilityHidden(true)
                                Text(verbatim: fact)
                                    .textRole(.body)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        } bottomBar: {
            OnboardingActions {
                if flow.offersOnlyContinue {
                    LoadingButton(label: L10n.Onboarding.`continue`, fullWidth: true, identifier: "onboarding-continue") {
                        flow.continueJoined()
                    }
                } else {
                    LoadingButton(label: L10n.Onboarding.join, fullWidth: true, identifier: "onboarding-join") {
                        flow.showJoin()
                    }
                    LoadingButton(label: L10n.Onboarding.local, variant: .quiet, fullWidth: true, identifier: "onboarding-local") {
                        flow.useOnItsOwn()
                    }
                }
            }
        }
    }
}

/// After joining (RN `JoinedStep`): a check in ink, "You are in", and Start.
private struct OnboardingJoinedStep: View {
    let flow: OnboardingFlowModel
    let headingFocus: AccessibilityFocusState<OnboardingFlowModel.Step?>.Binding

    var body: some View {
        ScreenFrame(.detail, banner: false, background: .plain) {
            OnboardingCentredScroll {
                VStack(alignment: .leading, spacing: 12) {
                    // Ink, like the mark on Welcome and Start, so the end of joining carries
                    // weight in both schemes.
                    Image(glyph: .check)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color.accentColor))
                        .padding(.bottom, 8)
                        .accessibilityHidden(true)
                    Text(verbatim: L10n.Onboarding.joinedTitle)
                        .textRole(.title, header: true)
                        .accessibilityFocused(headingFocus, equals: .joined)
                    Text(verbatim: flow.joinedBody)
                        .textRole(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } bottomBar: {
            OnboardingActions {
                LoadingButton(label: L10n.Onboarding.start, fullWidth: true, identifier: "onboarding-start") {
                    flow.start()
                }
            }
        }
    }
}

/// A step's content, centred in the column while it fits and scrolling once it does not
/// (Dynamic Type at its largest), so the buttons below are never pushed away.
private struct OnboardingCentredScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .padding(.horizontal, 16)
                    .padding(.vertical, 32)
                    .frame(maxWidth: OnboardingLayout.columnWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Text scrolled under the buttons stays out of the way of the quiet one.
            .scrollEdgeEffectStyle(.hard, for: .bottom)
        }
    }
}

/// The step's buttons, one under the other, the primary first (RN `actions`), pinned under the
/// content in the frame's bottom bar.
private struct OnboardingActions<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 8) {
            content
        }
        // Pinned, so its text grows only to AX1 (as the connection banner's and the camera's
        // pinned controls do; RN capped button text lower still, at 1.6, 08 §6): past it the two
        // stacked buttons took nearly half an iPhone SE at AX5. The step's own text above keeps
        // growing, and scrolls.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        // Its full height at the largest text sizes, so no label is cut short; the step's
        // content scrolls behind it instead.
        .fixedSize(horizontal: false, vertical: true)
        .buttonSizing(.flexible)
        .controlSize(.large)
        .frame(maxWidth: OnboardingLayout.columnWidth)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }
}

/// RN `MAX_WIDTH`: onboarding fits a phone; on an iPad it stays a readable column.
private enum OnboardingLayout {
    static let columnWidth: CGFloat = 480
}

#if DEBUG
#Preview("Welcome") {
    AccountPreviewHost(.onboarding) { OnboardingScreen() }
}

#Preview("Welcome, replayed on a joined phone") {
    AccountPreviewHost(.onboardingReplay) { OnboardingScreen() }
}

#Preview("Join") {
    AccountPreviewHost(.onboardingJoin) {
        OnboardingScreen().environment(\.accountDemoOnboardingStart, .join)
    }
}

#Preview("You are in") {
    AccountPreviewHost(.onboardingJoined) {
        OnboardingScreen().environment(\.accountDemoOnboardingStart, .joined)
    }
}
#endif
