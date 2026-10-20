import UIKit
import InventoryAppModels

/// Where a haptic ends up: the UIKit feedback generators in the app, a recorder in tests.
@MainActor
protocol ShellFeedbackOutput: AnyObject {
    func selectionChanged()
    func impactOccurred(_ style: HapticFeedback.ImpactStyle)
    func notificationOccurred(_ type: HapticFeedback.NotificationType)
}

/// Plays ``HapticEvent``s the way RN's expo-haptics did (08 §7.1): each event's
/// ``HapticEvent/feedback`` picks the generator call.
@MainActor
final class ShellHapticEngine {
    private let output: any ShellFeedbackOutput

    init(output: any ShellFeedbackOutput = ShellUIKitFeedback()) {
        self.output = output
    }

    /// Plays `event`. Fire-and-forget: generators never throw.
    func play(_ event: HapticEvent) {
        switch event.feedback {
        case .selection: output.selectionChanged()
        case .impact(let style): output.impactOccurred(style)
        case .notification(let type): output.notificationOccurred(type)
        }
    }

    /// The engine as the `HapticPlayer` the models and the environment take.
    var player: HapticPlayer {
        { [self] event in play(event) }
    }
}

/// The UIKit generators, kept and prepared so the next haptic plays without the warm-up lag.
@MainActor
final class ShellUIKitFeedback: ShellFeedbackOutput {
    private let selection = UISelectionFeedbackGenerator()
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let notification = UINotificationFeedbackGenerator()

    init() {
        selection.prepare()
        light.prepare()
        medium.prepare()
        notification.prepare()
    }

    func selectionChanged() {
        selection.selectionChanged()
        selection.prepare()
    }

    func impactOccurred(_ style: HapticFeedback.ImpactStyle) {
        let generator = style == .light ? light : medium
        generator.impactOccurred()
        generator.prepare()
    }

    func notificationOccurred(_ type: HapticFeedback.NotificationType) {
        let kind: UINotificationFeedbackGenerator.FeedbackType = switch type {
        case .success: .success
        case .warning: .warning
        case .error: .error
        }
        notification.notificationOccurred(kind)
        notification.prepare()
    }
}
