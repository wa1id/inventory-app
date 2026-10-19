/// The telemetry `errorClass` for a thrown error: its type name (09 §9.1).
///
/// RN sent `error.name` (`HouseholdHttpError`, `ConflictError`, `TypeError`, …).
/// Swift has no `Error.name`, so this is the type's name, which keeps the first two
/// identical. Never `localizedDescription`: it can carry user text or file paths.
/// Call sites that RN gave a ``ErrorKind`` instead send `describeError(...).kind.rawValue`.
public func errorClass(of error: any Error) -> String {
    String(describing: type(of: error))
}
