import Foundation
import InventoryCore

/// Whether onboarding has been completed (06 §11.1). RN: src/services/onboarding.ts.
public struct OnboardingPreference: Sendable {
    private let preferences: any PreferenceStoring

    public init(preferences: any PreferenceStoring) {
        self.preferences = preferences
    }

    /// Completed only when the stored value is exactly "true" (RN: onboarding.ts:10-18).
    public var isCompleted: Bool {
        preferences.storedString(forKey: PreferenceKey.onboardingCompleted) == "true"
    }

    /// Writes "true", or removes the key so onboarding shows again (RN: onboarding.ts:20-30).
    public func setCompleted(_ completed: Bool) {
        if completed {
            preferences.setString("true", forKey: PreferenceKey.onboardingCompleted)
        } else {
            preferences.removeValue(forKey: PreferenceKey.onboardingCompleted)
        }
    }
}

/// Whether Home's "this phone keeps its own inventory" notice was put away (04 §12.8).
/// RN: src/ui/home/unpairedNotice.ts.
public struct UnpairedNoticePreference: Sendable {
    private let preferences: any PreferenceStoring

    public init(preferences: any PreferenceStoring) {
        self.preferences = preferences
    }

    /// Dismissed only when the stored value is exactly "1" (RN: unpairedNotice.ts:21-28).
    public var isDismissed: Bool {
        preferences.storedString(forKey: PreferenceKey.unpairedNoticeDismissed) == "1"
    }

    /// Persists "1" (RN: unpairedNotice.ts:34-39).
    public func dismiss() {
        preferences.setString("1", forKey: PreferenceKey.unpairedNoticeDismissed)
    }
}

/// When the last backup was taken, in the server's clock (03 §5.3). One global marker, not per
/// account. RN: src/services/sync/backup.ts:12, 29-46.
public struct LastBackupPreference: Sendable {
    private let preferences: any PreferenceStoring

    public init(preferences: any PreferenceStoring) {
        self.preferences = preferences
    }

    /// Milliseconds since the epoch, or nil when nothing finite is stored.
    ///
    /// RN reads `stored ? Number(stored) : NaN` and keeps finite results, so an empty string is
    /// nil while whitespace alone is 0, and hex or exponent forms parse (backup.ts:29-37).
    public var lastBackupAt: Double? {
        guard let stored = preferences.storedString(forKey: PreferenceKey.lastBackupAt), !stored.isEmpty,
              let value = jsNumber(stored.jsTrimmed()), value.isFinite else { return nil }
        return value
    }

    /// Records a backup's `capturedAt` in the integer form `String(number)` gives for an integral
    /// JS number, never with a ".0" suffix (02 §5.3).
    public func recordBackup(at capturedAt: Int64) {
        preferences.setString(String(capturedAt), forKey: PreferenceKey.lastBackupAt)
    }
}
