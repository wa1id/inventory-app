// RN: src/ui/household/join.ts:65-81. One of the result taxonomies 09 §10.1 places
// next to describeError natively. The raw value is the `outcome` of the
// `household_join_failed` telemetry event (09 §9.2).

/// Why joining a household did not work (RN `JoinFailure`).
public enum JoinFailure: String, Sendable, Hashable, CaseIterable {
    /// The home server did not accept the code.
    case refused
    /// The home server did not answer.
    case offline
    /// Anything else.
    case other
}

/// Why joining did not work (RN `joinFailure`).
///
/// A 401 or an `unauthorized` code from pairing is a code the home server did not
/// accept: pairing carries no token yet, so it is never a removed phone, and it is
/// checked before reachability. Otherwise the unreachable cases follow
/// ``describeError(_:context:subject:)``, which knows Cloudflare's "home box is
/// down" answers, and everything else is `other`.
public func joinFailure(_ cause: (any Error)?) -> JoinFailure {
    if let http = cause as? HouseholdHttpError, http.status == 401 || isCode(http, "unauthorized") {
        return .refused
    }
    return describeError(cause, context: .join).kind == .offline ? .offline : .other
}
