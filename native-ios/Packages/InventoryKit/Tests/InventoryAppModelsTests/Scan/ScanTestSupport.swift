import Foundation
import InventoryCore
import InventoryTestSupport
import Synchronization
import Testing
@testable import InventoryAppModels

/// A QR repository for the scan and label tests: scripted answers, optionally held until the test
/// lets them through.
final class ScanTestQr: QrRepository {
    private struct State {
        var outcomes: [String: Result<ScanOutcome, any Error>] = [:]
        var resolved: [String] = []
        var existing: [String: QrBinding] = [:]
        var getError: (any Error)?
        var bindError: (any Error)?
        var bound: [(token: String, containerId: String)] = []
        var lookups: [String] = []
    }

    private let state = Mutex(State())
    /// When set, every `resolveScan` waits for the test.
    let resolveLatch: ScanTestLatch?
    /// When set, every `getByContainer` waits for the test.
    let lookupLatch: ScanTestLatch?
    /// When set, every `bind` waits for the test.
    let bindLatch: ScanTestLatch?

    init(holdResolves: Bool = false, holdLookups: Bool = false, holdBinds: Bool = false) {
        resolveLatch = holdResolves ? ScanTestLatch() : nil
        lookupLatch = holdLookups ? ScanTestLatch() : nil
        bindLatch = holdBinds ? ScanTestLatch() : nil
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
        state.withLock { $0.bound.append((token, containerId)) }
        return QrBinding(id: "b1", token: token, containerId: containerId, createdAt: 1, updatedAt: 1)
    }

    func getByToken(_ token: String) async throws -> QrBinding? { nil }
    func createAndBind(_ containerId: String) async throws -> QrBinding { throw ScanTestError() }
    func unbind(_ containerId: String) async throws -> Bool { false }
}

/// Holds async calls until the test lets them through, oldest first.
actor ScanTestLatch {
    private var held: [CheckedContinuation<Void, Never>] = []
    private var arrivals = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func hold() async {
        await withCheckedContinuation { continuation in
            held.append(continuation)
            arrivals += 1
            let ready = waiters.filter { $0.count <= arrivals }
            waiters.removeAll { $0.count <= arrivals }
            for waiter in ready { waiter.continuation.resume() }
        }
    }

    func waitForArrivals(_ count: Int) async {
        if arrivals >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func release() {
        guard !held.isEmpty else {
            Issue.record("ScanTestLatch: nothing to release")
            return
        }
        held.removeFirst().resume()
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
