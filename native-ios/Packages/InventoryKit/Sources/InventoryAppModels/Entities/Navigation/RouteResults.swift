import Foundation

// RN: src/ui/routeResult.ts (06 §3.4, 07 §0.9). A screen opens another for a result and waits;
// the opened screen delivers a value once, or abandons the request when it closes without
// one. Natively the closure-free contract is kept, because several screens answer the same
// way (the camera, the new-container and new-space forms, the move sheet) and their callers
// rely on "deliver returns false when nobody waits" to fall back to their own behaviour.

/// A pending request for a `Value`, passed from the opener to the screen it opens
/// (RN's `request` route param). Opaque; only uniqueness matters.
public struct RouteRequest<Value: Sendable>: Hashable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

/// Results handed back between screens, each resolved exactly once (RN `routeResult`).
///
/// - ``open(_:_:)`` creates a request, hands it to `open` (which presents the screen) and
///   waits for its value, or nil when the screen closes without one.
/// - ``deliver(_:_:)`` answers a request once and returns true; false when nobody waits any
///   more (answered, abandoned, or a missing or unknown request).
/// - ``abandon(_:)`` answers nil; idempotent, so an answering screen calls it whenever it
///   closes, whether or not it delivered first.
///
/// Requests live in memory only, like RN's: lost on restart, when the opener is gone too.
@MainActor
public final class RouteResults {
    private var pending: [String: any RouteResultPending] = [:]
    private let makeId: () -> String

    /// - Parameter makeId: request ids; unique per call (UUIDs by default).
    public init(makeId: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.makeId = makeId
    }

    /// Opens a screen that will answer, and waits for the answer (RN `openForResult`).
    ///
    /// `open` receives the request to give the screen. If it throws, the request is dropped and
    /// the error is rethrown (RN rejects the returned promise).
    public func open<Value: Sendable>(
        _ type: Value.Type = Value.self,
        _ open: (RouteRequest<Value>) throws -> Void
    ) async throws -> Value? {
        let request = RouteRequest<Value>(id: makeId())
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value?, any Error>) in
            pending[request.id] = RouteResultSlot(continuation: continuation)
            do {
                try open(request)
            } catch {
                pending[request.id] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Answers `request` with `value` (RN `deliverResult`). False when nobody is waiting.
    @discardableResult
    public func deliver<Value: Sendable>(_ request: RouteRequest<Value>?, _ value: Value) -> Bool {
        guard let request, let slot = pending[request.id] as? RouteResultSlot<Value> else { return false }
        pending[request.id] = nil
        slot.continuation.resume(returning: value)
        return true
    }

    /// Closes `request` without an answer (RN `abandonResult`). Safe to call more than once,
    /// and with nil.
    public func abandon<Value: Sendable>(_ request: RouteRequest<Value>?) {
        guard let request, let slot = pending.removeValue(forKey: request.id) else { return }
        slot.resumeEmpty()
    }

    /// Whether `request` still waits for an answer.
    public func isPending<Value: Sendable>(_ request: RouteRequest<Value>?) -> Bool {
        guard let request else { return false }
        return pending[request.id] != nil
    }
}

/// A waiting request, whatever its value type.
@MainActor
private protocol RouteResultPending: AnyObject {
    func resumeEmpty()
}

@MainActor
private final class RouteResultSlot<Value: Sendable>: RouteResultPending {
    let continuation: CheckedContinuation<Value?, any Error>

    init(continuation: CheckedContinuation<Value?, any Error>) {
        self.continuation = continuation
    }

    func resumeEmpty() {
        continuation.resume(returning: nil)
    }
}
