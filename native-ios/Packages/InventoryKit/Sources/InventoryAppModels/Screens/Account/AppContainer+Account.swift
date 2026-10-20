import InventoryCore
import InventoryServices

// The account screens' models, wired from the container the way their RN screens reached their
// providers: Settings, Privacy, Household (join form and paired view), Backup and onboarding.

extension AppContainer {
    /// What Settings shows now (RN app/settings.tsx). Computed from the household session and
    /// backup's status, so a view reading it follows both.
    public var accountSettings: AccountSettingsContent {
        AccountSettingsContent(session: household.session, syncStatus: sync.status, config: config)
    }

    /// The privacy notice for this build and this phone (RN app/privacy.tsx).
    public var accountPrivacyParts: [AccountPrivacyPart] {
        AccountPrivacyContent.parts(paired: household.session != nil, config: config)
    }

    /// The join form (RN `JoinForm`), shared by Household and onboarding: pairs through
    /// ``household``, counts the raw local database for the import offer, invalidates through
    /// ``database``, suggests the device's own name, and captions the build's household origin.
    public func makeJoinForm(initialDraft: JoinDraft? = nil) -> JoinFormModel {
        let provider = repositoryProvider
        return JoinFormModel(
            household: household,
            joinPreferences: joinPreferences,
            localRepositories: { provider.localRepositories },
            invalidator: database,
            haptics: platform.haptics,
            householdOrigin: config.householdOrigin,
            deviceName: platform.deviceName(),
            initialDraft: initialDraft,
            telemetry: telemetry
        )
    }

    /// The Household screen once joined to `session` (RN `Paired`): the phone list, removing a
    /// phone, copying this phone's own inventory in (with the backup's copy of a missing photo),
    /// and leaving. Make one per session.
    public func makeHouseholdPairedModel(session: HouseholdSession) -> HouseholdPairedModel {
        let provider = repositoryProvider
        return HouseholdPairedModel(
            session: session,
            household: household,
            client: householdClient,
            importer: makeHouseholdImporter(for: session),
            joinPreferences: joinPreferences,
            localRepositories: { provider.localRepositories },
            invalidator: database,
            toasts: toasts,
            confirm: platform.confirm,
            haptics: platform.haptics,
            telemetry: telemetry
        )
    }

    /// The Backup screen's model over the app's ``sync``.
    public func makeBackupScreenModel() -> BackupScreenModel {
        BackupScreenModel(
            sync: sync,
            toasts: toasts,
            confirm: platform.confirm,
            haptics: platform.haptics,
            announce: platform.announce
        )
    }

    /// Onboarding's steps (RN app/onboarding.tsx). Finishing flips ``onboarding`` and so the gate.
    public func makeOnboardingFlow() -> OnboardingFlowModel {
        // The flow is the screen's, not the container's, so holding the container is no cycle.
        OnboardingFlowModel(
            onboarding: onboarding,
            household: household,
            makeJoinForm: { draft in self.makeJoinForm(initialDraft: draft) },
            telemetry: telemetry
        )
    }

    /// Whether this phone's own database holds anything beyond the seeded drop zone (03 B12),
    /// for hiding the Restore offer once something is added. False before the database is open.
    public func localInventoryHasUserRows() async throws -> Bool {
        guard let store = repositoryProvider.localRepositories?.store else { return false }
        return try await BackupService.hasUserRows(store)
    }
}
