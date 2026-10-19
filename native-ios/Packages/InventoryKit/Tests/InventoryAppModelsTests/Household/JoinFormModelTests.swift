import Foundation
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage
import InventoryStrings
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

// RN has no tests for src/ui/household/JoinForm.tsx; these pin 04 §12.3 and the import offer
// decided before pairing (04 §11.1).

private let validCode = "MMWKYM2H78ABCDEFGHJKMNPQRS"
private let pairAnswer = #"{"deviceId":"dev-9","token":"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd","origin":"https://inventory.wystudio.be","householdName":"Cabin","contractVersion":1}"#

@MainActor
private struct JoinFixture {
    let household: HouseholdModelFixture
    let preferences: InMemoryPreferences
    let invalidations = SharedSeamsInvalidationCounter()
    let haptics = SharedSeamsHapticRecorder()
    let telemetry = RecordingTelemetry()
    let local: LocalRepositories?
    let form: JoinFormModel

    init(
        preferences: InMemoryPreferences = InMemoryPreferences(),
        local: LocalRepositories? = nil,
        deviceName: String? = "iPhone",
        initialDraft: JoinDraft? = nil,
        _ handler: @escaping StubServer.Handler = { _ in .json(200, pairAnswer) }
    ) async throws {
        household = try HouseholdModelFixture(handler)
        await household.household.load()
        self.preferences = preferences
        self.local = local
        form = JoinFormModel(
            household: household.household,
            joinPreferences: HouseholdJoinPreferences(preferences: preferences),
            localRepositories: { local },
            invalidator: invalidations,
            haptics: haptics.player,
            householdOrigin: "https://inventory.wystudio.be/",
            deviceName: deviceName,
            initialDraft: initialDraft,
            telemetry: TelemetryReporter(sink: telemetry)
        )
    }
}

@MainActor
@Suite("JoinFormModel")
struct HouseholdJoinFormModelTests {
    @Test("starts from the draft or the phone's own name; the caption names the build's server")
    func initialState() async throws {
        let fresh = try await JoinFixture(deviceName: "  Anna’s iPhone ")
        #expect(fresh.form.code == "")
        #expect(fresh.form.name == "Anna’s iPhone")
        #expect(fresh.form.serverCaption == L10n.Household.server(host: "inventory.wystudio.be"))
        #expect(fresh.form.codeCounter == nil)

        let generic = try await JoinFixture(deviceName: "iPhone")
        #expect(generic.form.name == "")

        let restored = try await JoinFixture(initialDraft: JoinDraft(code: "MMWKY", name: "Kitchen"))
        #expect(restored.form.code == "MMWKY")
        #expect(restored.form.name == "Kitchen")
    }

    @Test("the code is kept normalised and shown in groups; editing it clears its error and the banner, editing the name only the name's")
    func editing() async throws {
        let fixture = try await JoinFixture { _ in .failure(.notConnectedToInternet, delay: nil) }
        var drafts: [JoinDraft] = []
        fixture.form.onDraftChange = { drafts.append($0) }
        fixture.form.updateCode(validCode)
        fixture.form.updateName("")
        _ = await fixture.form.join()
        #expect(fixture.form.errors == JoinErrors(name: L10n.Join.nameRequired))

        fixture.form.updateName("Kitchen")
        #expect(fixture.form.errors.isEmpty)
        _ = await fixture.form.join()
        #expect(fixture.form.failure == .offline)

        fixture.form.updateName("Kitchen 2")
        #expect(fixture.form.failure == .offline)
        fixture.form.updateCode("mmwky-m2h78 abcde-fghjk-mnpqr-s")
        #expect(fixture.form.failure == nil)
        #expect(fixture.form.code == validCode)
        #expect(fixture.form.formattedCode == "MMWKY-M2H78-ABCDE-FGHJK-MNPQR-S")
        #expect(fixture.form.codeCounter == L10n.Forms.codeCounter(count: 26, total: 26))
        #expect(drafts.last == JoinDraft(code: validCode, name: "Kitchen 2"))
        #expect(drafts.count == 5)

        fixture.form.updateCode("Il0")
        #expect(fixture.form.code == "110")
    }

    @Test("an invalid form says why under each field, plays the error haptic and sends nothing")
    func validation() async throws {
        let fixture = try await JoinFixture()
        fixture.form.updateCode("ABC")
        fixture.form.updateName("   ")
        #expect(await fixture.form.join() == nil)
        #expect(fixture.form.errors == JoinErrors(code: L10n.Join.wrongLength(count: 3), name: L10n.Join.nameRequired))
        #expect(fixture.haptics.played == [.error])
        #expect(fixture.household.server.requests.isEmpty)
        #expect(fixture.household.household.session == nil)
    }

    @Test("joining pairs with the trimmed name, marks joined before, invalidates and plays success")
    func joins() async throws {
        let fixture = try await JoinFixture()
        fixture.form.updateCode(validCode)
        fixture.form.updateName("  Kitchen iPhone ")
        let joined = await fixture.form.join()
        #expect(joined == HouseholdJoined(householdName: "Cabin", hasImportOffer: false))
        let request = try #require(fixture.household.server.requests.first)
        #expect(request.json == .object(["bootstrapSecret": .string(validCode), "deviceName": .string("Kitchen iPhone")]))
        #expect(fixture.household.household.session?.deviceName == "Kitchen iPhone")
        #expect(fixture.preferences.values[PreferenceKey.householdJoinedBefore] == "true")
        #expect(fixture.invalidations.count == 1)
        #expect(fixture.haptics.played == [.success])
        #expect(!fixture.form.isJoining)
        #expect(fixture.telemetry.entries.isEmpty)
    }

    @Test("a phone with its own inventory gets the offer, counted from the raw local database before pairing")
    func importOfferBeforePairing() async throws {
        let local = try householdModelLocal()
        let space = try await local.spaces.create(CreateSpaceInput(name: "Garage", icon: "", color: ""))
        let box = try await local.containers.create(CreateContainerInput(spaceId: space.id, visualType: .box))
        _ = try await local.items.create(ItemDraft(containerId: box.id, name: "Drill"))
        _ = try await local.items.create(ItemDraft(containerId: DropZone.containerId))
        let fixture = try await JoinFixture(local: local)
        fixture.form.updateCode(validCode)
        fixture.form.updateName("Kitchen")
        let joined = await fixture.form.join()
        #expect(joined?.hasImportOffer == true)
        // The drop-zone space is not counted; its items are.
        #expect(fixture.preferences.values[PreferenceKey.householdImportOffer] == #"{"spaces":1,"items":2}"#)
    }

    // A join whose task is cancelled still pairs (the request is never aborted), so the count
    // before it must not fail either: once paired, the offer can never be made again.
    @Test("a cancelled join still counts the phone's own inventory for the offer, then pairs")
    func cancelledJoinKeepsTheOffer() async throws {
        let local = try householdModelLocal()
        _ = try await local.spaces.create(CreateSpaceInput(name: "Garage", icon: "", color: ""))
        let fixture = try await JoinFixture(local: local)
        fixture.form.updateCode(validCode)
        fixture.form.updateName("Kitchen")
        let form = fixture.form
        let join = Task { await form.join() }
        join.cancel()
        let joined = await join.value
        #expect(joined == HouseholdJoined(householdName: "Cabin", hasImportOffer: true))
        #expect(fixture.preferences.values[PreferenceKey.householdImportOffer] == #"{"spaces":1,"items":0}"#)
        #expect(fixture.household.household.session?.deviceId == "dev-9")
    }

    @Test("an empty phone, a phone that joined before, and a database not ready get no offer")
    func noOffer() async throws {
        let empty = try await JoinFixture(local: try householdModelLocal())
        empty.form.updateCode(validCode)
        empty.form.updateName("Kitchen")
        #expect(await empty.form.join()?.hasImportOffer == false)

        let local = try householdModelLocal()
        _ = try await local.spaces.create(CreateSpaceInput(name: "Garage", icon: "", color: ""))
        let before = try await JoinFixture(preferences: InMemoryPreferences([PreferenceKey.householdJoinedBefore: "true"]), local: local)
        before.form.updateCode(validCode)
        before.form.updateName("Kitchen")
        #expect(await before.form.join()?.hasImportOffer == false)

        let notReady = try await JoinFixture(local: nil)
        notReady.form.updateCode(validCode)
        notReady.form.updateName("Kitchen")
        #expect(await notReady.form.join()?.hasImportOffer == false)
        #expect(notReady.preferences.values[PreferenceKey.householdJoinedBefore] == "true")
    }

    @Test("a refused code goes under the code field; telemetry has the outcome, status and class")
    func refused() async throws {
        let fixture = try await JoinFixture { _ in .json(401, #"{"error":"unauthorized"}"#) }
        fixture.form.updateCode(validCode)
        fixture.form.updateName("Kitchen")
        #expect(await fixture.form.join() == nil)
        #expect(fixture.form.errors == JoinErrors(code: L10n.Join.refused))
        #expect(fixture.form.failure == nil)
        #expect(fixture.form.name == "Kitchen")
        #expect(fixture.haptics.played == [.error])
        #expect(fixture.telemetry.entries == [RecordingTelemetry.Entry(level: "error", name: "household_join_failed", payload: [
            "outcome": .string("refused"), "statusCode": .int(401), "errorClass": .string("HouseholdHttpError"),
        ])])
        #expect(fixture.preferences.values[PreferenceKey.householdJoinedBefore] == nil)
    }

    @Test("no answer is the offline banner; anything else the plain one", arguments: [
        (StubReply.failure(.notConnectedToInternet, delay: nil), JoinFailure.offline, TelemetryValue.int(0)),
        (.text(530, "<html>"), .offline, .int(530)),
        (.json(500, #"{"error":"invalid_response"}"#), .other, .int(500)),
    ])
    func failures(reply: StubReply, expected: JoinFailure, status: TelemetryValue) async throws {
        let fixture = try await JoinFixture { _ in reply }
        fixture.form.updateCode(validCode)
        fixture.form.updateName("Kitchen")
        #expect(await fixture.form.join() == nil)
        #expect(fixture.form.failure == expected)
        #expect(fixture.form.errors.isEmpty)
        #expect(fixture.telemetry.entries.first?.payload["outcome"] == .string(expected.rawValue))
        #expect(fixture.telemetry.entries.first?.payload["statusCode"] == status)
    }

    @Test("a session the keychain cannot save is a plain failure with a null status")
    func keychainFailure() async throws {
        let fixture = try await JoinFixture()
        fixture.household.keychain.failNextWrite()
        fixture.form.updateCode(validCode)
        fixture.form.updateName("Kitchen")
        #expect(await fixture.form.join() == nil)
        #expect(fixture.form.failure == .other)
        #expect(fixture.telemetry.entries.first?.payload == [
            "outcome": .string("other"), "statusCode": .null, "errorClass": .string("KeychainError"),
        ])
    }

    @Test("a second press while joining does nothing: pairing twice would register the phone twice")
    func reentrancy() async throws {
        let fixture = try await JoinFixture { _ in .json(200, pairAnswer, delay: .milliseconds(200)) }
        fixture.form.updateCode(validCode)
        fixture.form.updateName("Kitchen")
        async let first = fixture.form.join()
        async let second = fixture.form.join()
        let results = await [first, second]
        #expect(results.compactMap { $0 }.count == 1)
        #expect(fixture.household.server.requests.count == 1)
    }
}
