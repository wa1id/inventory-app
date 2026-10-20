import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage
import InventoryStrings
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

// RN has no tests for app/onboarding.tsx; these pin 06 §11.2. The completion store's own rules
// (status before storage, read failure → pending) are OnboardingModelTests.

/// An account demo container booted, with telemetry recorded.
@MainActor
private func accountOnboardingApp(_ scenario: AccountDemoScenario) async -> (AppContainer, RecordingTelemetry) {
    let app = AppContainer.accountDemo(scenario, platform: .silent())
    await app.boot.run()
    let telemetry = RecordingTelemetry()
    return (app, telemetry)
}

@MainActor
private func accountFlow(_ app: AppContainer, telemetry: RecordingTelemetry) -> OnboardingFlowModel {
    OnboardingFlowModel(
        onboarding: app.onboarding,
        household: app.household,
        makeJoinForm: { app.makeJoinForm(initialDraft: $0) },
        telemetry: TelemetryReporter(sink: telemetry)
    )
}

@MainActor
@Suite("Onboarding steps (app/onboarding.tsx)", .serialized, .timeLimit(.minutes(1)))
struct AccountOnboardingFlowTests {
    @Test("Welcome on a phone of its own offers Join and Use on its own; on a joined phone only Continue")
    func welcomeChoices() async {
        let (alone, aloneTelemetry) = await accountOnboardingApp(.onboarding)
        #expect(alone.onboarding.status == .pending)
        let flow = accountFlow(alone, telemetry: aloneTelemetry)
        #expect(flow.step == .welcome)
        #expect(!flow.offersOnlyContinue)

        let (joined, joinedTelemetry) = await accountOnboardingApp(.onboardingReplay)
        #expect(accountFlow(joined, telemetry: joinedTelemetry).offersOnlyContinue)
    }

    @Test("Use this phone on its own finishes as skipped at Welcome, and the gate flips")
    func useOnItsOwn() async {
        let (app, telemetry) = await accountOnboardingApp(.onboarding)
        let flow = accountFlow(app, telemetry: telemetry)

        flow.useOnItsOwn()

        #expect(app.onboarding.status == .completed)
        #expect(app.boot.phase == .main)
        #expect(app.preferences.storedString(forKey: PreferenceKey.onboardingCompleted) == "true")
        #expect(telemetry.events.map(\.name) == ["onboarding_finished"])
        #expect(telemetry.events.first?.payload == ["outcome": .string("skipped"), "step": .int(0)])
    }

    @Test("Continue on a joined phone finishes as completed at Welcome")
    func continueJoined() async {
        let (app, telemetry) = await accountOnboardingApp(.onboardingReplay)
        let flow = accountFlow(app, telemetry: telemetry)

        flow.continueJoined()

        #expect(app.onboarding.status == .completed)
        #expect(telemetry.events.first?.payload == ["outcome": .string("completed"), "step": .int(0)])
    }

    @Test("finishing twice completes and logs once")
    func finishesOnce() async {
        let (app, telemetry) = await accountOnboardingApp(.onboarding)
        let flow = accountFlow(app, telemetry: telemetry)

        flow.useOnItsOwn()
        flow.useOnItsOwn()
        flow.start()

        #expect(telemetry.events.count == 1)
    }

    @Test("what was typed survives Back to Welcome and Join again")
    func draftSurvivesBack() async throws {
        let (app, telemetry) = await accountOnboardingApp(.onboarding)
        let flow = accountFlow(app, telemetry: telemetry)

        flow.showJoin()
        let first = try #require(flow.joinForm)
        #expect(flow.step == .join)
        first.updateCode("mmwky-m2h78")
        first.updateName("Anna’s iPhone")
        flow.back()
        #expect(flow.step == .welcome)
        #expect(flow.joinForm == nil)

        flow.showJoin()
        let second = try #require(flow.joinForm)
        #expect(second !== first)
        #expect(second.code == "MMWKYM2H78")
        #expect(second.name == "Anna’s iPhone")
    }

    @Test("joining shows You are in, naming the household; Start finishes as completed at step 1")
    func joinsThenStarts() async throws {
        let (app, telemetry) = await accountOnboardingApp(.onboarding)
        let flow = accountFlow(app, telemetry: telemetry)
        flow.showJoin()
        let form = try #require(flow.joinForm)
        form.updateCode(AccountDemoServer.householdCode)
        form.updateName("Anna’s iPhone")

        await flow.join()

        #expect(flow.step == .joined)
        #expect(app.household.session?.deviceName == "Anna’s iPhone")
        #expect(flow.joinedBody == L10n.Onboarding.joinedBody(household: "Home"))
        // Still onboarding until Start.
        #expect(app.onboarding.status == .pending)
        flow.start()
        #expect(app.onboarding.status == .completed)
        #expect(telemetry.events.first?.payload == ["outcome": .string("completed"), "step": .int(1)])
    }

    @Test("a refused code stays on Join with the reason under the code")
    func refusedStays() async throws {
        let (app, telemetry) = await accountOnboardingApp(.onboarding)
        let flow = accountFlow(app, telemetry: telemetry)
        flow.showJoin()
        let form = try #require(flow.joinForm)
        form.updateCode("ZZZZZZZZZZZZZZZZZZZZZZZZZW")
        form.updateName("Anna’s iPhone")

        await flow.join()

        #expect(flow.step == .join)
        #expect(form.errors.code == L10n.Join.refused)
        #expect(app.household.session == nil)
    }

    @Test("You are in names the session's household when the join gave no name")
    func joinedBodyFallsBack() async {
        let (app, telemetry) = await accountOnboardingApp(.onboardingReplay)
        let flow = accountFlow(app, telemetry: telemetry)
        flow.joined(HouseholdJoined(householdName: "", hasImportOffer: false))
        #expect(flow.joinedBody == L10n.Onboarding.joinedBody(household: AccountDemoServer.session.householdName))
    }
}
