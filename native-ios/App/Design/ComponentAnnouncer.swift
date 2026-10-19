import SwiftUI
import UIKit

/// VoiceOver announcements for the components (08 §9.2 item 10). VoiceOver does not read live
/// regions, so what RN marked live is announced when it appears or changes.
///
/// Banners, error states and stepper errors interrupt, as RN's plain `announceForAccessibility`
/// did. Field errors are queued behind what VoiceOver is reading, as RN's `{ queue: true }`.
@MainActor
enum ComponentAnnouncer {
    /// Interrupts whatever VoiceOver is saying.
    static func announce(_ text: String) {
        guard !text.isEmpty else { return }
        AccessibilityNotification.Announcement(text).post()
    }

    /// Waits for VoiceOver to finish what it is reading (RN `{ queue: true }`).
    static func announceQueued(_ text: String) {
        guard !text.isEmpty else { return }
        // The queue attribute RN set (UIAccessibilitySpeechAttributeQueueAnnouncement) has no
        // SwiftUI `AttributedString` key, so this one goes through UIKit.
        let attributed = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
        UIAccessibility.post(notification: .announcement, argument: attributed)
    }
}
