import Foundation
import InventoryCore
import InventoryTestSupport
import Synchronization
import Testing

// InventoryTestSupport has no test target of its own; its helpers are checked here, in the
// fastest suite that links it.

/// Values appended from concurrent tasks.
private final class TestSupportLog<Item: Sendable>: Sendable {
    private let storage = Mutex<[Item]>([])
    var items: [Item] { storage.withLock { $0 } }
    func append(_ item: Item) { storage.withLock { $0.append(item) } }
}

/// The shape of the app models' timers: a main-actor Task asleep on the injected clock, cancelled
/// on a state change, re-armed from inside itself (ConnectionModel's reconnect, ToastCenter's life).
@MainActor
private final class TestSupportRetryModel {
    private(set) var attempts = 0
    private var timer: Task<Void, Never>?
    private let clock: any Clock<Duration>

    init(clock: any Clock<Duration>) {
        self.clock = clock
    }

    func arm() {
        timer?.cancel()
        timer = Task { [clock] in
            do { try await clock.sleep(for: .milliseconds(2500)) } catch { return }
            attempts += 1
            arm()
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

@Suite("ManualClock")
struct TestSupportManualClockTests {
    @Test("sleepers wake in deadline order, and only once their deadline is reached")
    func deadlineOrder() async throws {
        let clock = ManualClock()
        let woke = TestSupportLog<Int>()
        for seconds in [3, 1, 2] {
            Task {
                try await clock.sleep(for: .seconds(seconds))
                woke.append(seconds)
            }
        }
        try await clock.waitForSleepers(3)
        #expect(clock.nextDeadline == ManualClock.Instant(offset: .seconds(1)))

        await clock.advance(by: .milliseconds(1500))
        #expect(woke.items == [1])
        #expect(clock.now == ManualClock.Instant(offset: .milliseconds(1500)))
        #expect(clock.pendingSleeperCount == 2)

        await clock.advance(by: .seconds(10))
        #expect(woke.items == [1, 2, 3])
        #expect(clock.pendingSleeperCount == 0)
        #expect(clock.now == ManualClock.Instant(offset: .milliseconds(11_500)))
    }

    @Test("sleepers with the same deadline wake in the order they went to sleep")
    func ties() async throws {
        let clock = ManualClock()
        let woke = TestSupportLog<String>()
        for (index, name) in ["first", "second", "third"].enumerated() {
            Task {
                try await clock.sleep(for: .seconds(1))
                woke.append(name)
            }
            try await clock.waitForSleepers(index + 1)
        }
        await clock.advance(by: .seconds(1))
        #expect(woke.items == ["first", "second", "third"])
    }

    @Test("a loop that sleeps again inside the window fires as often as in real time")
    func repeatingTimer() async throws {
        let clock = ManualClock()
        let ticks = TestSupportLog<ManualClock.Instant>()
        let loop = Task {
            while true {
                try await clock.sleep(for: .milliseconds(2500))
                ticks.append(clock.now)
            }
        }
        defer { loop.cancel() }
        try await clock.waitForSleepers()
        await clock.advance(by: .seconds(10))
        #expect(ticks.items.map(\.offset) == [.milliseconds(2500), .seconds(5), .milliseconds(7500), .seconds(10)])
    }

    @Test("cancelling a sleeper wakes it with CancellationError and forgets it")
    func cancellation() async throws {
        let clock = ManualClock()
        let sleeper = Task { try await clock.sleep(for: .seconds(60)) }
        try await clock.waitForSleepers()
        sleeper.cancel()
        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(clock.pendingSleeperCount == 0)

        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await clock.sleep(for: .seconds(1))
        }
        await #expect(throws: CancellationError.self) { try await early.value }
        #expect(clock.pendingSleeperCount == 0)
    }

    @Test("a deadline already reached returns at once")
    func pastDeadline() async throws {
        let clock = ManualClock()
        await clock.advance(by: .seconds(5))
        try await clock.sleep(until: ManualClock.Instant(offset: .seconds(5)))
        try await clock.sleep(for: .zero)
        #expect(clock.pendingSleeperCount == 0)
    }

    @Test("waiting for sleepers that never come fails instead of hanging")
    func waitTimesOut() async {
        let clock = ManualClock()
        await #expect(throws: ManualClock.Timeout.self) {
            try await clock.waitForSleepers(1, timeout: .milliseconds(50))
        }
    }

    @Test("drives a main-actor model's re-arming timer, and a cancelled timer never fires")
    @MainActor
    func mainActorModel() async throws {
        let clock = ManualClock()
        let model = TestSupportRetryModel(clock: clock)
        model.arm()
        try await clock.waitForSleepers()
        await clock.advance(by: .milliseconds(2499))
        #expect(model.attempts == 0)
        await clock.advance(by: .milliseconds(1))
        #expect(model.attempts == 1)
        // Each firing arms a new Task, which has to be asleep again before the next deadline.
        await clock.advance(by: .seconds(5))
        #expect(model.attempts == 3)
        model.stop()
        #expect(clock.pendingSleeperCount == 0)
        await clock.advance(by: .seconds(10))
        #expect(model.attempts == 3)
    }

    @Test(
        "drives many re-arming main-actor timers at once, each firing on time (run in parallel for load)",
        arguments: 0..<24
    )
    @MainActor
    func manyMainActorModels(round: Int) async throws {
        let clock = ManualClock()
        let models = (0..<6).map { _ in TestSupportRetryModel(clock: clock) }
        models.forEach { $0.arm() }
        try await clock.waitForSleepers(models.count)
        await clock.advance(by: .milliseconds(2500))
        #expect(models.map(\.attempts) == Array(repeating: 1, count: models.count))
        await clock.advance(by: .milliseconds(7500))
        #expect(models.map(\.attempts) == Array(repeating: 4, count: models.count))
        models.forEach { $0.stop() }
        #expect(clock.pendingSleeperCount == 0)
    }

    @Test("works behind any Clock<Duration>")
    func existential() async throws {
        func sleep<C: Clock>(on clock: C, for duration: C.Duration) async throws {
            try await clock.sleep(for: duration)
        }
        let clock = ManualClock()
        let erased: any Clock<Duration> = clock
        let done = TestSupportLog<Bool>()
        Task {
            try await sleep(on: erased, for: .seconds(1))
            done.append(true)
        }
        try await clock.waitForSleepers()
        await clock.advance(by: .seconds(1))
        #expect(done.items == [true])
    }
}

@Suite("Temporary directories and defaults")
struct TestSupportTemporaryResourceTests {
    @Test("a temporary directory stands in for a container and goes away with its value")
    func directory() throws {
        var directory: TemporaryDirectory? = try TemporaryDirectory(prefix: "support")
        let root = try #require(directory?.root)
        let written = try #require(try directory?.write(Data("x".utf8), to: "Documents/item-photos/a.webp"))
        #expect(written.path == directory?.documents.appending(path: "item-photos/a.webp").path)
        #expect(directory?.exists("Documents/item-photos/a.webp") == true)
        #expect(directory?.contents(of: "Documents") == ["item-photos"])
        #expect(directory?.caches.path.hasSuffix("Library/Caches") == true)
        directory = nil
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("a temporary defaults suite is private and removed with its value")
    func defaults() throws {
        var suite: TemporaryDefaults? = try TemporaryDefaults()
        let name = try #require(suite?.name)
        suite?.defaults.set("1", forKey: "notice.unpaired.dismissed.v1")
        #expect(UserDefaults.standard.string(forKey: "notice.unpaired.dismissed.v1") == nil)
        suite = nil
        #expect(UserDefaults(suiteName: name)?.string(forKey: "notice.unpaired.dismissed.v1") == nil)
    }
}

@Suite("RecordingTelemetry")
struct TestSupportRecordingTelemetryTests {
    @Test("records events and errors in order, as given")
    func records() {
        let telemetry = RecordingTelemetry()
        let sink: any TelemetrySink = telemetry
        sink.event("photo_uploaded", ["byteSize": .int(10), "itemName": .string("Drill")])
        sink.error("household_fetch_failed", ["errorClass": .string("URLError")])
        #expect(telemetry.names == ["photo_uploaded", "household_fetch_failed"])
        #expect(telemetry.events == [.init(level: "event", name: "photo_uploaded", payload: ["byteSize": .int(10), "itemName": .string("Drill")])])
        #expect(telemetry.errors.map(\.payload) == [["errorClass": .string("URLError")]])
        telemetry.reset()
        #expect(telemetry.entries.isEmpty)
    }
}

@Suite("StubServer")
struct TestSupportStubServerTests {
    @Test("records each request and answers from its script")
    func scripted() async throws {
        let seen = TestSupportLog<String>()
        let server = StubServer { request in
            seen.append(request.method)
            return seen.items.count == 1 ? .json(201, #"{"id":"a"}"#, headers: ["X-Request": request.method]) : .status(404)
        }
        var request = URLRequest(url: try #require(URL(string: "https://stub.example/v1/items?q=a%20b")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"name":"Drill"}"#.utf8)
        let (data, response) = try await server.session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 201)
        #expect(http.value(forHTTPHeaderField: "x-request") == "POST")
        #expect(data.utf8Text == #"{"id":"a"}"#)

        let recorded = try #require(server.lastRequest)
        #expect(recorded.method == "POST")
        #expect(recorded.path == "/v1/items?q=a%20b")
        #expect(recorded.header("content-type") == "application/json")
        #expect(recorded.header(StubURLProtocol.routeHeader) == nil)
        #expect(recorded.jsonObject == ["name": .string("Drill")])

        let (_, second) = try await server.session.data(from: try #require(URL(string: "https://stub.example/v1/missing")))
        #expect((second as? HTTPURLResponse)?.statusCode == 404)
        #expect(server.requests.map(\.line) == ["POST https://stub.example/v1/items?q=a%20b", "GET https://stub.example/v1/missing"])
    }

    @Test("a scripted failure reaches the client as that URLError")
    func failure() async throws {
        let server = StubServer(reply: .failure(.notConnectedToInternet, delay: nil))
        let url = try #require(URL(string: "https://stub.example/"))
        let error = await #expect(throws: URLError.self) {
            _ = try await server.session.data(from: url)
        }
        #expect(error?.code == .notConnectedToInternet)
    }
}
