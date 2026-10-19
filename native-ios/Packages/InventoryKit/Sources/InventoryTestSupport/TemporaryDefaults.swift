import Foundation

/// A throwaway `UserDefaults` suite, removed when the value goes away.
///
/// Every instance has its own suite name, so suites that run in parallel never see each
/// other's keys and nothing leaks into the test runner's standard defaults.
public final class TemporaryDefaults {
    public let name: String
    public let defaults: UserDefaults

    public struct Unavailable: Error, CustomStringConvertible {
        public let name: String
        public var description: String { "UserDefaults(suiteName: \(name)) returned nil" }
    }

    public init(prefix: String = "inventory.tests") throws {
        name = "\(prefix).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { throw Unavailable(name: name) }
        self.defaults = defaults
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
    }
}
