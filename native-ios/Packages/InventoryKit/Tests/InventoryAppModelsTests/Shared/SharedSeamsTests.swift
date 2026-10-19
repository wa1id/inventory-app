import Foundation
import InventoryStrings
import Testing
@testable import InventoryAppModels

/// `Fixtures/shared-seams.json`, generated from src/ui/motion.ts, src/ui/haptics.ts and
/// src/ui/confirm.ts by `Fixtures/generator/shared-seams-vectors.test.ts`.
private struct SharedSeamsFixture: Decodable {
    struct MotionCase: Decodable {
        let ms: Int
        let reduced: Bool
        let result: Int
    }

    struct Easing: Decodable {
        let bezier: [Double]?
        let out: String?
    }

    struct ConfirmCase: Decodable {
        struct Button: Decodable {
            let text: String
            let style: String
        }

        let title: String
        let body: String
        let buttons: [Button]
        let cancelable: Bool
    }

    let duration: [String: Int]
    let delay: [String: Int]
    let easing: [String: Easing]
    let motionMs: [MotionCase]
    /// Event name → the expo-haptics calls it made, each `[function, argument?]`.
    let haptics: [String: [[String]]]
    let confirms: [ConfirmCase]

    static func load() throws -> SharedSeamsFixture {
        let url = try #require(Bundle.module.url(forResource: "shared-seams", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(SharedSeamsFixture.self, from: Data(contentsOf: url))
    }
}

@Suite("Motion (src/ui/motion.ts)")
struct MotionTests {
    private static func lengths(_ durations: Motion.Durations) -> [String: Int] {
        [
            "press": durations.press, "toastIn": durations.toastIn, "toastOut": durations.toastOut,
            "expand": durations.expand, "stepSwap": durations.stepSwap, "reticleLock": durations.reticleLock,
            "focusSpot": durations.focusSpot, "shutterFlash": durations.shutterFlash,
        ]
    }

    private static func waits(_ delays: Motion.Delays) -> [String: Int] {
        [
            "skeleton": delays.skeleton, "spinner": delays.spinner, "bootCaption": delays.bootCaption,
            "reconnect": delays.reconnect, "searchDebounce": delays.searchDebounce,
            "searchSkeleton": delays.searchSkeleton, "toast": delays.toast,
            "toastWithAction": delays.toastWithAction, "stepRepeat": delays.stepRepeat,
            "stepRepeatEvery": delays.stepRepeatEvery,
        ]
    }

    @Test("every duration matches motion.ts, and there is no other")
    func durations() throws {
        #expect(Self.lengths(Motion.duration) == (try SharedSeamsFixture.load().duration))
        #expect(Motion.duration.toastOut == 120)
    }

    @Test("every delay matches motion.ts, and there is no other")
    func delays() throws {
        #expect(Self.waits(Motion.delay) == (try SharedSeamsFixture.load().delay))
        #expect(Motion.delay.reconnect == 2500)
        #expect(Motion.delay.toast == 5000)
        #expect(Motion.delay.toastWithAction == 9000)
    }

    @Test("Reduce Motion zeroes every duration, as motionMs does, and leaves the delays alone")
    func reduceMotion() throws {
        let fixture = try SharedSeamsFixture.load()
        for vector in fixture.motionMs {
            #expect(Motion.motionMs(vector.ms, reduced: vector.reduced) == vector.result, "motionMs(\(vector.ms), \(vector.reduced))")
        }
        let reduced = Self.lengths(Motion.duration(reduceMotion: true))
        #expect(reduced == fixture.duration.mapValues { Motion.motionMs($0, reduced: true) })
        #expect(reduced.values.allSatisfy { $0 == 0 })
        #expect(Motion.duration(reduceMotion: false) == Motion.duration)
        #expect(Self.waits(Motion.Delays()) == fixture.delay)
    }

    @Test("the curves are motion.ts's: two Béziers as given and a cubic ease-out")
    func easings() throws {
        let easing = try SharedSeamsFixture.load().easing
        func points(_ curve: Motion.Curve) -> [Double] { [curve.x1, curve.y1, curve.x2, curve.y2] }
        #expect(easing["settle"]?.bezier == points(Motion.Easing.settle))
        #expect(easing["exit"]?.bezier == points(Motion.Easing.exit))
        #expect(easing["out"]?.out == "cubic")
        #expect(points(Motion.Easing.out) == [0.33, 1, 0.68, 1])
        #expect(Set(easing.keys) == ["settle", "out", "exit"])
    }
}

@Suite("Haptics (src/ui/haptics.ts)")
struct HapticEventTests {
    /// The expo-haptics call RN made for a feedback.
    private static func expoCall(_ feedback: HapticFeedback) -> [String] {
        switch feedback {
        case .selection: ["selectionAsync"]
        case .impact(let style): ["impactAsync", style.rawValue]
        case .notification(let type): ["notificationAsync", type.rawValue]
        }
    }

    @Test("one event per RN haptic, with RN's name")
    func everyEvent() throws {
        let haptics = try SharedSeamsFixture.load().haptics
        #expect(Set(HapticEvent.allCases.map(\.rawValue)) == Set(haptics.keys))
    }

    @Test("each event plays the generator RN's expo-haptics call does", arguments: HapticEvent.allCases)
    func feedback(event: HapticEvent) throws {
        let haptics = try SharedSeamsFixture.load().haptics
        #expect(haptics[event.rawValue] == [Self.expoCall(event.feedback)])
    }

    @Test("a model plays haptics through an injected player")
    @MainActor
    func player() {
        let played = SharedSeamsLog<HapticEvent>()
        let player: HapticPlayer = { played.items.append($0) }
        player(.success)
        player(.reachedZero)
        #expect(played.items == [.success, .reachedZero])
    }
}

@Suite("ConfirmOptions (src/ui/confirm.ts)")
struct ConfirmOptionsTests {
    @Test("defaults to Cancel and a destructive confirm, as confirm() does")
    func defaults() throws {
        let vector = try #require(try SharedSeamsFixture.load().confirms.first)
        let options = ConfirmOptions(title: vector.title, body: vector.body, confirmLabel: "Delete")
        #expect(options.cancelLabel == L10n.Common.cancel)
        #expect(vector.buttons.map(\.text) == [options.cancelLabel, options.confirmLabel])
        #expect(vector.buttons.map(\.style) == ["cancel", options.destructive ? "destructive" : "default"])
        #expect(options.destructive)
        #expect(vector.cancelable)
    }

    @Test("a dirty form's confirm keeps its own cancel label and a plain button")
    func explicit() throws {
        let vector = try #require(try SharedSeamsFixture.load().confirms.last)
        let options = ConfirmOptions(title: "Discard?", body: "Changes go.", confirmLabel: "Discard", cancelLabel: "Keep editing", destructive: false)
        #expect(vector.buttons.map(\.text) == [options.cancelLabel, options.confirmLabel])
        #expect(vector.buttons.map(\.style) == ["cancel", options.destructive ? "destructive" : "default"])
    }

    @Test("a presenter answers a model's question")
    @MainActor
    func presenter() async {
        @MainActor
        final class ScriptedConfirm: ConfirmPresenting {
            var asked: [ConfirmOptions] = []
            let answer: Bool
            init(answer: Bool) { self.answer = answer }
            func confirm(_ options: ConfirmOptions) async -> Bool {
                asked.append(options)
                return answer
            }
        }
        let presenter = ScriptedConfirm(answer: false)
        let presenting: any ConfirmPresenting = presenter
        let options = ConfirmOptions(title: "Delete?", body: "Gone.", confirmLabel: "Delete")
        #expect(await presenting.confirm(options) == false)
        #expect(presenter.asked == [options])
    }
}

@Suite("Toast seam (src/providers/ToastProvider.tsx)")
struct ToastSeamTests {
    @MainActor
    final class RecordingToasts: ToastPresenting {
        var shown: [ToastOptions] = []
        var dismissed: [String] = []

        func show(_ options: ToastOptions) -> String {
            shown.append(options)
            return "toast-\(shown.count)"
        }

        func dismiss(_ id: String) {
            dismissed.append(id)
        }
    }

    @Test("options default to an info toast living 5 s, 9 s with an action, or what the caller says")
    func defaults() {
        let plain = ToastOptions(message: "Saved")
        #expect(plain.tone == .info)
        #expect(plain.action == nil)
        #expect(plain.duration == nil)
        #expect(plain.baseDuration == .milliseconds(5000))
        let undo = ToastOptions(message: "Moved", action: ToastAction(label: "Undo") {})
        #expect(undo.baseDuration == .milliseconds(9000))
        #expect(ToastOptions(message: "x", action: ToastAction(label: "Undo") {}, duration: .seconds(2)).baseDuration == .seconds(2))
        #expect([ToastTone.info, .error].map(\.rawValue) == ["info", "error"])
    }

    @Test("show returns the id, dismiss takes it, and the action runs on the main actor")
    @MainActor
    func presenting() {
        let toasts = RecordingToasts()
        let presenter: any ToastPresenting = toasts
        let undone = SharedSeamsLog<String>()
        let id = presenter.show(ToastOptions(
            message: "Moved to Tool chest (Garage)",
            action: ToastAction(label: "Undo", accessibilityLabel: "Undo moving Cordless drill") { undone.items.append("undo") }
        ))
        presenter.dismiss(id)
        #expect(id == "toast-1")
        #expect(toasts.dismissed == ["toast-1"])
        let action = toasts.shown.first?.action
        #expect(action?.accessibilityLabel == "Undo moving Cordless drill")
        action?.handler()
        #expect(undone.items == ["undo"])
        presenter.show(ToastOptions(message: "Error", tone: .error))
        #expect(toasts.shown.map(\.tone) == [.info, .error])
    }
}

@Suite("Invalidation and app activity")
struct InvalidationAndActivityTests {
    @MainActor
    final class CountingInvalidator: InventoryInvalidating {
        var revision = 0
        func invalidate() { revision &+= 1 }
    }

    @Test("a writer bumps the revision through the protocol")
    @MainActor
    func invalidates() {
        let counter = CountingInvalidator()
        let invalidator: any InventoryInvalidating = counter
        invalidator.invalidate()
        invalidator.invalidate()
        #expect(counter.revision == 2)
    }

    @Test("only active is active")
    func activity() {
        #expect(AppActivity.active.isActive)
        #expect(!AppActivity.inactive.isActive)
        #expect(!AppActivity.background.isActive)
    }
}

/// A main-actor list a `@MainActor @Sendable` closure can append to.
@MainActor
private final class SharedSeamsLog<Item> {
    var items: [Item] = []
}
