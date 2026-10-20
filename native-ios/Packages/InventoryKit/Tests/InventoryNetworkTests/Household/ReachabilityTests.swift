import Foundation
import InventoryCore
import InventoryTestSupport
import Synchronization
import Testing
@testable import InventoryNetwork

// RN: src/services/household/__tests__/reachability.test.ts. RN's listeners were a
// global Set; here each client reports to the hub it was given, and listeners
// are AsyncStreams.

private let origin = "https://inventory.example"

/// Collects what a hub reports, from a stream opened before any request.
private final class Recorder: Sendable {
    private final class Storage: Sendable {
        let seen = Mutex<[Reachability]>([])
    }

    private let storage = Storage()
    private let listener: Task<Void, Never>

    init(_ hub: ReachabilityHub) {
        let updates = hub.updates()
        let storage = storage
        listener = Task {
            for await value in updates { storage.seen.withLock { $0.append(value) } }
        }
    }

    deinit { listener.cancel() }

    var values: [Reachability] { storage.seen.withLock { $0 } }

    func stop() { listener.cancel() }

    /// Waits until `count` values arrived (or `networkPatience` of real time passed: a loaded
    /// Mac can hold the listener's task back for seconds).
    func waitFor(_ count: Int) async -> [Reachability] {
        let deadline = ContinuousClock.now.advanced(by: networkPatience)
        while values.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return values
    }
}

private func client(_ server: StubServer, hub: ReachabilityHub, token: String? = "t") -> HouseholdClient {
    HouseholdClient(origin: origin, token: token, transport: server.transport, reachability: hub, telemetry: RecordingTelemetry().telemetry)
}

/// A token-carrying read that gets `status` back.
private func fetchWithToken(_ status: Int, hub: ReachabilityHub) async throws -> HTTPResponse {
    let server = StubServer(reply: .json(status, "{}"))
    return try await client(server, hub: hub).send(HouseholdRequest(path: "/v1/spaces"))
}

@Suite("household reachability")
struct ReachabilityTests {
    @Test("reports ok for any answer from the home server")
    func reportsOkForAnyAnswerFromTheHomeServer() async throws {
        let hub = ReachabilityHub()
        let recorder = Recorder(hub)
        _ = try await fetchWithToken(200, hub: hub)
        let missing = StubServer(reply: .json(404, "{}"))
        await #expect(throws: HouseholdHttpError(status: 404, code: "http_404")) {
            _ = try await client(missing, hub: hub).request(HouseholdRequest(path: "/v1/items/x"), as: IgnoredBody.self)
        }
        #expect(await recorder.waitFor(2) == [.ok, .ok])
    }

    @Test("reports unauthorized for a 401 on a request that carried a token")
    func reportsUnauthorizedForA401OnARequestThatCarriedAToken() async throws {
        let hub = ReachabilityHub()
        let recorder = Recorder(hub)
        _ = try await fetchWithToken(401, hub: hub)
        #expect(await recorder.waitFor(1) == [.unauthorized])
    }

    @Test("treats a refused household code while pairing as an answer, not a removed phone")
    func treatsARefusedHouseholdCodeWhilePairingAsAnAnswerNotARemovedPhone() async throws {
        let hub = ReachabilityHub()
        let recorder = Recorder(hub)
        let server = StubServer(reply: .json(401, #"{"error":"unauthorized"}"#))
        await #expect(throws: HouseholdHttpError(status: 401, code: "unauthorized")) {
            _ = try await client(server, hub: hub, token: "t").pair(bootstrapSecret: "nope", deviceName: "Pixel")
        }
        #expect(await recorder.waitFor(1) == [.ok])
    }

    @Test("reports offline when the request never gets an answer")
    func reportsOfflineWhenTheRequestNeverGetsAnAnswer() async throws {
        let hub = ReachabilityHub()
        let recorder = Recorder(hub)
        let server = StubServer(reply: .failure(.notConnectedToInternet, delay: nil))
        await #expect(throws: HouseholdHttpError(status: 0, code: "offline")) {
            _ = try await client(server, hub: hub).send(HouseholdRequest(path: "/v1/spaces"))
        }
        #expect(await recorder.waitFor(1) == [.offline])
    }

    @Test("reports offline when Cloudflare says the home box is down")
    func reportsOfflineWhenCloudflareSaysTheHomeBoxIsDown() async throws {
        let hub = ReachabilityHub()
        let recorder = Recorder(hub)
        _ = try await fetchWithToken(530, hub: hub)
        _ = try await fetchWithToken(502, hub: hub)
        _ = try await fetchWithToken(500, hub: hub)
        #expect(await recorder.waitFor(3) == [.offline, .offline, .ok])
    }

    @Test("stops reporting to a listener that unsubscribed")
    func stopsReportingToAListenerThatUnsubscribed() async throws {
        let hub = ReachabilityHub()
        let recorder = Recorder(hub)
        recorder.stop()
        await networkEventually("the listener unsubscribed") { hub.subscriberCount == 0 }
        #expect(hub.subscriberCount == 0)
        _ = try await fetchWithToken(200, hub: hub)
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.values.isEmpty)
    }

    @Test("never fails a request because a listener threw")
    func neverFailsARequestBecauseAListenerThrew() async throws {
        // Swift listeners cannot throw; the hazard here is a listener that never
        // reads. It must neither block the request nor starve the other listeners.
        let hub = ReachabilityHub()
        let stalled = hub.updates()
        let recorder = Recorder(hub)
        var responses: [Int] = []
        for _ in 0..<(ReachabilityHub.bufferLimit + 20) {
            responses.append(try await fetchWithToken(200, hub: hub).status)
        }
        #expect(responses.allSatisfy { $0 == 200 })
        let heard = await recorder.waitFor(ReachabilityHub.bufferLimit + 20)
        #expect(heard.count >= ReachabilityHub.bufferLimit)
        #expect(heard.allSatisfy { $0 == .ok })
        withExtendedLifetime(stalled) {}
    }

    // MARK: Native additions

    @Test("classifies statuses as RN reachabilityOf does", arguments: [
        (200, true, Reachability.ok), (204, true, .ok), (404, true, .ok), (409, true, .ok), (500, true, .ok),
        (503, true, .ok), (502, true, .offline), (520, true, .offline), (525, false, .offline), (530, true, .offline),
        (531, true, .ok), (519, true, .ok), (401, true, .unauthorized), (401, false, .ok), (403, true, .ok),
    ])
    func classifiesStatuses(status: Int, hadToken: Bool, expected: Reachability) {
        #expect(Reachability.of(status: status, hadToken: hadToken) == expected)
    }

    @Test("a stream released without being read unsubscribes itself")
    func releasedStreamUnsubscribes() async throws {
        let hub = ReachabilityHub()
        do {
            _ = hub.updates()
        }
        await networkEventually("the listener unsubscribed") { hub.subscriberCount == 0 }
        #expect(hub.subscriberCount == 0)
    }

    @Test("a stalled stream keeps only the newest values")
    func stalledStreamKeepsNewest() async {
        let hub = ReachabilityHub()
        let updates = hub.updates()
        for _ in 0..<ReachabilityHub.bufferLimit { hub.report(.ok) }
        hub.report(.unauthorized)
        var iterator = updates.makeAsyncIterator()
        var values: [Reachability] = []
        for _ in 0..<ReachabilityHub.bufferLimit {
            if let value = await iterator.next() { values.append(value) }
        }
        #expect(values.count == ReachabilityHub.bufferLimit)
        #expect(values.last == .unauthorized)
    }

    @Test("every live stream hears every report")
    func fanOut() async {
        let hub = ReachabilityHub()
        let first = hub.updates()
        let second = hub.updates()
        hub.report(.offline)
        hub.report(.ok)
        var a = first.makeAsyncIterator()
        var b = second.makeAsyncIterator()
        #expect(await [a.next(), a.next()] == [.offline, .ok])
        #expect(await [b.next(), b.next()] == [.offline, .ok])
    }
}
