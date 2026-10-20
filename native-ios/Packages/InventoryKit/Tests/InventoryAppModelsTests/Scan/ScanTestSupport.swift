import Foundation
import InventoryCore
import InventoryTestSupport
import Synchronization
import Testing
@testable import InventoryAppModels

/// A QR repository for the scan and label tests: scripted answers, optionally held until the test
/// lets them through. Writes (`bind`, `createAndBind`, `unbind`) change what `getByContainer`
/// answers afterwards, as the real repositories do.
final class ScanTestQr: QrRepository {
    private struct State {
        var outcomes: [String: Result<ScanOutcome, any Error>] = [:]
        var resolved: [String] = []
        var existing: [String: QrBinding] = [:]
        var getError: (any Error)?
        var bindError: (any Error)?
        var createError: (any Error)?
        var unbindError: (any Error)?
        var bound: [(token: String, containerId: String)] = []
        var created: [String] = []
        var unbound: [String] = []
        var lookups: [String] = []
        var madeCount = 0
    }

    private let state = Mutex(State())
    /// When set, every `resolveScan` waits for the test.
    let resolveLatch: ScanTestLatch?
    /// When set, every `getByContainer` waits for the test.
    let lookupLatch: ScanTestLatch?
    /// When set, every `bind` waits for the test.
    let bindLatch: ScanTestLatch?

    /// When set, every `createAndBind` and `unbind` waits for the test.
    let writeLatch: ScanTestLatch?

    init(holdResolves: Bool = false, holdLookups: Bool = false, holdBinds: Bool = false, holdWrites: Bool = false) {
        resolveLatch = holdResolves ? ScanTestLatch() : nil
        lookupLatch = holdLookups ? ScanTestLatch() : nil
        bindLatch = holdBinds ? ScanTestLatch() : nil
        writeLatch = holdWrites ? ScanTestLatch() : nil
    }

    func answer(_ raw: String, with outcome: Result<ScanOutcome, any Error>) {
        state.withLock { $0.outcomes[raw] = outcome }
    }

    func setExisting(_ binding: QrBinding?, for containerId: String) {
        state.withLock { $0.existing[containerId] = binding }
    }

    var getError: (any Error)? {
        get { state.withLock { $0.getError } }
        set { state.withLock { $0.getError = newValue } }
    }

    var bindError: (any Error)? {
        get { state.withLock { $0.bindError } }
        set { state.withLock { $0.bindError = newValue } }
    }

    var createError: (any Error)? {
        get { state.withLock { $0.createError } }
        set { state.withLock { $0.createError = newValue } }
    }

    var unbindError: (any Error)? {
        get { state.withLock { $0.unbindError } }
        set { state.withLock { $0.unbindError = newValue } }
    }

    /// The containers `createAndBind` made a label for, oldest first.
    var created: [String] { state.withLock { $0.created } }
    /// The containers `unbind` removed a label from, oldest first.
    var unbound: [String] { state.withLock { $0.unbound } }

    /// The token the `n`th `createAndBind` (from 1) writes: 32 hex digits of `n`.
    static func madeToken(_ n: Int) -> String {
        String(repeating: String(n % 10), count: 32)
    }

    var resolved: [String] { state.withLock { $0.resolved } }
    var bound: [(token: String, containerId: String)] { state.withLock { $0.bound } }
    var lookups: [String] { state.withLock { $0.lookups } }

    func resolveScan(_ raw: String) async throws -> ScanOutcome {
        let answer = state.withLock { state -> Result<ScanOutcome, any Error>? in
            state.resolved.append(raw)
            return state.outcomes[raw]
        }
        if let resolveLatch { await resolveLatch.hold() }
        guard let answer else {
            if let token = parseQrPayload(raw) { return .unknown(token: token) }
            return .invalid(raw: raw)
        }
        return try answer.get()
    }

    func getByContainer(_ containerId: String) async throws -> QrBinding? {
        let (binding, error) = state.withLock { state -> (QrBinding?, (any Error)?) in
            state.lookups.append(containerId)
            return (state.existing[containerId], state.getError)
        }
        if let lookupLatch { await lookupLatch.hold() }
        if let error { throw error }
        return binding
    }

    func bind(token: String, containerId: String) async throws -> QrBinding {
        let error = state.withLock { $0.bindError }
        if let bindLatch { await bindLatch.hold() }
        if let error { throw error }
        let binding = QrBinding(id: "b1", token: token, containerId: containerId, createdAt: 1, updatedAt: 1)
        state.withLock {
            $0.bound.append((token, containerId))
            $0.existing[containerId] = binding
        }
        return binding
    }

    func getByToken(_ token: String) async throws -> QrBinding? { nil }

    func createAndBind(_ containerId: String) async throws -> QrBinding {
        let error = state.withLock { $0.createError }
        if let writeLatch { await writeLatch.hold() }
        if let error { throw error }
        return state.withLock { state in
            state.madeCount += 1
            let binding = QrBinding(id: "made-\(state.madeCount)", token: Self.madeToken(state.madeCount), containerId: containerId, createdAt: 2, updatedAt: 2)
            state.created.append(containerId)
            state.existing[containerId] = binding
            return binding
        }
    }

    func unbind(_ containerId: String) async throws -> Bool {
        let error = state.withLock { $0.unbindError }
        if let writeLatch { await writeLatch.hold() }
        if let error { throw error }
        return state.withLock { state in
            state.unbound.append(containerId)
            return state.existing.removeValue(forKey: containerId) != nil
        }
    }
}

/// Holds async calls until the test lets them through, oldest first.
///
/// It never hangs the run. A call whose task is cancelled while held goes through at once, as a
/// real repository call ends, and keeps its place, so the test's later ``release()`` for it
/// still matches. ``waitForArrivals(_:within:sourceLocation:)`` gives up after ``patience`` of
/// real time and records an issue, so a model that never makes the call fails its test instead
/// of leaving it waiting for ever.
actor ScanTestLatch {
    /// How long a test waits for calls that should arrive at once. Real time, and generous: a
    /// loaded Mac can hold a task back for seconds.
    static let patience: Duration = .seconds(30)

    private enum Held {
        case waiting(id: Int, continuation: CheckedContinuation<Void, Never>)
        /// Let through because its task was cancelled; ``release()`` only drops it.
        case cancelled(id: Int)

        var id: Int {
            switch self {
            case .waiting(let id, _), .cancelled(let id): id
            }
        }
    }

    private struct Waiter {
        let id: Int
        let count: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var held: [Held] = []
    private var arrivals = 0
    private var nextId = 0
    private var waiters: [Waiter] = []

    func hold() async {
        nextId += 1
        let id = nextId
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    held.append(.cancelled(id: id))
                    arrive()
                    continuation.resume()
                } else {
                    held.append(.waiting(id: id, continuation: continuation))
                    arrive()
                }
            }
        } onCancel: {
            Task { await self.letThrough(id) }
        }
    }

    /// Waits until `count` calls have arrived in all; false, with an issue recorded (unless
    /// `reportsTimeout` is off), when they have not after `patience`.
    @discardableResult
    func waitForArrivals(
        _ count: Int,
        within patience: Duration = ScanTestLatch.patience,
        reportsTimeout: Bool = true,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        if arrivals >= count { return true }
        nextId += 1
        let id = nextId
        let watchdog = Task.detached {
            try await Task.sleep(for: patience)
            await self.timeOut(id)
        }
        let arrived = await withCheckedContinuation { continuation in
            waiters.append(Waiter(id: id, count: count, continuation: continuation))
        }
        watchdog.cancel()
        if !arrived && reportsTimeout {
            Issue.record("ScanTestLatch: expected \(count) held call(s) within \(patience), saw \(arrivals)", sourceLocation: sourceLocation)
        }
        return arrived
    }

    func release() {
        guard !held.isEmpty else {
            Issue.record("ScanTestLatch: nothing to release")
            return
        }
        if case .waiting(_, let continuation) = held.removeFirst() {
            continuation.resume()
        }
    }

    private func arrive() {
        arrivals += 1
        let ready = waiters.filter { $0.count <= arrivals }
        waiters.removeAll { $0.count <= arrivals }
        for waiter in ready { waiter.continuation.resume(returning: true) }
    }

    private func letThrough(_ id: Int) {
        guard let index = held.firstIndex(where: { $0.id == id }),
              case .waiting(_, let continuation) = held[index]
        else { return }
        held[index] = .cancelled(id: id)
        continuation.resume()
    }

    private func timeOut(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

struct ScanTestError: Error {}

/// Records where a scan model navigated, oldest first.
@MainActor
final class ScanTestNavigation<Destination: Sendable> {
    private(set) var destinations: [Destination] = []

    var navigate: @MainActor @Sendable (Destination) -> Void {
        { [self] destination in destinations.append(destination) }
    }
}

enum ScanTestData {
    static let token = String(repeating: "a", count: 32)
    static let otherToken = String(repeating: "b", count: 32)

    static func container(_ id: String = "c1", name: String? = "Tool chest", shortCode: String = "CAB-J92R") -> Container {
        Container(id: id, spaceId: "s1", name: name, visualType: .box, shortCode: shortCode, createdAt: 1, updatedAt: 1)
    }

    static func option(_ id: String = "c1", name: String? = "Tool chest", shortCode: String = "CAB-J92R") -> PlaceOption {
        PlaceOption(id: id, name: name, shortCode: shortCode, visualType: .box, spaceId: "s1", spaceName: "Garage", spaceColor: "#5B8DEF", spaceIcon: "🚗", itemCount: 0)
    }

    static func binding(_ token: String, containerId: String = "c1") -> QrBinding {
        QrBinding(id: "existing", token: token, containerId: containerId, createdAt: 1, updatedAt: 1)
    }

    /// A granted scan permission.
    @MainActor
    static func permission(_ status: CameraAuthorization = .authorized) -> CameraPermissionModel {
        CameraPermissionModel(purpose: .scan, readAuthorization: { status }, requestAccess: { true }, telemetry: TelemetryReporter(sink: RecordingTelemetry()))
    }
}

/// The latch itself: it holds, lets go in order, and never hangs a test.
@Suite("ScanTestLatch")
struct ScanTestLatchTests {
    @Test("holds calls until released, oldest first")
    func holdsInOrder() async {
        let latch = ScanTestLatch()
        let order = ScanTestOrder()
        let first = Task { await latch.hold(); order.append(1) }
        await latch.waitForArrivals(1)
        let second = Task { await latch.hold(); order.append(2) }
        await latch.waitForArrivals(2)
        #expect(order.values.isEmpty)
        await latch.release()
        await first.value
        await latch.release()
        await second.value
        #expect(order.values == [1, 2])
    }

    @Test("a held call whose task is cancelled goes through at once and keeps its place")
    func cancelledCallGoesThrough() async {
        let latch = ScanTestLatch()
        let held = Task { await latch.hold() }
        await latch.waitForArrivals(1)
        held.cancel()
        await held.value
        let next = Task { await latch.hold() }
        await latch.waitForArrivals(2)
        // The first release is the cancelled call's; the second lets the next one through.
        await latch.release()
        await latch.release()
        await next.value
    }

    @Test("waiting for a call that never comes gives up instead of hanging")
    func waitGivesUp() async {
        let latch = ScanTestLatch()
        let arrived = await latch.waitForArrivals(1, within: .milliseconds(50), reportsTimeout: false)
        #expect(!arrived)
    }
}

/// Integers appended from several tasks.
private final class ScanTestOrder: Sendable {
    private let state = Mutex<[Int]>([])

    var values: [Int] { state.withLock { $0 } }

    func append(_ value: Int) {
        state.withLock { $0.append(value) }
    }
}
