import InventoryStorage
import Observation

/// Whether the intro has been seen, shared by the whole app so the root gate flips in the same
/// tick the onboarding screen finishes (RN `OnboardingProvider` + src/services/onboarding.ts;
/// 06 §11.1, 09 §4.5).
///
/// The flag is the `onboarding.completed.v1` preference: completed only when it holds exactly
/// `"true"`. It is read once at boot, after the legacy preference import (09 §3.2 step 2a), or
/// every existing user would see onboarding again. There is no navigation call anywhere: the
/// root view swaps onboarding and the main shell from ``status`` alone.
@MainActor
@Observable
public final class OnboardingModel {
    /// RN `OnboardingStatus`.
    public enum Status: Sendable, Hashable {
        /// Not read yet: the gate shows the boot view.
        case loading
        /// Show onboarding.
        case pending
        case completed
    }

    /// Where the flag lives. Reads may fail (they did in RN, from AsyncStorage); writes may too,
    /// and their failures are ignored.
    public struct Storage: Sendable {
        /// Whether onboarding was completed.
        public var read: @Sendable () throws -> Bool
        /// Persists `true` (store `"true"`) or `false` (remove the key).
        public var write: @Sendable (Bool) throws -> Void

        public init(read: @escaping @Sendable () throws -> Bool, write: @escaping @Sendable (Bool) throws -> Void) {
            self.read = read
            self.write = write
        }

        /// The `onboarding.completed.v1` preference.
        public static func preference(_ preference: OnboardingPreference) -> Storage {
            Storage(read: { preference.isCompleted }, write: { preference.setCompleted($0) })
        }
    }

    public private(set) var status: Status = .loading
    @ObservationIgnored private let storage: Storage

    public init(storage: Storage) {
        self.storage = storage
    }

    /// Reads the flag from `preferences` (`UserDefaults.standard` in the app).
    public convenience init(preferences: any PreferenceStoring) {
        self.init(storage: .preference(OnboardingPreference(preferences: preferences)))
    }

    /// Reads the flag (boot). A read that fails means pending: showing onboarding once more is
    /// the safer failure (RN onboarding.ts:10-18). Does nothing once the status is known, so a
    /// late read can never undo ``complete()`` or ``replay()``.
    public func load() {
        guard status == .loading else { return }
        let completed = (try? storage.read()) ?? false
        status = completed ? .completed : .pending
    }

    /// Onboarding finished: the gate flips first, then `"true"` is stored (RN :33-36).
    public func complete() {
        status = .completed
        try? storage.write(true)
    }

    /// Settings › How it works: back to onboarding first, then the flag is removed (RN :38-41).
    public func replay() {
        status = .pending
        try? storage.write(false)
    }
}
