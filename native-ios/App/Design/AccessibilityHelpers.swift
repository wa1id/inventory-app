import SwiftUI

extension View {
    /// Sets the UI-test identifier (RN `testID`) when there is one.
    @ViewBuilder
    func accessibilityIdentifierIfPresent(_ identifier: String?) -> some View {
        if let identifier, !identifier.isEmpty {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }

    /// Sets the spoken label when there is one.
    @ViewBuilder
    func accessibilityLabelIfPresent(_ label: String?) -> some View {
        if let label, !label.isEmpty {
            accessibilityLabel(Text(verbatim: label))
        } else {
            self
        }
    }

    /// Sets the spoken hint when there is one.
    @ViewBuilder
    func accessibilityHintIfPresent(_ hint: String?) -> some View {
        if let hint, !hint.isEmpty {
            accessibilityHint(Text(verbatim: hint))
        } else {
            self
        }
    }

    /// Announces `text` to VoiceOver when this view appears and whenever `text` changes, unless
    /// `enabled` is false (RN live regions, which VoiceOver does not read).
    func announcesOnChange(_ text: String, enabled: Bool = true, queued: Bool = false) -> some View {
        task(id: enabled ? text : nil) {
            guard enabled else { return }
            if queued {
                ComponentAnnouncer.announceQueued(text)
            } else {
                ComponentAnnouncer.announce(text)
            }
        }
    }
}
