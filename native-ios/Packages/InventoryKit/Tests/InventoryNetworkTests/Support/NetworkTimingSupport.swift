import Foundation
import InventoryCore
import InventoryTestSupport
import Synchronization
import Testing

// Deadlines in these tests run on a ManualClock, so they fire exactly when a test moves time and
// never because the test process was starved: Swift Testing runs the whole package at once, and
// on a Mac that also builds other checkouts a 100 ms timer has been seen to wake six seconds
// late. Real time is only a watchdog, `networkPatience`, generous enough never to fire on a
// loaded Mac, so a regression fails the test instead of hanging the run.

/// How long a test waits in real time for something that should happen at once.
let networkPatience: Duration = .seconds(60)

/// The task's result, or nil (with an issue recorded and the task cancelled) when it has not
/// finished within `patience` of real time.
func networkResult<Success: Sendable, Failure: Error>(
    of task: Task<Success, Failure>,
    within patience: Duration = networkPatience,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> Result<Success, Failure>? {
    let outcome: Result<Success, Failure>? = await withCheckedContinuation { continuation in
        let once = NetworkOnce(continuation)
        let watchdog = Task {
            // Cancelled once the task has answered: then it must not answer for it.
            do { try await Task.sleep(for: patience) } catch { return }
            once.resume(nil)
        }
        Task {
            let result = await task.result
            once.resume(result)
            watchdog.cancel()
        }
    }
    if outcome == nil {
        task.cancel()
        Issue.record("still running after \(patience) of real time", sourceLocation: sourceLocation)
    }
    return outcome
}

/// Waits, polling, until `condition` holds; false (with an issue recorded) after `patience`.
@discardableResult
func networkEventually(
    _ description: String,
    within patience: Duration = networkPatience,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: patience)
    while !(await condition()) {
        if ContinuousClock.now > deadline {
            Issue.record("never happened within \(patience): \(description)", sourceLocation: sourceLocation)
            return false
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}

extension StubServer {
    /// Waits until the server has received `count` requests (it then holds or answers them).
    @discardableResult
    func waitForRequests(_ count: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await networkEventually("\(count) request(s) reached the stub server", sourceLocation: sourceLocation) {
            self.requests.count >= count
        }
    }

    /// Waits until URLSession holds the status and headers of a response whose body has not
    /// arrived: the point a deadline must still cover. The reply must name its `Content-Type`:
    /// without one URLSession keeps the response back until it can sniff the body.
    @discardableResult
    func waitForHead(sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await networkEventually("the client received the status and headers", sourceLocation: sourceLocation) {
            await self.session.allTasks.contains { $0.response != nil }
        }
    }
}

/// Resumes a continuation once; later calls do nothing.
private final class NetworkOnce<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, Never>?>

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ value: Value) {
        continuation.withLock { stored in
            stored?.resume(returning: value)
            stored = nil
        }
    }
}
