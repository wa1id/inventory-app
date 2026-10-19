import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Whether files with the default data protection class and `WhenUnlocked` keychain items can be
/// read yet. Before the first unlock after a reboot they cannot: the RN manifest, the database and
/// the keychain all fail, and a failed keychain read looks like "not paired" (02 §1, §4.4, §8).
@MainActor
public enum ProtectedData {
    /// True once protected data is readable. Always true where UIKit is absent (macOS tests).
    public static var isAvailable: Bool {
        #if canImport(UIKit)
        UIApplication.shared.isProtectedDataAvailable
        #else
        true
        #endif
    }

    /// Returns once protected data is readable: at once if it already is, otherwise on
    /// `UIApplication.protectedDataDidBecomeAvailableNotification` (02 §8 step 0).
    public static func waitUntilAvailable() async {
        #if canImport(UIKit)
        let notifications = NotificationCenter.default.notifications(
            named: UIApplication.protectedDataDidBecomeAvailableNotification)
        // The check runs after the sequence exists and before any suspension, so a notification
        // posted on the main thread cannot slip between the two.
        guard !isAvailable else { return }
        for await _ in notifications.map({ _ in () }) {
            return
        }
        #endif
    }
}
