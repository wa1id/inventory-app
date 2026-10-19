import Foundation

/// The telemetry `errorClass` for a thrown error: its type name (09 §9.1).
///
/// RN sent `error.name` (`HouseholdHttpError`, `ConflictError`, `TypeError`, …).
/// Swift has no `Error.name`, so this is the type's name, which keeps the first two
/// identical. URLSession's errors arrive as `URLError` or as an `NSError` in
/// `NSURLErrorDomain` (which bridges to `URLError`); both are named `URLError`.
/// Never `localizedDescription`: it can carry user text or file paths.
/// Call sites that RN gave a ``ErrorKind`` instead send `describeError(...).kind.rawValue`.
public func errorClass(of error: any Error) -> String {
    if error is URLError || (error as NSError).domain == NSURLErrorDomain { return "URLError" }
    return String(describing: type(of: error))
}
