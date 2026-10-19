import Foundation
import Synchronization

/// An in-memory ``KeychainStore`` for tests and previews, mirroring the expo-secure-store mock in
/// RN's `identity.test.ts:11-40`: a map, plus switches that make the next read or the next write
/// fail once.
public final class InMemoryKeychain: KeychainStore {
    private struct State {
        var values: [String: String]
        var failNextRead = false
        var failNextWrite = false
    }

    private let state: Mutex<State>

    public init(_ values: [String: String] = [:]) {
        state = Mutex(State(values: values))
    }

    /// The error the failure switches throw: `errSecInteractionNotAllowed`, as on a locked device.
    public static let simulatedFailure = KeychainError.status(-25308)

    /// Every stored value.
    public var values: [String: String] {
        state.withLock { $0.values }
    }

    /// Makes the next ``string(forKey:)`` throw, once.
    public func failNextRead() {
        state.withLock { $0.failNextRead = true }
    }

    /// Makes the next ``set(_:forKey:)`` throw, once.
    public func failNextWrite() {
        state.withLock { $0.failNextWrite = true }
    }

    public func string(forKey key: String) throws(KeychainError) -> String? {
        let result: Result<String?, KeychainError> = state.withLock { state in
            if state.failNextRead {
                state.failNextRead = false
                return .failure(Self.simulatedFailure)
            }
            return .success(state.values[key])
        }
        return try result.get()
    }

    public func set(_ value: String, forKey key: String) throws(KeychainError) {
        let failed = state.withLock { state in
            if state.failNextWrite {
                state.failNextWrite = false
                return true
            }
            state.values[key] = value
            return false
        }
        if failed { throw Self.simulatedFailure }
    }

    public func delete(forKey key: String) {
        _ = state.withLock { $0.values.removeValue(forKey: key) }
    }
}
