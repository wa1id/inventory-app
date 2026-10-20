import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStrings
import Testing
@testable import InventoryAppModels

// RN has no tests for app/settings.tsx or app/privacy.tsx; these pin 06 §12-13. The rules they
// read (backupSummary, showBackupRow, serverHost) are ported with their owners
// (SyncModelTests, InventoryCoreTests).

private let accountSession = HouseholdSession(
    origin: "http://192.168.1.5:8788/",
    token: "token",
    deviceId: "dev-1",
    deviceName: "Kitchen iPhone",
    householdName: "Home"
)
private let accountStatusAccount = SyncAccount(id: "acc", recoveryCode: "CODE")
private let accountConfig = AppConfig(
    recognitionEndpoint: "https://recognition.example/v1/recognize",
    syncEndpoint: "https://sync.example",
    householdOrigin: "https://inventory.wystudio.be",
    environment: .preview,
    appVersion: "0.2.0"
)

@Suite("Settings (app/settings.tsx)")
struct AccountSettingsContentTests {
    @Test("the household row says who this phone joined as, or This phone only")
    func householdRow() {
        let joined = AccountSettingsContent(session: accountSession, syncStatus: .off, config: accountConfig)
        #expect(joined.householdValue == L10n.Settings.joinedAs(name: "Kitchen iPhone"))
        let alone = AccountSettingsContent(session: nil, syncStatus: .off, config: accountConfig)
        #expect(alone.householdValue == L10n.Settings.thisPhoneOnly)
    }

    @Test("a phone of its own always lists backup, with its state as the value", arguments: [
        (SyncStatus.off, L10n.Settings.BackupSummary.off),
        (.idle(account: accountStatusAccount, lastBackupAt: nil), L10n.Settings.BackupSummary.notYetRun),
        (.idle(account: accountStatusAccount, lastBackupAt: 1), L10n.Settings.BackupSummary.on),
        (.working(account: accountStatusAccount), L10n.Settings.BackupSummary.working),
    ])
    func backupRowAlone(status: SyncStatus, value: String) throws {
        let row = try #require(AccountSettingsContent(session: nil, syncStatus: status, config: accountConfig).backupRow)
        #expect(row == AccountSettingsContent.BackupRow(value: value, tone: .ink, opensScreen: true))
    }

    @Test("a joined phone lists backup only once it has a backup account (#48)")
    func backupRowJoined() {
        #expect(AccountSettingsContent(session: accountSession, syncStatus: .off, config: accountConfig).backupRow == nil)
        #expect(AccountSettingsContent(session: accountSession, syncStatus: .unavailable, config: accountConfig).backupRow == nil)
        #expect(AccountSettingsContent(
            session: accountSession, syncStatus: .idle(account: accountStatusAccount, lastBackupAt: 1), config: accountConfig
        ).backupRow != nil)
    }

    @Test("a failed backup needs attention, in signal; a build without the service is a static row")
    func backupRowToneAndStatic() throws {
        let failed = try #require(AccountSettingsContent(
            session: nil, syncStatus: .error(account: accountStatusAccount, reason: .offline), config: accountConfig
        ).backupRow)
        #expect(failed == AccountSettingsContent.BackupRow(value: L10n.Settings.BackupSummary.attention, tone: .signal, opensScreen: true))

        let unavailable = try #require(AccountSettingsContent(session: nil, syncStatus: .unavailable, config: AppConfig()).backupRow)
        #expect(unavailable == AccountSettingsContent.BackupRow(value: L10n.Settings.BackupSummary.notConfigured, tone: .ink, opensScreen: false))
    }

    @Test("technical details: environment, schema v7, suggestions and the server in use, in RN's order")
    func technicalFacts() {
        let joined = AccountSettingsContent(session: accountSession, syncStatus: .off, config: accountConfig)
        #expect(joined.version == "0.2.0")
        #expect(joined.technicalFacts == [
            .init(label: L10n.Settings.environment, value: "preview"),
            .init(label: L10n.Settings.schema, value: "v7"),
            .init(label: L10n.Settings.suggestions, value: L10n.Settings.suggestionsOn),
            .init(label: L10n.Settings.serverAddress, value: "192.168.1.5:8788"),
        ])

        // Not joined: the address this build would join; no recognition endpoint: not set up.
        let bare = AccountSettingsContent(session: nil, syncStatus: .unavailable, config: AppConfig())
        #expect(bare.version == AppConfig.defaultAppVersion)
        #expect(bare.technicalFacts.map(\.value) == ["development", "v7", L10n.Settings.suggestionsOff, "inventory.wystudio.be"])
    }
}

@Suite("Privacy (app/privacy.tsx)")
struct AccountPrivacyContentTests {
    @Test("a phone of its own, in a build with backup and suggestions")
    func local() {
        let parts = AccountPrivacyContent.parts(paired: false, syncConfigured: true, recognitionConfigured: true)
        typealias Copy = L10n.Privacy
        #expect(parts.map(\.title) == [
            Copy.whereTitle, Copy.backupTitle, Copy.cameraTitle, Copy.suggestionsTitle, Copy.diagnosticsTitle, Copy.offlineTitle,
        ])
        #expect(parts[0].paragraphs == [Copy.whereBody, Copy.backupOff])
        #expect(parts[1].paragraphs == [Copy.backupAccount, Copy.backupPassword, Copy.backupLocal])
        #expect(parts[2].paragraphs == [Copy.cameraUse, Copy.photosLocal, Copy.photosResized(maxDimension: 1400), Copy.photosDeleted])
        #expect(parts[3].paragraphs == [Copy.suggestionsSent, Copy.suggestionsPrivate])
        #expect(parts[4].paragraphs == [Copy.diagnosticsBody])
        #expect(parts[5].paragraphs == [Copy.offlineBody])
    }

    @Test("a joined phone: the household first, and nothing promised that a joined phone does not get")
    func paired() {
        let parts = AccountPrivacyContent.parts(paired: true, syncConfigured: true, recognitionConfigured: true)
        typealias Copy = L10n.Privacy
        #expect(parts.first == AccountPrivacyPart(title: Copy.householdTitle, paragraphs: [Copy.householdBody]))
        #expect(parts[1].paragraphs == [Copy.whereBodyPaired, Copy.backupOffPaired])
        #expect(parts[3].paragraphs[1] == Copy.photosPaired)
        #expect(parts.last?.paragraphs == [Copy.offlinePaired])
    }

    @Test("a build without a backup service or suggestions says so, and has no backup part", arguments: [false, true])
    func bareBuild(paired: Bool) {
        let parts = AccountPrivacyContent.parts(paired: paired, config: AppConfig())
        typealias Copy = L10n.Privacy
        #expect(!parts.map(\.title).contains(Copy.backupTitle))
        let whereLines = parts.first { $0.title == Copy.whereTitle }?.paragraphs
        #expect(whereLines?.last == (paired ? Copy.noBackupServicePaired : Copy.noBackupService))
        #expect(parts.first { $0.title == Copy.suggestionsTitle }?.paragraphs == [Copy.suggestionsOff])
    }

    @Test("photos are resized to the capture pipeline's long edge")
    func resizedEdge() {
        #expect(ImageScaling.maxImageDimension == 1400)
        let camera = AccountPrivacyContent.parts(paired: false, config: AppConfig()).first { $0.title == L10n.Privacy.cameraTitle }
        #expect(camera?.paragraphs.contains(L10n.Privacy.photosResized(maxDimension: 1400)) == true)
    }
}
