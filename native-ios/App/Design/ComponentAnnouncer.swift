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

    /// Posts `text`, queued or interrupting: what ``SwiftUI/EnvironmentValues/componentAnnounce``
    /// does unless a test records instead.
    static func post(_ text: String, queued: Bool) {
        if queued {
            announceQueued(text)
        } else {
            announce(text)
        }
    }
}

extension EnvironmentValues {
    /// Where `announcesOnChange` posts: VoiceOver (``ComponentAnnouncer``). Hosted tests put a
    /// recorder here to count what a component announced. The second argument is `queued`.
    @Entry var componentAnnounce: @MainActor @Sendable (String, Bool) -> Void = { text, queued in
        ComponentAnnouncer.post(text, queued: queued)
    }
}

/// Announces a text once when its view first appears and again only when the text changes
/// (RN live regions and `useEffect([text])`). A list row that scrolls away and back appears
/// again with the same words and stays silent: the view's state remembers what was said. Turning
/// `enabled` off forgets it, so the same words coming back (a field error shown again after it
/// was cleared) are news again.
struct ComponentAnnouncementModifier: ViewModifier {
    let text: String
    let enabled: Bool
    let queued: Bool

    @Environment(\.componentAnnounce) private var post
    @State private var announced: String?

    func body(content: Content) -> some View {
        content.task(id: enabled ? text : nil) {
            guard enabled, !text.isEmpty else {
                announced = nil
                return
            }
            guard announced != text else { return }
            announced = text
            post(text, queued)
        }
    }
}
