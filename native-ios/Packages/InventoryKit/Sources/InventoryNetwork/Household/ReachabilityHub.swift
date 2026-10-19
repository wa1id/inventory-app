import Foundation
import Synchronization

/// What the last household request said about the connection: the home server
/// answered, could not be reached, or no longer accepts this phone's token
/// (RN `Reachability`).
public enum Reachability: String, Sendable, Hashable {
    case ok
    case offline
    case unauthorized

    /// RN `reachabilityOf(status, hadToken)`.
    ///
    /// Cloudflare answers 502 and 520–530 itself when the box behind the tunnel
    /// is down, so those mean "not reachable", not a server bug. A 401 means
    /// "removed" only on a request that carried a token: pairing has none, and a
    /// refused household code is not a revoked phone.
    public static func of(status: Int, hadToken: Bool) -> Reachability {
        if status == 502 || (520...530).contains(status) { return .offline }
        if status == 401 && hadToken { return .unauthorized }
        return .ok
    }
}

/// The reachability side channel (04 §3.3): every household request reports one
/// ``Reachability`` here, so the connection banner and the removed-phone layer
/// follow real traffic instead of polling.
///
/// Each ``updates()`` call returns a new stream. Reporting never waits for a
/// consumer: a stream buffers its newest ``bufferLimit`` values, so a slow or
/// stalled listener can neither block a request nor fail it (RN swallowed a
/// throwing listener for the same reason). A stream unsubscribes itself when its
/// consuming task is cancelled or the stream is released.
public final class ReachabilityHub: Sendable {
    /// Values a stream keeps for a consumer that has fallen behind; the oldest are dropped first.
    public static let bufferLimit = 128

    private let continuations = Mutex<[UUID: AsyncStream<Reachability>.Continuation]>([:])

    public init() {}

    /// A stream of every value reported from now on.
    public func updates() -> AsyncStream<Reachability> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Reachability>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.bufferLimit)
        )
        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { _ = $0.removeValue(forKey: id) }
        }
        continuations.withLock { $0[id] = continuation }
        return stream
    }

    /// Delivers `reachability` to every live stream without waiting for any of them.
    public func report(_ reachability: Reachability) {
        let targets = continuations.withLock { Array($0.values) }
        for continuation in targets {
            continuation.yield(reachability)
        }
    }

    /// Live streams, for tests.
    var subscriberCount: Int {
        continuations.withLock { $0.count }
    }
}
