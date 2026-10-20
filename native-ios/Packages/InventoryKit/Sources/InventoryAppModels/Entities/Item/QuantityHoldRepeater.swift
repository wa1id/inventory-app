import InventoryCore
import Observation

/// The quantity stepper's behaviour without its drawing: tap and hold-repeat on minus and plus,
/// and typing a number (RN `QuantityStepper`, src/ui/components/QuantityStepper.tsx; 07 §4.7).
///
/// - A tap steps by one. Holding steps once after 400 ms, then every 80 ms until release or a
///   bound (exact RN timing, 07 Q2), on the injected clock.
/// - Haptics: `reachedZero` when a step lands on 0, else `step`; while holding, only every
///   fifth repeat ticks. A step that changes nothing (at a bound, or disabled) does nothing.
/// - Typing: the field shows ``draft`` while it is being edited (at most four characters).
///   Leaving it, Return or the keyboard's Done commits: anything that is not a whole number
///   reverts; the rest is clamped to 0…9999. With `commitWhileTyping` (the Add form, whose Save
///   sits outside the scroll view) every whole number typed is reported at once. A ± press
///   with a draft open commits the draft first.
///
/// It is controlled: the view keeps ``value`` equal to its binding and passes `onChange`.
@MainActor
@Observable
public final class QuantityHoldRepeater {
    /// Which button.
    public enum Direction: Int, Sendable, Hashable {
        case minus = -1
        case plus = 1
    }

    /// During hold-repeat only every fifth step ticks (RN `REPEAT_HAPTIC_EVERY`).
    public nonisolated static let repeatHapticEvery = 5
    /// The longest number the field takes: "9999".
    public nonisolated static let maxDraftLength = String(maxQuantity).count

    /// The current count. The view sets it from its binding; steps update it at once so a hold
    /// keeps counting before the binding comes back.
    public var value: Int
    /// Steps and typing do nothing (the whole stepper is dimmed).
    public var isDisabled: Bool
    /// What the number field shows while it is being edited; nil otherwise.
    public private(set) var draft: String?

    @ObservationIgnored public var onChange: @MainActor (Int) -> Void
    @ObservationIgnored private let commitWhileTyping: Bool
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let haptics: HapticPlayer
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var repeatCount = 0
    /// The press turned into a hold (RN's `onLongPress` fired), so its release is not a tap.
    @ObservationIgnored private var held = false
    @ObservationIgnored private var pressed: Direction?

    public init(
        value: Int,
        isDisabled: Bool = false,
        commitWhileTyping: Bool = false,
        clock: any Clock<Duration> = ContinuousClock(),
        haptics: @escaping HapticPlayer,
        onChange: @escaping @MainActor (Int) -> Void
    ) {
        self.value = value
        self.isDisabled = isDisabled
        self.commitWhileTyping = commitWhileTyping
        self.clock = clock
        self.haptics = haptics
        self.onChange = onChange
    }

    /// Minus is off at 0 or below (or when disabled).
    public var isMinusDisabled: Bool { isDisabled || value <= minQuantity }
    /// Plus is off at 9999 or above (or when disabled); a larger stored value stays as it is.
    public var isPlusDisabled: Bool { isDisabled || value >= maxQuantity }
    /// What the field shows: the draft while editing, else the count.
    public var fieldText: String { draft ?? String(value) }

    // MARK: Pressing

    /// A finger went down on a button: arms the 400 ms hold.
    public func pressBegan(_ direction: Direction) {
        cancelHold()
        pressed = direction
        held = false
        let clock = clock
        // One task for the whole press: the hold delay, then the repeats.
        holdTask = Task { [weak self] in
            do {
                try await clock.sleep(for: .milliseconds(Motion.delay.stepRepeat))
            } catch {
                return
            }
            guard self?.startRepeating(direction) == true else { return }
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: .milliseconds(Motion.delay.stepRepeatEvery))
                } catch {
                    return
                }
                guard self?.repeatStep(direction) == true else { return }
            }
        }
    }

    /// The finger lifted: a press shorter than the hold delay is a tap (one step); after a hold
    /// the repeating stops.
    public func pressEnded() {
        let direction = pressed
        let wasHeld = held
        cancelHold()
        pressed = nil
        held = false
        if !wasHeld, let direction { step(direction) }
    }

    // A stock button in a scrolling list reports its pressed state and calls its action
    // separately, in either order, and a scroll that takes the touch ends the press with no
    // action. These two keep that from stepping twice, or stepping on a scroll.

    /// The button stopped being pressed (released, slid away, or a scroll took the touch): the
    /// hold and its repeats stop. Whether the press became a hold is kept for
    /// ``buttonActivated(_:)``, which follows a release but never a cancelled press.
    public func pressLifted() {
        cancelHold()
    }

    /// The button's action: a tap steps once; the release of a hold in that direction does not
    /// step again. Works whether or not the press was seen beginning (a quick tap can begin and
    /// end between two updates).
    public func buttonActivated(_ direction: Direction) {
        let wasHeld = held && pressed == direction
        cancelHold()
        pressed = nil
        held = false
        if !wasHeld { step(direction) }
    }

    /// The press was cancelled (the finger slid away, the view went): no step, repeating stops.
    public func pressCancelled() {
        cancelHold()
        pressed = nil
        held = false
    }

    /// One step, as a tap or VoiceOver's increment and decrement make (RN `step` / `bump`).
    /// Returns the new count, or nil when nothing changed.
    @discardableResult
    public func step(_ direction: Direction) -> Int? {
        bump(direction.rawValue, repeating: false)
    }

    // MARK: Typing

    /// The field took focus: the draft starts as the count.
    public func beginEditing() {
        draft = String(value)
    }

    /// The field's text changed (cut to four characters, as the RN field's `maxLength`).
    public func typeDraft(_ text: String) {
        let limited = String(text.prefix(Self.maxDraftLength))
        draft = limited
        guard commitWhileTyping, let parsed = parseQuantityInput(limited) else { return }
        // An empty or partial entry waits for more typing.
        let next = clampQuantity(parsed)
        let changed = next != value
        value = next
        if changed { onChange(next) }
    }

    /// Leaving the field, Return or Done: a whole number is taken (clamped), anything else reverts.
    public func commitTyped() {
        let before = value
        let next = commitDraft()
        if next != before { onChange(next) }
    }

    // MARK: Private

    /// The hold delay passed (RN `onLongPress` → `startRepeat`): one step now; the repeats follow.
    /// False when the press already ended.
    private func startRepeating(_ direction: Direction) -> Bool {
        guard pressed == direction, !Task.isCancelled else { return false }
        held = true
        repeatCount = 0
        bump(direction.rawValue, repeating: false)
        return true
    }

    /// One repeat; false once it stopped (a bound).
    private func repeatStep(_ direction: Direction) -> Bool {
        guard held, pressed == direction else { return false }
        return bump(direction.rawValue, repeating: true) != nil
    }

    /// The stepped count, or nil when nothing changed (RN `bump`).
    @discardableResult
    private func bump(_ delta: Int, repeating: Bool) -> Int? {
        if isDisabled { return nil }
        let base = commitDraft()
        let next = stepQuantity(base, delta)
        if next == base {
            stopRepeating()
            return nil
        }
        value = next
        onChange(next)
        if next == minQuantity {
            haptics(.reachedZero)
        } else if !repeating {
            haptics(.step)
        } else {
            repeatCount += 1
            if repeatCount % Self.repeatHapticEvery == 0 { haptics(.step) }
        }
        return next
    }

    /// Takes the draft, if any, and returns the count to step from (RN `commitDraft`).
    private func commitDraft() -> Int {
        guard let typed = draft else { return value }
        draft = nil
        guard let parsed = parseQuantityInput(typed) else { return value }
        value = clampQuantity(parsed)
        return value
    }

    /// A bound stops the repeat; the press itself goes on until release.
    private func stopRepeating() {
        guard held else { return }
        holdTask?.cancel()
        holdTask = nil
    }

    private func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
    }
}
