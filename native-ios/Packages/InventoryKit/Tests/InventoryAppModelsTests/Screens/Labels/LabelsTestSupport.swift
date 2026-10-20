import Foundation
import InventoryCore
import InventoryTestSupport
import Synchronization
import Testing
@testable import InventoryAppModels

/// A container read for the QR label and sticker tests: a scripted answer per read, optionally
/// held until the test lets it through.
final class LabelsTestContainerRead: Sendable {
    private struct State {
        var answer: Result<ContainerWithCounts?, any Error> = .success(nil)
        var reads = 0
    }

    private let state = Mutex(State())
    /// When set, every read waits for the test.
    let latch: ScanTestLatch?

    init(_ container: ContainerWithCounts?, hold: Bool = false) {
        latch = hold ? ScanTestLatch() : nil
        state.withLock { $0.answer = .success(container) }
    }

    /// What the next reads answer.
    func answer(_ answer: Result<ContainerWithCounts?, any Error>) {
        state.withLock { $0.answer = answer }
    }

    /// How many reads started.
    var reads: Int { state.withLock { $0.reads } }

    func read(_ id: String) async throws -> ContainerWithCounts? {
        let answer = state.withLock { state -> Result<ContainerWithCounts?, any Error> in
            state.reads += 1
            return state.answer
        }
        if let latch { await latch.hold() }
        return try answer.get()
    }
}

enum LabelsTestData {
    static func container(_ id: String = "c1", name: String? = "Tool chest", shortCode: String = "CAB-J92R", qrToken: String? = nil) -> ContainerWithCounts {
        ContainerWithCounts(
            container: Container(id: id, spaceId: "s1", name: name, visualType: .cabinet, shortCode: shortCode, createdAt: 1, updatedAt: 1),
            itemCount: 2,
            qrToken: qrToken
        )
    }

    /// A read failure that is not offline (the refresh banner's case; `describeError` reads it as local).
    struct ReadFailure: Error {}

    /// The household did not answer.
    static var offline: any Error { HouseholdHttpError(status: 0, code: "offline") }

    /// The household no longer has it.
    static var notFound: any Error { HouseholdHttpError(status: 404, code: "not_found") }
}

/// Polls `condition` on the main actor, letting the model's tasks run, until it holds
/// (``ScanTestLatch/patience`` at most, in real time: a loaded Mac can hold the model's tasks
/// back for seconds, and the wait ends as soon as the condition holds). A cancelled test stops
/// waiting at once.
@MainActor
func labelsEventually(
    _ description: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: ScanTestLatch.patience)
    while !condition() {
        if Task.isCancelled {
            Issue.record("cancelled while waiting for: \(description)", sourceLocation: sourceLocation)
            return
        }
        if clock.now > deadline {
            Issue.record("never happened: \(description)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}
