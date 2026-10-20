import SwiftUI
import Testing
import UIKit
@testable import Inventory
import InventoryAppModels
import InventoryStorage

@Suite("Overlay window (hosted)", .serialized)
@MainActor
struct ShellOverlayWindowTests {
    @Test("it installs above a presented sheet, shows only with a toast, and lets touches through outside the card")
    func aboveSheetsAndPassThrough() async throws {
        let app = AppContainer.preview()
        await app.boot.run()
        let host = try ShellTestWindow(Color.clear)
        defer { host.close() }
        let scene = try #require(ShellTestWindow.scene)

        // A sheet is up in the app's window.
        let sheet = UIViewController()
        host.window.rootViewController?.present(sheet, animated: false)
        await ShellTestWait.until("the sheet") { host.window.rootViewController?.presentedViewController === sheet }

        let overlay = ShellOverlayController(app: app)
        overlay.install(on: scene)
        let window = try #require(overlay.window)
        #expect(window.windowScene === scene)
        #expect(window.windowLevel > host.window.windowLevel)
        #expect(window.windowLevel > .alert)
        #expect(!window.canBecomeKey)
        #expect(window.isHidden)

        app.toasts.show(ToastOptions(message: "Moved to Tool chest (Garage).", action: ToastAction(label: "Undo") {}))
        await ShellTestWait.until("the window shown for the toast") { !window.isHidden }
        await ShellTestWait.until("the card laid out") { overlay.state.cardFrame != nil }
        let card = try #require(overlay.state.cardFrame)

        // Outside the card: through to the app's window. Inside: the card.
        #expect(window.hitTest(CGPoint(x: window.bounds.midX, y: 120), with: nil) == nil)
        #expect(window.hitTest(CGPoint(x: card.midX, y: card.midY), with: nil) != nil)

        // The removed-phone layer captures everything and is modal for VoiceOver.
        window.capturesAllTouches = true
        #expect(window.hitTest(CGPoint(x: window.bounds.midX, y: 120), with: nil) != nil)
        window.capturesAllTouches = false

        let id = try #require(app.toasts.current?.id)
        app.toasts.dismiss(id)
        await ShellTestWait.until("the window hidden again") { window.isHidden }
        window.isHidden = true
    }
}

@Suite("Haptics (hosted)")
@MainActor
struct ShellHapticsTests {
    @MainActor
    final class Recorder: ShellFeedbackOutput {
        var calls: [String] = []
        func selectionChanged() { calls.append("selection") }
        func impactOccurred(_ style: HapticFeedback.ImpactStyle) { calls.append("impact.\(style.rawValue)") }
        func notificationOccurred(_ type: HapticFeedback.NotificationType) { calls.append("notification.\(type.rawValue)") }
    }

    @Test("every event plays the generator RN's expo-haptics call used (08 §7.1)", arguments: [
        (HapticEvent.step, "selection"),
        (.reachedZero, "impact.light"),
        (.choice, "selection"),
        (.undo, "selection"),
        (.success, "notification.success"),
        (.warning, "notification.warning"),
        (.error, "notification.error"),
        (.tap, "impact.light"),
        (.longPress, "impact.medium"),
    ])
    func mapping(event: HapticEvent, call: String) {
        let recorder = Recorder()
        let engine = ShellHapticEngine(output: recorder)
        engine.player(event)
        #expect(recorder.calls == [call])
    }

    @Test("the UIKit output plays every kind without failing")
    func uikit() {
        let engine = ShellHapticEngine()
        for event in HapticEvent.allCases { engine.play(event) }
    }
}
