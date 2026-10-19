/// What the root view shows, worked out from the three things boot waits for (RN
/// `RootNavigator`, app/_layout.tsx:104-221; 09 §2.4, §3.2 step 3; 06 §2).
///
/// In order:
/// 1. the database failed → the failure screen with Try again, **even while** onboarding or
///    the household session are still loading;
/// 2. the database, the onboarding flag or the household session is still loading → the boot
///    view (the session must be known before any screen reads, or a joined phone would flash
///    its local copy);
/// 3. otherwise onboarding or the main shell, from the onboarding status alone.
///
/// Nothing else gates: fonts are gone natively and the backup account loads on the side, which
/// is why neither is an input here.
public enum BootGate {
    /// The root view's four states.
    public enum Phase: Sendable, Hashable {
        /// The database could not be opened: `L10n.Boot.failedTitle` / `failedBody` and
        /// `L10n.Common.tryAgain`, which calls `DatabaseModel.retry()`.
        case failed
        /// The boot view: the mark, and `L10n.Boot.opening` after `Motion.delay.bootCaption`.
        case booting
        /// The onboarding flow, as the full-screen root (not dismissible).
        case onboarding
        /// The tabs and every route.
        case main
    }

    /// The root view's state for these inputs.
    ///
    /// - Parameters:
    ///   - database: `DatabaseModel.status`.
    ///   - onboarding: `OnboardingModel.status`.
    ///   - householdReady: whether the household session has come back from the keychain
    ///     (RN `household.ready`), paired or not.
    public static func phase(
        database: DatabaseModel.Status,
        onboarding: OnboardingModel.Status,
        householdReady: Bool
    ) -> Phase {
        if database == .failed { return .failed }
        if database == .loading || onboarding == .loading || !householdReady { return .booting }
        return onboarding == .completed ? .main : .onboarding
    }
}
