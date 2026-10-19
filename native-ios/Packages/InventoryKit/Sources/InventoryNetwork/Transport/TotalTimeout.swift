import Foundation

/// The client's own wall-clock deadline fired before the exchange finished.
///
/// Distinct from `CancellationError` so a caller's cancellation (a view going
/// away) is never mistaken for a timeout.
public struct DeadlineExceeded: Error, Sendable, Equatable {
    public init() {}
}

/// Runs `operation` under a total wall-clock deadline: request upload, server
/// time and the full response body all count against it (D-7, 09 §8.4).
///
/// RN arms an `AbortController` timer before the request and clears it only
/// once `fetch` has resolved, which on device is after the whole body arrived.
/// `URLRequest.timeoutInterval` is an idle timeout and cannot express that, so
/// the operation races `clock.sleep(for: timeout)` in a task group and the loser
/// is cancelled. When the clock wins this throws ``DeadlineExceeded``; when the
/// calling task is cancelled, whichever child notices first decides the error
/// (`CancellationError` or `URLError(.cancelled)`).
public func withTotalTimeout<T: Sendable>(
    _ timeout: Duration,
    clock: any Clock<Duration> = ContinuousClock(),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await sleep(on: clock, for: timeout)
            throw DeadlineExceeded()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}

/// Opens the existential so the generic `Clock.sleep(for:tolerance:)` can be called.
private func sleep<C: Clock>(on clock: C, for duration: C.Duration) async throws {
    try await clock.sleep(for: duration)
}

/// How a thrown error from a request reads, before each client maps it to its own vocabulary.
enum TransportFailure: Equatable {
    /// ``withTotalTimeout(_:clock:operation:)`` fired (RN `AbortError`).
    case deadline
    /// No usable answer from the network. On RN iOS every transport failure is
    /// `TypeError('Network request failed')`, and an idle timeout is
    /// `'Network request timed out'`; both match RN's `/network/i` regex.
    case offline
    /// The calling task was cancelled; RN has no equivalent.
    case cancelled
    /// Anything else: a file read, a malformed URL, a server that broke HTTP.
    case other

    static func classify(_ error: any Error) -> TransportFailure {
        if error is DeadlineExceeded { return .deadline }
        if error is CancellationError { return Task.isCancelled ? .cancelled : .other }
        guard let urlError = error as? URLError else { return .other }
        if urlError.code == .cancelled { return Task.isCancelled ? .cancelled : .other }
        return offlineCodes.contains(urlError.code) ? .offline : .other
    }

    /// Connectivity, DNS, TLS and timeout failures (03 §4.2, 05 §10.5). `.timedOut`
    /// reads as offline, as RN reads "Network request timed out" (00-index §5, 03 Q7).
    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
        .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed, .callIsActive,
        .cannotLoadFromNetwork, .secureConnectionFailed, .serverCertificateHasBadDate,
        .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
        .clientCertificateRejected, .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection,
        .backgroundSessionWasDisconnected,
    ]
}

/// Whole milliseconds since `start`, like RN's `Date.now() - startedAt`.
func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
    let elapsed = ContinuousClock.now - start
    return Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
}
