import Foundation
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStorage
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

// RN has no tests for HouseholdProvider or session.ts; these pin 04 §5 and 09 §4.2: the session
// read on launch (the Expo build's item included), the protected-data gate, pairing and leaving.

/// `JSON.stringify(session)` as the Expo build wrote it under `household.session.v1`.
private let expoSessionJSON = #"{"origin":"https://inventory.wystudio.be","token":"abababababababababababababababababababababababababababababababab","deviceId":"11111111-2222-4333-8444-555555555555","deviceName":"Kitchen iPhone","householdName":"Home"}"#

@MainActor
@Suite("HouseholdModel: load")
struct HouseholdModelLoadTests {
    @Test("a phone paired by the Expo build stays paired")
    func expoPairedPhoneStaysPaired() async throws {
        let fixture = try HouseholdModelFixture(keychain: InMemoryKeychain([KeychainKey.householdSession: expoSessionJSON])) { request in
            .json(200, #"{"spaces":[]}"#)
        }
        #expect(!fixture.household.ready)
        await fixture.household.load()
        #expect(fixture.household.ready)
        #expect(fixture.household.session == householdModelSession)

        // Its requests go to the stored origin with the stored token.
        let repos = try #require(fixture.household.remoteRepositories)
        _ = try await repos.spaces.listWithCounts()
        let request = try #require(fixture.server.lastRequest)
        #expect(request.line == "GET https://inventory.wystudio.be/v1/spaces")
        #expect(request.header("authorization") == "Bearer \(householdModelSession.token)")
        // Nothing was rewritten: an RN build installed over this one still reads the same item.
        #expect(fixture.storedSession == expoSessionJSON)
    }

    @Test("missing names read as This phone and Home; missing ids or bad JSON read as not joined, and the item stays")
    func sessionRules() async throws {
        let named = try HouseholdModelFixture(keychain: InMemoryKeychain([KeychainKey.householdSession: #"{"origin":"o","token":"t","deviceId":"d","deviceName":5}"#]))
        await named.household.load()
        #expect(named.household.session == HouseholdSession(origin: "o", token: "t", deviceId: "d", deviceName: "This phone", householdName: "Home"))

        for stored in [#"{"origin":"o","token":"t"}"#, "{nope", ""] {
            let fixture = try HouseholdModelFixture(keychain: InMemoryKeychain([KeychainKey.householdSession: stored]))
            await fixture.household.load()
            #expect(fixture.household.ready)
            #expect(fixture.household.session == nil)
            #expect(fixture.storedSession == stored)
        }
    }

    @Test("an unpaired phone loads as ready with no session or repositories")
    func unpaired() async throws {
        let fixture = try HouseholdModelFixture()
        await fixture.household.load()
        #expect(fixture.household.ready)
        #expect(fixture.household.session == nil)
        #expect(fixture.household.remoteRepositories == nil)
        #expect(fixture.household.sessionClient == nil)
    }

    @Test("nothing is read, and the phone is neither paired nor unpaired, until protected data is available")
    func waitsForProtectedData() async throws {
        let protectedData = HouseholdTestProtectedData(available: false)
        let fixture = try HouseholdModelFixture(keychain: InMemoryKeychain([KeychainKey.householdSession: expoSessionJSON]), protectedData: protectedData)
        let load = Task { await fixture.household.load() }
        #expect(await householdWaitUntil { protectedData.waiterCount == 1 })
        #expect(!fixture.household.ready)
        #expect(fixture.household.session == nil)

        protectedData.makeAvailable()
        await load.value
        #expect(fixture.household.ready)
        #expect(fixture.household.session == householdModelSession)
    }

    @Test("a read refused while protected data is available reads as not joined, as in RN")
    func refusedReadIsUnpaired() async throws {
        let keychain = InMemoryKeychain([KeychainKey.householdSession: expoSessionJSON])
        keychain.failNextRead()
        let fixture = try HouseholdModelFixture(keychain: keychain)
        await fixture.household.load()
        #expect(fixture.household.ready)
        #expect(fixture.household.session == nil)
        #expect(fixture.storedSession == expoSessionJSON)
    }

    @Test("a read refused because the device locked again waits for the next unlock and reads again")
    func lockedAgainWaits() async throws {
        let keychain = InMemoryKeychain([KeychainKey.householdSession: expoSessionJSON])
        keychain.failNextRead()
        let protectedData = HouseholdTestProtectedData()
        protectedData.lockOnNextCheck = true
        let fixture = try HouseholdModelFixture(keychain: keychain, protectedData: protectedData)
        let load = Task { await fixture.household.load() }
        #expect(await householdWaitUntil { protectedData.waiterCount == 1 })
        #expect(!fixture.household.ready)

        protectedData.makeAvailable()
        await load.value
        #expect(fixture.household.session == householdModelSession)
    }

    @Test("loading twice reads once and both callers see the result")
    func loadOnce() async throws {
        let fixture = try HouseholdModelFixture(keychain: InMemoryKeychain([KeychainKey.householdSession: expoSessionJSON]))
        async let first: Void = fixture.household.load()
        async let second: Void = fixture.household.load()
        _ = await (first, second)
        #expect(fixture.household.session == householdModelSession)
        fixture.keychain.delete(forKey: KeychainKey.householdSession)
        await fixture.household.load()
        #expect(fixture.household.session == householdModelSession)
    }
}

@MainActor
@Suite("HouseholdModel: pair and disconnect")
struct HouseholdModelPairTests {
    private nonisolated static let pairAnswer = #"{"deviceId":"dev-9","token":"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd","origin":"https://box.example/","householdName":"Home","contractVersion":1}"#

    @Test("pairing posts the code to the build's origin, saves the session as RN wrote it and switches to it")
    func pairs() async throws {
        let fixture = try HouseholdModelFixture { request in
            request.path == "/v1/pair" ? .json(200, Self.pairAnswer) : .json(200, #"{"spaces":[]}"#)
        }
        await fixture.household.load()
        var seen: [HouseholdSession?] = []
        fixture.household.addSessionObserver { seen.append($0) }

        try await fixture.household.pair(bootstrapSecret: "MMWKYM2H78ABCDEFGHJKMNPQRS", deviceName: "  Anna’s iPhone ")

        let pairRequest = try #require(fixture.server.requests.first)
        #expect(pairRequest.line == "POST https://inventory.wystudio.be/v1/pair")
        #expect(pairRequest.header("authorization") == nil)
        #expect(pairRequest.json == .object(["bootstrapSecret": .string("MMWKYM2H78ABCDEFGHJKMNPQRS"), "deviceName": .string("  Anna’s iPhone ")]))
        let expected = HouseholdSession(
            origin: "https://box.example", token: String(repeating: "cd", count: 32), deviceId: "dev-9",
            deviceName: "Anna’s iPhone", householdName: "Home"
        )
        #expect(fixture.household.session == expected)
        #expect(seen == [expected])
        #expect(fixture.storedSession == #"{"origin":"https://box.example","token":"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd","deviceId":"dev-9","deviceName":"Anna’s iPhone","householdName":"Home"}"#)

        // From now on requests go to the origin the server answered with.
        _ = try await fixture.household.remoteRepositories?.spaces.listWithCounts()
        #expect(fixture.server.lastRequest?.line == "GET https://box.example/v1/spaces")
    }

    @Test("a refused code throws the 401 and changes nothing")
    func refused() async throws {
        let fixture = try HouseholdModelFixture { _ in .json(401, #"{"error":"unauthorized"}"#) }
        await fixture.household.load()
        await #expect(throws: HouseholdHttpError(status: 401, code: "unauthorized")) {
            try await fixture.household.pair(bootstrapSecret: "nope", deviceName: "Pixel")
        }
        #expect(fixture.household.session == nil)
        #expect(fixture.storedSession == nil)
    }

    // RN never cancelled a request: an aborted pairing could leave a device row this phone has no
    // token for, and the next attempt would register the phone again.
    @Test("a join screen going away does not abort the pairing: the phone is paired and saved, once")
    func cancelledCallerStillPairs() async throws {
        let fixture = try HouseholdModelFixture { _ in .json(200, Self.pairAnswer, delay: .milliseconds(300)) }
        await fixture.household.load()
        let household = fixture.household
        let join = Task { try await household.pair(bootstrapSecret: "code", deviceName: "Pixel") }
        #expect(await householdWaitUntil { fixture.server.requests.count == 1 })
        join.cancel()
        try await join.value
        #expect(fixture.household.session?.deviceId == "dev-9")
        #expect(fixture.storedSession?.contains(#""deviceId":"dev-9""#) == true)
        #expect(fixture.server.requests.count == 1)
    }

    @Test("a session the keychain refuses to save fails the join and stays unpaired")
    func saveFailure() async throws {
        let keychain = InMemoryKeychain()
        let fixture = try HouseholdModelFixture(keychain: keychain) { _ in .json(200, Self.pairAnswer) }
        await fixture.household.load()
        keychain.failNextWrite()
        await #expect(throws: InMemoryKeychain.simulatedFailure) {
            try await fixture.household.pair(bootstrapSecret: "code", deviceName: "Pixel")
        }
        #expect(fixture.household.session == nil)
    }

    @Test("leaving forgets the session at once, then tells the home server with the old token, 5 s, errors ignored")
    func disconnectRevokes() async throws {
        let fixture = try HouseholdModelFixture(keychain: InMemoryKeychain([KeychainKey.householdSession: expoSessionJSON])) { _ in .status(204) }
        await fixture.household.load()
        var seen: [HouseholdSession?] = []
        fixture.household.addSessionObserver { seen.append($0) }

        fixture.household.disconnect()
        #expect(fixture.household.session == nil)
        #expect(fixture.storedSession == nil)
        #expect(seen == [nil])
        await fixture.household.pendingRevoke?.value
        let request = try #require(fixture.server.lastRequest)
        #expect(request.line == "DELETE https://inventory.wystudio.be/v1/devices/11111111-2222-4333-8444-555555555555")
        #expect(request.header("authorization") == "Bearer \(householdModelSession.token)")
    }

    @Test("leaving offline is just as instant; the removed-phone layer forgets without telling the server")
    func disconnectOfflineAndRevoked() async throws {
        let offline = try HouseholdModelFixture(keychain: InMemoryKeychain([KeychainKey.householdSession: expoSessionJSON])) { _ in
            .failure(.notConnectedToInternet, delay: nil)
        }
        await offline.household.load()
        offline.household.disconnect()
        #expect(offline.household.session == nil)
        await offline.household.pendingRevoke?.value
        #expect(offline.server.requests.count == 1)

        let revoked = try HouseholdModelFixture(keychain: InMemoryKeychain([KeychainKey.householdSession: expoSessionJSON])) { _ in .status(204) }
        await revoked.household.load()
        revoked.household.disconnect(revokeDevice: false)
        #expect(revoked.household.session == nil)
        #expect(revoked.household.pendingRevoke == nil)
        #expect(revoked.server.requests.isEmpty)
    }

    @Test("observers hear each change once, in order, and can stop listening")
    func observers() async throws {
        let fixture = try HouseholdModelFixture(keychain: InMemoryKeychain([KeychainKey.householdSession: expoSessionJSON])) { _ in .status(204) }
        var first: [String?] = []
        var second: [String?] = []
        let token = fixture.household.addSessionObserver { first.append($0?.deviceId) }
        fixture.household.addSessionObserver { second.append($0?.deviceId) }
        await fixture.household.load()
        fixture.household.removeSessionObserver(token)
        fixture.household.disconnect(revokeDevice: false)
        fixture.household.disconnect(revokeDevice: false)
        #expect(first == [householdModelSession.deviceId])
        #expect(second == [householdModelSession.deviceId, nil])
    }

    @Test("a slow keychain load never overwrites a pairing that finished first")
    func loadDoesNotOverwritePairing() async throws {
        let protectedData = HouseholdTestProtectedData(available: false)
        let fixture = try HouseholdModelFixture(protectedData: protectedData) { _ in .json(200, Self.pairAnswer) }
        let load = Task { await fixture.household.load() }
        #expect(await householdWaitUntil { protectedData.waiterCount == 1 })
        try await fixture.household.pair(bootstrapSecret: "code", deviceName: "Pixel")
        fixture.keychain.delete(forKey: KeychainKey.householdSession)
        protectedData.makeAvailable()
        await load.value
        #expect(fixture.household.ready)
        #expect(fixture.household.session?.deviceId == "dev-9")
    }
}
