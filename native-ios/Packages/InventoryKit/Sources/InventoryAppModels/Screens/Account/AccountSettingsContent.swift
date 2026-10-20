import InventoryCore
import InventoryServices
import InventoryStorage
import InventoryStrings

// RN: app/settings.tsx (06 §12), with src/ui/household/status.ts (backupSummary, showBackupRow)
// and src/ui/household/join.ts (serverHost).

/// Everything Settings says, as values (RN `SettingsScreen`): who this phone joined as, the
/// backup row when it shows, the version and the technical facts. Nothing on Settings writes,
/// except "How it works", which replays onboarding.
public struct AccountSettingsContent: Sendable, Hashable {
    /// The backup row on "On this phone" (RN `backupSummary` + `showBackupRow`).
    public struct BackupRow: Sendable, Hashable {
        /// "Off", "On", "On, not yet run", "Backing up…", "Needs attention" or "Not set up".
        public var value: String
        /// "Needs attention" is drawn in the signal colour.
        public var tone: HouseholdStatus.Tone
        /// False in a build without a backup service: the row is a static fact, not a link
        /// (RN `onPress={status.state === 'unavailable' ? undefined : …}`).
        public var opensScreen: Bool
    }

    /// One line under "Technical details", read as "label, value".
    public struct Fact: Sendable, Hashable, Identifiable {
        public var label: String
        public var value: String
        public var id: String { label }
    }

    /// "Joined as “Kitchen iPhone”" or "This phone only". Always the name this phone joined as:
    /// an outage is said once, by the connection banner, not again on this row.
    public var householdValue: String
    /// Nil when the row is hidden: a joined phone that never set up backup (#48).
    public var backupRow: BackupRow?
    /// The app version (`CFBundleShortVersionString`, "0.0.0" without one).
    public var version: String
    /// Environment, database schema, photo suggestions and the home server address, in RN's order.
    public var technicalFacts: [Fact]

    /// - Parameters:
    ///   - session: the household session, nil while this phone keeps its own inventory.
    ///   - syncStatus: backup's state now.
    ///   - config: the build's configuration (environment, endpoints, origin, version).
    ///   - schemaVersion: the newest database schema this build knows (RN `LATEST_SCHEMA_VERSION`).
    public init(
        session: HouseholdSession?,
        syncStatus: SyncStatus,
        config: AppConfig,
        schemaVersion: Int = Migration.latestSchemaVersion
    ) {
        householdValue = session.map { L10n.Settings.joinedAs(name: $0.deviceName) } ?? L10n.Settings.thisPhoneOnly
        if syncStatus.showsSettingsRow(paired: session != nil) {
            let summary = syncStatus.settingsSummary
            backupRow = BackupRow(value: summary.value, tone: summary.tone, opensScreen: syncStatus.opensBackupScreen)
        } else {
            backupRow = nil
        }
        version = config.appVersion
        technicalFacts = [
            Fact(label: L10n.Settings.environment, value: config.environment.rawValue),
            Fact(label: L10n.Settings.schema, value: L10n.Settings.schemaValue(version: schemaVersion)),
            Fact(
                label: L10n.Settings.suggestions,
                value: config.recognitionEndpoint == nil ? L10n.Settings.suggestionsOff : L10n.Settings.suggestionsOn
            ),
            // The address in use when joined; the one this build would join otherwise.
            Fact(label: L10n.Settings.serverAddress, value: serverHost(session?.origin ?? config.householdOrigin)),
        ]
    }
}

/// One headed part of the privacy notice (RN `Part` in app/privacy.tsx).
public struct AccountPrivacyPart: Sendable, Hashable, Identifiable {
    public var title: String
    public var paragraphs: [String]
    public var id: String { title }
}

/// The privacy notice, following this build and this phone so it never promises something
/// untrue (RN app/privacy.tsx; 06 §13): a joined phone's inventory and photos live on the home
/// server, and a build without a backup service or photo suggestions says so.
public enum AccountPrivacyContent {
    /// The parts in RN's order.
    ///
    /// - Parameters:
    ///   - paired: this phone is part of a household.
    ///   - syncConfigured: the build has a backup service (`AppConfig.syncEndpoint`).
    ///   - recognitionConfigured: the build has photo suggestions (`AppConfig.recognitionEndpoint`).
    ///   - maxImageDimension: the long edge photos are resized to (RN `MAX_IMAGE_DIMENSION`).
    public static func parts(
        paired: Bool,
        syncConfigured: Bool,
        recognitionConfigured: Bool,
        maxImageDimension: Int = ImageScaling.maxImageDimension
    ) -> [AccountPrivacyPart] {
        typealias Copy = L10n.Privacy
        var parts: [AccountPrivacyPart] = []
        if paired {
            parts.append(AccountPrivacyPart(title: Copy.householdTitle, paragraphs: [Copy.householdBody]))
        }
        // "Nothing is uploaded" is not true of a joined phone.
        let backupLine = syncConfigured
            ? (paired ? Copy.backupOffPaired : Copy.backupOff)
            : (paired ? Copy.noBackupServicePaired : Copy.noBackupService)
        parts.append(AccountPrivacyPart(
            title: Copy.whereTitle,
            paragraphs: [paired ? Copy.whereBodyPaired : Copy.whereBody, backupLine]
        ))
        if syncConfigured {
            parts.append(AccountPrivacyPart(
                title: Copy.backupTitle,
                paragraphs: [Copy.backupAccount, Copy.backupPassword, Copy.backupLocal]
            ))
        }
        parts.append(AccountPrivacyPart(
            title: Copy.cameraTitle,
            paragraphs: [
                Copy.cameraUse,
                paired ? Copy.photosPaired : Copy.photosLocal,
                Copy.photosResized(maxDimension: maxImageDimension),
                Copy.photosDeleted,
            ]
        ))
        parts.append(AccountPrivacyPart(
            title: Copy.suggestionsTitle,
            paragraphs: recognitionConfigured ? [Copy.suggestionsSent, Copy.suggestionsPrivate] : [Copy.suggestionsOff]
        ))
        parts.append(AccountPrivacyPart(title: Copy.diagnosticsTitle, paragraphs: [Copy.diagnosticsBody]))
        parts.append(AccountPrivacyPart(title: Copy.offlineTitle, paragraphs: [paired ? Copy.offlinePaired : Copy.offlineBody]))
        return parts
    }

    /// ``parts(paired:syncConfigured:recognitionConfigured:maxImageDimension:)`` for this build.
    public static func parts(paired: Bool, config: AppConfig) -> [AccountPrivacyPart] {
        parts(paired: paired, syncConfigured: config.syncEndpoint != nil, recognitionConfigured: config.recognitionEndpoint != nil)
    }
}
