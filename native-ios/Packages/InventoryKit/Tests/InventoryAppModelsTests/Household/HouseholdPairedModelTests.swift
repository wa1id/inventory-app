import Foundation
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage
import InventoryStrings
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

// RN has no tests for app/household.tsx; these pin the paired view's logic (04 §12.5-12.6):
// copying the phone's inventory in, removing a phone, leaving, and the phone list's states.

@MainActor
private struct PairedFixture {
    let household: HouseholdModelFixture
    let preferences: InMemoryPreferences
    let invalidations = SharedSeamsInvalidationCounter()
    let toasts = SharedSeamsToastRecorder()
    let confirm: SharedSeamsConfirmScript
    let haptics = SharedSeamsHapticRecorder()
    let telemetry = RecordingTelemetry()
    let local: LocalRepositories?
    let model: HouseholdPairedModel

    init(
        answers: [Bool] = [true],
        preferences: InMemoryPreferences = InMemoryPreferences(),
        local: LocalRepositories? = nil,
        _ handler: @escaping StubServer.Handler
    ) async throws {
        household = try HouseholdModelFixture(keychain: InMemoryKeychain([KeychainKey.householdSession: householdModelSession.jsonString]), handler)
        await household.household.load()
        self.preferences = preferences
        self.local = local
        confirm = SharedSeamsConfirmScript(answers: answers)
        let session = try #require(household.household.session)
        let client = household.household.client
        model = HouseholdPairedModel(
            session: session,
            household: household.household,
            client: client,
            importer: HouseholdImporter(session: session, client: client, photos: HouseholdModelFakePhotos(), telemetry: TelemetryReporter(sink: telemetry)),
            joinPreferences: HouseholdJoinPreferences(preferences: preferences),
            localRepositories: { local },
            invalidator: invalidations,
            toasts: toasts,
            confirm: confirm,
            haptics: haptics.player,
            telemetry: TelemetryReporter(sink: telemetry)
        )
    }

    var server: StubServer { household.server }
}

private func offerPreferences() -> InMemoryPreferences {
    InMemoryPreferences([PreferenceKey.householdImportOffer: #"{"spaces":2,"items":5}"#])
}

@MainActor
@Suite("HouseholdPairedModel: status and import offer")
struct HouseholdPairedOfferTests {
    @Test("the status card names this phone and its household; only an answer reads Connected")
    func statusCard() async throws {
        let fixture = try await PairedFixture { _ in .status(204) }
        #expect(fixture.model.heading == L10n.Household.thisPhoneIs(name: "Kitchen iPhone"))
        #expect(fixture.model.partOf == L10n.Household.partOf(household: "Home"))
        #expect(HouseholdPairedModel.connectionSummary(.online) == .init(value: L10n.Connection.connected, tone: .ink))
        for state in [ConnectionState.unsure, .offline, .revoked, .local] {
            #expect(HouseholdPairedModel.connectionSummary(state) == .init(value: L10n.Connection.reconnectingShort, tone: .signal))
        }
    }

    @Test("the offer is read when the view appears")
    func readsOffer() async throws {
        let fixture = try await PairedFixture(preferences: offerPreferences()) { _ in .status(204) }
        #expect(fixture.model.offer == nil)
        fixture.model.readImportOffer()
        #expect(fixture.model.offer == ImportOffer(spaces: 2, items: 5))
    }

    @Test("copying asks first (not destructive), copies the raw local database, clears the offer and says what went in")
    func copyIn() async throws {
        let local = try householdModelLocal()
        let space = try await local.spaces.create(CreateSpaceInput(name: "Garage", icon: "", color: ""))
        _ = try await local.containers.create(CreateContainerInput(spaceId: space.id, visualType: .box))
        let fixture = try await PairedFixture(preferences: offerPreferences(), local: local) { request in
            .json(200, #"{"ok":true,"spaces":2,"containers":2,"items":4,"photos":0}"#)
        }
        fixture.model.readImportOffer()
        await fixture.model.copyIn()

        #expect(fixture.confirm.asked == [ConfirmOptions(
            title: L10n.Household.importConfirmTitle, body: L10n.Household.importConfirmBody,
            confirmLabel: L10n.Household.importConfirm, destructive: false
        )])
        #expect(fixture.server.lastRequest?.line == "POST https://inventory.wystudio.be/v1/import")
        #expect(fixture.server.lastRequest?.header("authorization") == "Bearer \(householdModelSession.token)")
        #expect(fixture.model.offer == nil)
        #expect(fixture.preferences.values[PreferenceKey.householdImportOffer] == nil)
        #expect(fixture.invalidations.count == 1)
        #expect(fixture.haptics.played == [.success])
        #expect(fixture.toasts.messages == [L10n.Household.copied(items: 4, photos: 0)])
        #expect(!fixture.model.isImporting)
        #expect(fixture.telemetry.names == ["household_imported"])
    }

    @Test("a failed copy keeps the offer, says so in the read wording and logs household_import_failed")
    func copyInFails() async throws {
        let fixture = try await PairedFixture(preferences: offerPreferences(), local: try householdModelLocal()) { _ in
            .json(400, #"{"error":"UNIQUE constraint failed: tags.normalized_name"}"#)
        }
        fixture.model.readImportOffer()
        await fixture.model.copyIn()
        #expect(fixture.model.offer == ImportOffer(spaces: 2, items: 5))
        #expect(fixture.model.importFailure == describeError(HouseholdHttpError(status: 400, code: "x"), context: .read))
        #expect(fixture.model.importFailure?.kind == .server)
        #expect(fixture.haptics.played == [.error])
        #expect(fixture.telemetry.entries == [RecordingTelemetry.Entry(level: "error", name: "household_import_failed", payload: ["errorClass": .string("HouseholdHttpError")])])
        #expect(fixture.toasts.shown.isEmpty)
    }

    @Test("a cancelled confirm copies nothing; nothing happens before the database is ready")
    func copyInGuards() async throws {
        let cancelled = try await PairedFixture(answers: [false], local: try householdModelLocal()) { _ in .json(200, "{}") }
        await cancelled.model.copyIn()
        #expect(cancelled.server.requests.isEmpty)
        #expect(cancelled.confirm.asked.count == 1)

        let notReady = try await PairedFixture(local: nil) { _ in .json(200, "{}") }
        await notReady.model.copyIn()
        #expect(notReady.confirm.asked.isEmpty)
    }

    @Test("Not needed clears the offer for good")
    func notNeeded() async throws {
        let fixture = try await PairedFixture(preferences: offerPreferences()) { _ in .status(204) }
        fixture.model.readImportOffer()
        fixture.model.notNeeded()
        #expect(fixture.model.offer == nil)
        fixture.model.readImportOffer()
        #expect(fixture.model.offer == nil)
    }
}

@MainActor
@Suite("HouseholdPairedModel: phones and leaving")
struct HouseholdPairedPhonesTests {
    private let mine = HouseholdDevice(id: householdModelSession.deviceId, name: "Kitchen iPhone", createdAt: 2, lastSeenAt: 1_000)
    private let other = HouseholdDevice(id: "dev-2", name: "Anna’s iPhone", createdAt: 1, lastSeenAt: 1_000)

    @Test("the list query reads the phones with the session token, keyed on this phone")
    func listsDevices() async throws {
        let fixture = try await PairedFixture { _ in
            .json(200, #"{"devices":[{"id":"dev-2","name":"Anna’s iPhone","createdAt":1,"lastSeenAt":null}]}"#)
        }
        #expect(fixture.model.devicesQueryKey == "devices:\(householdModelSession.deviceId)")
        #expect(try await fixture.model.listDevices() == [HouseholdDevice(id: "dev-2", name: "Anna’s iPhone", createdAt: 1, lastSeenAt: nil)])
        #expect(fixture.server.lastRequest?.header("authorization") == "Bearer \(householdModelSession.token)")
    }

    @Test("removing asks first, revokes, logs device_removed, reloads the list and says so")
    func remove() async throws {
        let fixture = try await PairedFixture { _ in .status(204) }
        var reloads = 0
        await fixture.model.remove(other) { reloads += 1 }
        #expect(fixture.confirm.asked == [ConfirmOptions(
            title: L10n.Household.removeTitle(name: "Anna’s iPhone"), body: L10n.Household.removeBody,
            confirmLabel: L10n.Household.removeConfirm
        )])
        #expect(fixture.server.lastRequest?.line == "DELETE https://inventory.wystudio.be/v1/devices/dev-2")
        #expect(reloads == 1)
        #expect(fixture.telemetry.names == ["device_removed"])
        #expect(fixture.toasts.messages == [L10n.Household.removed(name: "Anna’s iPhone")])
        #expect(fixture.invalidations.count == 0)
        #expect(fixture.model.removingId == nil)
    }

    @Test("a phone already gone counts as removed")
    func removeGone() async throws {
        let fixture = try await PairedFixture { _ in .json(404, #"{"error":"not_found"}"#) }
        var reloads = 0
        await fixture.model.remove(other) { reloads += 1 }
        #expect(reloads == 1)
        #expect(fixture.model.removeFailure == nil)
    }

    @Test("a failed removal names the phone when offline, logs status and class, and can be put away")
    func removeFails() async throws {
        let offline = try await PairedFixture { _ in .failure(.notConnectedToInternet, delay: nil) }
        await offline.model.remove(other) {}
        let copy = try #require(offline.model.removeFailure)
        #expect(copy.kind == .offline)
        #expect(copy.title == L10n.Errors.Offline.title)
        #expect(copy.body == L10n.Household.removeOffline(name: "Anna’s iPhone"))
        #expect(offline.haptics.played == [.error])
        #expect(offline.telemetry.errors == [RecordingTelemetry.Entry(level: "error", name: "household_remove_failed", payload: [
            "statusCode": .int(0), "errorClass": .string("HouseholdHttpError"),
        ])])
        offline.model.dismissRemoveFailure()
        #expect(offline.model.removeFailure == nil)

        let failing = try await PairedFixture { _ in .json(500, #"{"error":"boom"}"#) }
        await failing.model.remove(other) {}
        #expect(failing.model.removeFailure == describeError(HouseholdHttpError(status: 500, code: "boom"), context: .delete))
    }

    @Test("one guard covers every write: a second action while a confirm is open does nothing")
    func sharedGuard() async throws {
        let fixture = try await PairedFixture(answers: [true, true], local: try householdModelLocal()) { _ in .status(204) }
        async let removing: Void = fixture.model.remove(other) {}
        async let leaving: Void = fixture.model.leave {}
        _ = await (removing, leaving)
        #expect(fixture.confirm.asked.count == 1)
    }

    @Test("leaving asks first, forgets the session, revokes in passing, clears the offer, logs, invalidates, leaves and says so")
    func leave() async throws {
        let fixture = try await PairedFixture(preferences: offerPreferences()) { _ in .status(204) }
        var steps: [String] = []
        fixture.household.household.addSessionObserver { steps.append($0 == nil ? "session gone" : "session") }
        await fixture.model.leave { steps.append("left screen") }

        #expect(fixture.confirm.asked.map(\.title) == [L10n.Household.leaveTitle])
        #expect(fixture.confirm.asked.first?.destructive == true)
        #expect(steps == ["session gone", "left screen"])
        #expect(fixture.household.household.session == nil)
        #expect(fixture.household.storedSession == nil)
        #expect(fixture.preferences.values[PreferenceKey.householdImportOffer] == nil)
        #expect(fixture.telemetry.names == ["household_left"])
        #expect(fixture.invalidations.count == 1)
        #expect(fixture.toasts.messages == [L10n.Household.left])
        #expect(fixture.model.isLeaving)
        await fixture.household.household.pendingRevoke?.value
        #expect(fixture.server.lastRequest?.line == "DELETE https://inventory.wystudio.be/v1/devices/\(householdModelSession.deviceId)")
    }

    @Test("a cancelled leave changes nothing")
    func leaveCancelled() async throws {
        let fixture = try await PairedFixture(answers: [false]) { _ in .status(204) }
        var left = false
        await fixture.model.leave { left = true }
        #expect(!left)
        #expect(fixture.household.household.session != nil)
        #expect(!fixture.model.isLeaving)
        // The guard was released.
        await fixture.model.remove(other) {}
        #expect(fixture.confirm.asked.count == 2)
    }

    @Test("the phone list: rows with this phone first, or why there are none", arguments: [true, false])
    func phoneList(online: Bool) {
        let connection: ConnectionState = online ? .online : .offline
        let rows = HouseholdPairedModel.phoneList(
            devices: [other, mine], loading: false, cause: nil, refreshFailed: false,
            connection: connection, thisDeviceId: mine.id, now: 61_000
        )
        guard case .rows(let phones, let refreshFailed) = rows else {
            Issue.record("expected rows, got \(rows)")
            return
        }
        #expect(!refreshFailed)
        #expect(phones.map(\.id) == [mine.id, other.id])
        #expect(phones[0].meta == L10n.Household.thisPhone)
        #expect(phones[0].isThisPhone)
        #expect(phones[0].removeAccessibilityLabel == nil)
        #expect(phones[1].meta == L10n.Household.lastUsed(ago: Format.ago(1_000, now: 61_000)))
        #expect(phones[1].accessibilityLabel == L10n.Household.phoneA11y(name: "Anna’s iPhone", meta: phones[1].meta))
        #expect(phones[1].removeAccessibilityLabel == L10n.Household.removeA11y(name: "Anna’s iPhone"))
    }

    @Test("without a list: the banner explains an outage, other failures get a banner with Try again, loading a skeleton")
    func phoneListWithoutData() {
        let offline = HouseholdHttpError(status: 0, code: "offline")
        func list(_ cause: (any Error)?, loading: Bool = false, connection: ConnectionState = .offline) -> HouseholdPhoneList {
            HouseholdPairedModel.phoneList(devices: nil, loading: loading, cause: cause, refreshFailed: false, connection: connection, thisDeviceId: "me", now: 0)
        }
        #expect(list(offline) == .offlineNote)
        #expect(list(offline, connection: .unsure) == .offlineNote)
        #expect(list(offline, connection: .online) == .failure(describeError(offline, context: .read)))
        #expect(list(HouseholdHttpError(status: 500, code: "x")) == .failure(describeError(HouseholdHttpError(status: 500, code: "x"), context: .read)))
        #expect(list(nil, loading: true) == .loading)
        #expect(list(nil) == .nothing)
    }

    @Test("a refresh that failed over a list shows the banner, unless the home server is out of reach")
    func phoneListRefreshFailed() {
        func refreshFailed(_ cause: any Error) -> Bool {
            let list = HouseholdPairedModel.phoneList(
                devices: [mine], loading: false, cause: cause, refreshFailed: true, connection: .online, thisDeviceId: mine.id, now: 0
            )
            guard case .rows(_, let banner) = list else { return false }
            return banner
        }
        #expect(refreshFailed(HouseholdHttpError(status: 500, code: "x")))
        #expect(!refreshFailed(HouseholdHttpError(status: 0, code: "timeout")))
    }
}
