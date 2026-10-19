import Foundation
import Synchronization

/// String-valued device preferences, the native stand-in for the RN AsyncStorage values.
///
/// Values are kept as the exact strings RN wrote ("true", "1", JSON text, a numeric string) and
/// parsed on read with RN's rules (DECISIONS D-5). The live store is `UserDefaults.standard`,
/// after ``LegacyImport`` has copied the RN values in; tests use ``InMemoryPreferences``.
public protocol PreferenceStoring: Sendable {
    /// The stored string, or nil when the key is absent or holds something other than a string.
    func storedString(forKey key: String) -> String?
    /// Stores `value` under `key`.
    func setString(_ value: String, forKey key: String)
    /// Removes `key`.
    func removeValue(forKey key: String)
}

extension UserDefaults: PreferenceStoring {
    public func storedString(forKey key: String) -> String? {
        // Not `UserDefaults.string(forKey:)`, which would turn a number into a string.
        object(forKey: key) as? String
    }

    public func setString(_ value: String, forKey key: String) {
        set(value, forKey: key)
    }

    public func removeValue(forKey key: String) {
        removeObject(forKey: key)
    }
}

/// An in-memory ``PreferenceStoring`` for tests and previews.
public final class InMemoryPreferences: PreferenceStoring {
    private let storage: Mutex<[String: String]>

    public init(_ values: [String: String] = [:]) {
        storage = Mutex(values)
    }

    /// Every stored value.
    public var values: [String: String] {
        storage.withLock { $0 }
    }

    public func storedString(forKey key: String) -> String? {
        storage.withLock { $0[key] }
    }

    public func setString(_ value: String, forKey key: String) {
        storage.withLock { $0[key] = value }
    }

    public func removeValue(forKey key: String) {
        _ = storage.withLock { $0.removeValue(forKey: key) }
    }
}

/// The seven preference keys the React Native build wrote. The names are part of the on-device
/// format (02 §5.3) and are kept unchanged in `UserDefaults`.
public enum PreferenceKey {
    /// "true" once onboarding is done; removed on replay. RN: src/services/onboarding.ts:3.
    public static let onboardingCompleted = "onboarding.completed.v1"
    /// JSON array of container ids, most recent first. RN: src/services/places/recentPlaces.ts:5.
    public static let recentPlaces = "places.recent.v1"
    /// JSON array of category names, most recent first. RN: src/ui/categoryMemory.ts:3.
    public static let recentCategories = "categories.recent.v1"
    /// "1" once Home's unpaired notice is dismissed. RN: src/ui/home/unpairedNotice.ts:4.
    public static let unpairedNoticeDismissed = "notice.unpaired.dismissed.v1"
    /// The server time of the last backup, integer milliseconds as a string. RN: src/services/sync/backup.ts:12.
    public static let lastBackupAt = "sync.lastBackupAt.v1"
    /// JSON `{"spaces":n,"items":n}`. RN: src/services/household/importOffer.ts:5.
    public static let householdImportOffer = "household.importOffer.v1"
    /// "true" once this phone has joined a household. RN: src/services/household/importOffer.ts:6.
    public static let householdJoinedBefore = "household.joinedBefore.v1"

    /// All seven, in the order 02 §5.3 lists them.
    public static let legacyKeys = [
        onboardingCompleted, recentPlaces, recentCategories, unpairedNoticeDismissed,
        lastBackupAt, householdImportOffer, householdJoinedBefore,
    ]
}
