#if DEBUG
import OSLog
import SwiftUI
import InventoryAppModels

/// DEBUG demo hooks for the account area: onboarding, Settings, Household, Backup and Privacy.
///
/// Every state can be screenshotted without tapping:
/// `mac.sh run out.png -demo YES -demoArea account -demoState <state> [-demoRoute <spec>]`,
/// where `<state>` is an ``AccountDemoScenario`` (`paired`, `backupRestoreOffer`, …) and the
/// route opens the screen (`settings`, `household`, `backup`, `privacy`, or a chain such as
/// `'settings>backup'`). Onboarding states need no route: the gate shows onboarding.
enum AccountDemo {
    /// The scenario's container (``AppContainer/accountDemo(_:platform:now:)``), or nil for an
    /// unknown state (the default demo container then runs).
    @MainActor
    static func container(state: String, platform: AppPlatform) -> AppContainer? {
        guard let scenario = AccountDemoScenario(rawValue: state) else {
            let names = AccountDemoScenario.allCases.map(\.rawValue).joined(separator: ", ")
            ShellDemo.log.error("-demoState \(state, privacy: .public) is not an account state; use one of \(names, privacy: .public)")
            return nil
        }
        return AppContainer.accountDemo(scenario, platform: platform)
    }

    /// Once the main shell shows, before `-demoRoute`: what a state needs beyond its container.
    @MainActor
    static func run(state: String, app: AppContainer) async {
        guard AccountDemoScenario(rawValue: state) == .backupFailing else { return }
        // Only a backup the person asked for shows its failure: run one while the service is down.
        for _ in 0..<50 where app.sync.status.account == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        _ = await app.sync.backupNow()
    }

    /// What the Backup screen does by itself the first time it shows in this launch's state.
    enum BackupAction: Sendable, Hashable {
        /// "Show recovery code".
        case showCode
        /// "Turn on backup".
        case turnOn
    }

    /// Where onboarding starts in this launch's state.
    enum OnboardingStart: Sendable, Hashable {
        case join
        case joined
    }

    /// The Backup screen's action for this launch, once.
    @MainActor
    static func takeBackupAction() -> BackupAction? {
        guard !tookBackupAction, let scenario = launchScenario else { return nil }
        tookBackupAction = true
        switch scenario {
        case .backupReveal: return .showCode
        case .backupKeptCode: return .turnOn
        default: return nil
        }
    }

    /// Onboarding's first step for this launch, once.
    @MainActor
    static func takeOnboardingStart() -> OnboardingStart? {
        guard !tookOnboardingStart, let scenario = launchScenario else { return nil }
        tookOnboardingStart = true
        switch scenario {
        case .onboardingJoin: return .join
        case .onboardingJoined: return .joined
        default: return nil
        }
    }

    /// `-demoArea account -demoState <scenario>` in a `-demo YES` launch.
    @MainActor
    private static var launchScenario: AccountDemoScenario? {
        guard UserDefaults.standard.bool(forKey: "demo"), ShellDemo.area == .account else { return nil }
        return AccountDemoScenario(rawValue: ShellDemo.state)
    }

    @MainActor private static var tookBackupAction = false
    @MainActor private static var tookOnboardingStart = false
}

extension EnvironmentValues {
    /// A preview's stand-in for ``AccountDemo/takeBackupAction()``.
    @Entry var accountDemoBackupAction: AccountDemo.BackupAction?
    /// A preview's stand-in for ``AccountDemo/takeOnboardingStart()``.
    @Entry var accountDemoOnboardingStart: AccountDemo.OnboardingStart?
}

/// Runs a preview on an account demo state: boots ``AppContainer/accountDemo(_:platform:now:)``
/// and shows `content` once the database is ready, with the shell's environment.
struct AccountPreviewHost<Content: View>: View {
    @State private var app: AppContainer
    private let content: Content

    init(_ scenario: AccountDemoScenario, @ViewBuilder content: () -> Content) {
        _app = State(initialValue: AppContainer.accountDemo(scenario, platform: .silent()))
        self.content = content()
    }

    var body: some View {
        Group {
            if app.database.status == .ready {
                content
            } else {
                ProgressView()
            }
        }
        .shellEnvironment(app)
        .task { await app.boot.run() }
    }
}
#endif
