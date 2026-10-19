import InventoryStrings

// RN: src/ui/errors.ts. Plain words for anything a read or write can fail with.
// Raw codes and error messages never reach the screen: the person gets what
// happened, what to do next and what is still safe. The cause itself goes to
// telemetry only, as the kind or the type name (09 §10.2).

/// What went wrong, as far as the person needs to know (RN `ErrorKind`).
///
/// The raw value is what telemetry sends as `errorClass` where RN sent the kind.
public enum ErrorKind: String, Sendable, Hashable, CaseIterable {
    /// The home server did not answer (no network, timeout, or Cloudflare's 502 and 520–530).
    case offline
    /// The home server no longer accepts this phone's token.
    case revoked
    /// Someone changed the record on another phone first.
    case conflict
    /// The record was deleted, probably on another phone.
    case gone
    /// The record is fine but its photo is missing on the home server.
    case photo
    /// Any other home-server failure.
    case server
    /// Anything that is not a household answer: the local database and the rest.
    case local
}

/// What the person was doing when it failed (RN `ErrorContext`).
///
/// `read` and `join` get the reading wording; the others the "not saved" wording.
public enum ErrorContext: String, Sendable, Hashable, CaseIterable {
    case read
    case save
    case move
    case quantity
    case delete
    case label
    case join
}

/// What the failed screen was about, which names a gone record (RN `ErrorSubject`).
public enum ErrorSubject: String, Sendable, Hashable, CaseIterable {
    case item
    case space
    case container
    case list
}

/// A failure in words for the screen (RN `DescribedError`).
public struct ErrorCopy: Sendable, Hashable {
    public var kind: ErrorKind
    public var title: String
    public var body: String

    public init(kind: ErrorKind, title: String, body: String) {
        self.kind = kind
        self.title = title
        self.body = body
    }
}

/// Describes a failure in plain words (RN `describeError`, src/ui/errors.ts:41-82).
///
/// `nil` stands for JS `null`: a read that found nothing, because the record was
/// deleted elsewhere, so it reads as gone. (JS `undefined` has no Swift
/// counterpart; a thrown error is never `nil`.) In order:
/// 1. a ``ConflictError`` is a conflict;
/// 2. `nil` is gone, titled by `subject`;
/// 3. a ``HouseholdHttpError`` is offline when the home server did not answer,
///    revoked on a 401 or an `unauthorized` code (except while joining, where it is
///    a refused code and reads as a server problem), gone on a 404 or `not_found`,
///    a missing photo on `photo_missing`, and otherwise a server problem;
/// 4. anything else is the local database.
public func describeError(
    _ cause: (any Error)?,
    context: ErrorContext = .read,
    subject: ErrorSubject = .list
) -> ErrorCopy {
    let reading = context == .read || context == .join

    if cause is ConflictError {
        return ErrorCopy(kind: .conflict, title: L10n.Errors.Conflict.title, body: L10n.Errors.Conflict.body)
    }

    guard let cause else { return gone(subject) }

    if let http = cause as? HouseholdHttpError {
        if isUnreachable(http) {
            return ErrorCopy(
                kind: .offline,
                title: L10n.Errors.Offline.title,
                body: reading ? L10n.Errors.Offline.read : L10n.Errors.Offline.save
            )
        }
        // Pairing has no token yet, so a 401 there is a refused code, not a removed phone.
        if context != .join && (http.status == 401 || isCode(http, "unauthorized")) {
            return ErrorCopy(kind: .revoked, title: L10n.Errors.Revoked.title, body: L10n.Errors.Revoked.body)
        }
        if http.status == 404 || isCode(http, "not_found") {
            return gone(subject)
        }
        if isCode(http, "photo_missing") {
            return ErrorCopy(kind: .photo, title: L10n.Errors.Photo.title, body: L10n.Errors.Photo.body)
        }
        return ErrorCopy(kind: .server, title: L10n.Errors.Server.title, body: L10n.Errors.Server.body)
    }

    return ErrorCopy(
        kind: .local,
        title: L10n.Errors.Local.title,
        body: reading ? L10n.Errors.Local.read : L10n.Errors.Local.save
    )
}

/// Whether a refresh that failed while data stayed on screen gets the "could not be
/// refreshed" banner (`L10n.Errors.refreshFailed`) (RN `needsRefreshBanner`).
///
/// Never when the refresh worked. Otherwise always, except when the reason already
/// has its own surface: the connection banner explains an unreachable home server,
/// and the removed-phone layer covers a revoked one.
public func needsRefreshBanner(_ refreshFailed: Bool, cause: (any Error)?) -> Bool {
    guard refreshFailed else { return false }
    let kind = describeError(cause).kind
    return kind != .offline && kind != .revoked
}

/// Whether a failed write was the connection, for the "check the connection" wording (RN `isOffline`).
public func isOffline(_ cause: (any Error)?) -> Bool {
    describeError(cause, context: .save).kind == .offline
}

// MARK: - Rules

/// The gone copy, titled by what the screen was about (RN `goneTitle`); a list reads as an item.
private func gone(_ subject: ErrorSubject) -> ErrorCopy {
    let title = switch subject {
    case .space: L10n.Errors.Gone.space
    case .container: L10n.Errors.Gone.container
    case .item, .list: L10n.Errors.Gone.item
    }
    return ErrorCopy(kind: .gone, title: title, body: L10n.Errors.Gone.body)
}

/// Codes from the household client that mean the home box could not be reached (RN `isUnreachable`).
///
/// `offline`, `timeout` and `http_502`; or a 502 or a 520–530, which Cloudflare
/// answers itself when the home box behind it is down. The status is the three
/// digits of an `http_NNN` code when there is one, else the response status.
func isUnreachable(_ error: HouseholdHttpError) -> Bool {
    if isCode(error, "offline") || isCode(error, "timeout") || isCode(error, "http_502") {
        return true
    }
    let status = httpStatus(inCode: error.code) ?? error.status
    return status == 502 || (520...530).contains(status)
}

/// The status in a code matching JS `/^http_(\d{3})$/`: exactly `http_` and three ASCII digits.
func httpStatus(inCode code: String) -> Int? {
    let units = Array(code.utf8)
    let prefix = Array("http_".utf8)
    guard units.count == prefix.count + 3, units.starts(with: prefix) else { return nil }
    var status = 0
    for unit in units[prefix.count...] {
        guard (0x30...0x39).contains(unit) else { return nil }
        status = status * 10 + Int(unit - 0x30)
    }
    return status
}

/// JS `error.code === expected`: exact code units, no canonical equivalence.
private func isCode(_ error: HouseholdHttpError, _ expected: String) -> Bool {
    error.code.utf8.elementsEqual(expected.utf8)
}
