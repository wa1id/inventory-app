import XCTest

/// The account screens driven like a person: Settings and the screens it opens, joining and
/// leaving the household, removing a phone, turning backup on, the recovery-code checks, the
/// Restore offer, and onboarding. Each test launches the DEBUG demo on an account state
/// (`-demoArea account -demoState …`): memory only, with a fake home server and backup service.
@MainActor
final class AccountUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
    }

    private func launch(_ state: String, route: String? = nil) {
        var arguments = ["-demo", "YES", "-demoArea", "account", "-demoState", state]
        if let route { arguments += ["-demoRoute", route] }
        app.launchArguments = arguments
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func goBack() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// Scrolls the screen until `element` is hittable (a tall form at large text sizes).
    private func reveal(_ target: XCUIElement) {
        for _ in 0..<6 where !target.isHittable {
            app.swipeUp()
        }
    }

    // MARK: - Settings

    func testSettingsOpensHouseholdBackupAndPrivacy() throws {
        launch("backupOff", route: "settings")
        XCTAssertTrue(element("screen-settings").waitForExistence(timeout: 15))
        XCTAssertEqual(element("settings-household").label, "Household, This phone only")
        XCTAssertEqual(element("settings-backup").label, "Off-device backup, Off")

        element("settings-household").tap()
        XCTAssertTrue(element("screen-household").waitForExistence(timeout: 5))
        goBack()
        element("settings-backup").tap()
        XCTAssertTrue(element("screen-backup").waitForExistence(timeout: 5))
        goBack()
        element("settings-privacy").tap()
        XCTAssertTrue(element("screen-privacy").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Where your inventory lives"].exists)
        goBack()

        // Technical details expands in place; each fact reads "label, value" and keeps no
        // identifier of the row that opened it.
        XCTAssertFalse(app.staticTexts["Database schema"].exists)
        app.descendants(matching: .any).matching(identifier: "settings-technical").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Database schema"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["Database schema, v7"].exists)
        let factsWithRowIdentifier = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'settings-technical' AND label CONTAINS 'schema'"))
        XCTAssertEqual(factsWithRowIdentifier.count, 0)
        attachScreenshot("settings-technical")
    }

    func testHowItWorksReplaysOnboardingAndUsingThePhoneOnItsOwnEndsIt() throws {
        launch("backupOff", route: "settings")
        XCTAssertTrue(element("settings-replay").waitForExistence(timeout: 15))
        element("settings-replay").tap()

        XCTAssertTrue(element("screen-onboarding").waitForExistence(timeout: 5))
        XCTAssertTrue(element("onboarding-join").exists)
        element("onboarding-local").tap()

        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("screen-onboarding").exists)
    }

    // MARK: - Household

    func testJoiningPairsAndOffersToCopyThisPhonesInventory() throws {
        launch("unpaired", route: "household")
        let code = element("join-code")
        XCTAssertTrue(code.waitForExistence(timeout: 15))

        // No code says where it comes from, under the field, and sends nothing. (The name starts
        // as the device's own, so only the code is missing.)
        element("join-submit").tap()
        XCTAssertTrue(app.staticTexts["Type the household code. Whoever set up the home server has it."].waitForExistence(timeout: 5))

        // The name starts as the simulator's own, which is kept.
        code.tap()
        code.typeText("mmwky m2h78 abcde fghjk mnpqr s")
        element("join-submit").tap()

        // A phone with an inventory of its own stays to see the offer.
        let notNeeded = element("household-not-needed")
        XCTAssertTrue(notNeeded.waitForExistence(timeout: 10))
        XCTAssertTrue(element("household-import").exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'This phone is “'")).firstMatch.exists)
        attachScreenshot("joined-with-offer")
        notNeeded.tap()
        XCTAssertFalse(element("household-import").waitForExistence(timeout: 2))
    }

    func testRemovingAnotherPhoneThenLeavingTheHousehold() throws {
        launch("paired", route: "settings>household")
        let remove = element("device-remove-demo-anna")
        XCTAssertTrue(remove.waitForExistence(timeout: 15))
        XCTAssertEqual(remove.label, "Remove Anna’s iPhone")
        XCTAssertFalse(element("device-remove-demo-this-phone").exists)

        remove.tap()
        let confirmRemove = app.alerts.buttons["Remove"]
        XCTAssertTrue(confirmRemove.waitForExistence(timeout: 5))
        confirmRemove.tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 10))

        let leave = element("household-leave")
        reveal(leave)
        leave.tap()
        let confirmLeave = app.alerts.buttons["Leave"]
        XCTAssertTrue(confirmLeave.waitForExistence(timeout: 5))
        confirmLeave.tap()

        // Back on Settings, which now says this phone keeps its own inventory.
        XCTAssertTrue(element("screen-settings").waitForExistence(timeout: 5))
        XCTAssertFalse(element("screen-household").exists)
        XCTAssertEqual(element("settings-household").label, "Household, This phone only")
    }

    // MARK: - Backup

    func testTurningOnBackupShowsTheCodeOnceThenBackupIsOn() throws {
        launch("backupOff", route: "backup")
        let turnOn = element("backup-enable")
        XCTAssertTrue(turnOn.waitForExistence(timeout: 15))
        turnOn.tap()

        let codeBox = element("backup-code")
        XCTAssertTrue(codeBox.waitForExistence(timeout: 10))
        XCTAssertTrue(element("backup-share-code").exists)
        attachScreenshot("backup-code")
        element("backup-saved").tap()

        XCTAssertTrue(element("backup-now").waitForExistence(timeout: 5))
        XCTAssertTrue(element("backup-show-code").exists)
        XCTAssertFalse(codeBox.exists)
    }

    func testAMistypedRecoveryCodeIsSaidUnderTheFieldWithoutAsking() throws {
        launch("backupOff", route: "backup")
        let field = element("backup-code-input")
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        reveal(field)
        field.tap()
        field.typeText("89144-gj289")
        let restore = element("backup-restore")
        reveal(restore)
        restore.tap()

        XCTAssertTrue(app.staticTexts["That code is not complete. It is 26 characters, usually written in groups of five."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testTheRestoreOfferAsksThenBringsTheSavedCopyBack() throws {
        launch("backupRestoreOffer", route: "backup")
        let offer = element("backup-restore-offer")
        XCTAssertTrue(offer.waitForExistence(timeout: 20))
        offer.tap()

        let replace = app.alerts.buttons["Replace"]
        XCTAssertTrue(replace.waitForExistence(timeout: 5))
        replace.tap()

        XCTAssertTrue(offer.waitForNonExistence(timeout: 20))
        XCTAssertTrue(element("backup-now").exists)
    }

    func testAnUnreadableKeychainOffersTryAgainInsteadOfTurnOn() throws {
        launch("backupUnreadable", route: "backup")
        let retry = element("backup-unreadable-retry")
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        XCTAssertFalse(element("backup-enable").exists)
        XCTAssertFalse(element("backup-restore").exists)
        retry.tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
    }

    // MARK: - Onboarding

    func testOnboardingJoinKeepsWhatWasTypedThroughBack() throws {
        launch("onboarding")
        XCTAssertTrue(element("onboarding-join").waitForExistence(timeout: 15))
        element("onboarding-join").tap()

        let code = element("join-code")
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        code.tap()
        code.typeText("mmwkym2h78")
        element("onboarding-back").tap()

        XCTAssertTrue(element("onboarding-join").waitForExistence(timeout: 5))
        element("onboarding-join").tap()
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        XCTAssertEqual(code.value as? String, "MMWKY-M2H78")
    }

    func testJoiningFromOnboardingEndsOnYouAreInThenStart() throws {
        launch("onboarding")
        XCTAssertTrue(element("onboarding-join").waitForExistence(timeout: 15))
        element("onboarding-join").tap()
        let code = element("join-code")
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        code.tap()
        code.typeText("MMWKYM2H78ABCDEFGHJKMNPQRS")
        // (With the keyboard up, the bottom bar rises over the name field: the name starts as the
        // simulator's own and is kept.)
        attachScreenshot("onboarding-join-filled")
        element("join-submit").tap()

        let start = element("onboarding-start")
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["You are in"].exists)
        start.tap()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 5))
    }

    func testReplayingOnAJoinedPhoneOffersOnlyContinue() throws {
        launch("onboardingReplay")
        let proceed = element("onboarding-continue")
        XCTAssertTrue(proceed.waitForExistence(timeout: 15))
        XCTAssertFalse(element("onboarding-join").exists)
        XCTAssertFalse(element("onboarding-local").exists)
        proceed.tap()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 5))
    }
}
