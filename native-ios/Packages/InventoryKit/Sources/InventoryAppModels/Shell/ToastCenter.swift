import InventoryStrings
import Observation

/// The app's toasts: one at a time, for writes that finished somewhere the person is no longer
/// looking (RN `ToastProvider`, src/providers/ToastProvider.tsx; 09 §4.6, 06 §14).
///
/// Rules, all RN's:
/// - ``show(_:)`` returns `"toast-N"` (N counts from 1 per process; there is one centre) and
///   replaces the current toast, even one that is leaving.
/// - **Error hold.** While the current toast is an error that has been up for less than
///   ``errorHold`` (1.5 s), a newcomer waits in a single pending slot: the newest waiting toast
///   wins, except that a waiting error is never replaced by an info toast. One timer fires when
///   the error's 1.5 s are up and presents whatever is waiting. A leaving toast is still
///   current until it is removed.
/// - **Life**: `ToastOptions.baseDuration` (5 s, 9 s with an action), doubled while VoiceOver
///   runs. On expiry the toast leaves: ``leaving`` turns on for the exit animation and the toast
///   is removed ``exitDuration`` (120 ms) later.
/// - ``pause()`` (touch down) freezes the remaining life; ``resume()`` (touch up or cancel)
///   restarts it with at least ``resumeFloor`` (2.5 s) and without doubling again.
/// - ``dismiss(_:)`` drops a waiting toast with that id, and makes the current one leave.
/// - Presenting announces ``Record/spokenText`` through the injected `announce`, which the app
///   posts as a queued VoiceOver announcement.
/// - ``registerChrome(height:)``: the focused screen's tab bar or bottom bar; the latest
///   registration wins, and the toast floats ``Layout/gap`` above it.
///
/// The view (`ToastHost`, in a pass-through overlay window above sheets, D-8) draws
/// ``current``, fades it out while ``leaving``, calls ``pause()``/``resume()`` on touch, and
/// ``performAction(of:)`` / ``dismiss(_:)`` from its buttons.
@MainActor
@Observable
public final class ToastCenter: ToastPresenting {
    /// A toast as shown (RN `ToastRecord`).
    public struct Record: Sendable, Identifiable {
        /// `"toast-N"`.
        public let id: String
        public let message: String
        public let tone: ToastTone
        public let action: ToastAction?
        /// The caller's life, if it gave one.
        public let duration: Duration?
        /// When it was presented, on the centre's clock.
        let shownAt: Duration

        init(id: String, options: ToastOptions, shownAt: Duration) {
            self.id = id
            message = options.message
            tone = options.tone
            action = options.action
            duration = options.duration
            self.shownAt = shownAt
        }

        /// The options it was shown with.
        public var options: ToastOptions {
            ToastOptions(message: message, tone: tone, action: action, duration: duration)
        }

        /// What VoiceOver says when it appears: the message, then
        /// `L10n.A11y.availableAction(label:)` when it has an action (RN :170-172).
        public var spokenText: String { ToastCenter.spokenText(for: options) }

        /// The action button's VoiceOver label: its own, else its visible label.
        public var actionAccessibilityLabel: String? {
            action.map { $0.accessibilityLabel ?? $0.label }
        }
    }

    /// The card's geometry and gestures (RN src/ui/components/Toast.tsx), for the view.
    public enum Layout {
        /// Between the toast and the bottom chrome, or the home indicator (`TOAST_GAP`).
        public static let gap: Double = 12
        /// A downward drag longer than this dismisses (`SWIPE_DISMISS`).
        public static let swipeDismissDistance: Double = 24
        /// The drag starts after this much mostly-vertical movement.
        public static let dragStartDistance: Double = 6
        /// The card is never wider (iPad).
        public static let maxWidth: Double = 480
    }

    /// A registration of bottom chrome; pass it back to ``unregisterChrome(_:)``.
    public struct ChromeRegistration: Hashable, Sendable {
        let token: Int
    }

    /// An error is never replaced before it has been on screen this long (RN `ERROR_HOLD_MS`).
    public nonisolated static let errorHold: Duration = .milliseconds(1500)
    /// The exit animation; the toast is removed after it (`duration.toastOut`, not shortened
    /// by Reduce Motion here: only the fade is).
    public nonisolated static let exitDuration: Duration = .milliseconds(Motion.duration.toastOut)
    /// The least life a toast gets back when a finger lifts (`delay.toast / 2`).
    public nonisolated static let resumeFloor: Duration = .milliseconds(Motion.delay.toast / 2)

    /// The toast on screen, leaving or not.
    public private(set) var current: Record?
    /// The exit animation is running; the toast goes once it ends.
    public private(set) var leaving = false
    /// VoiceOver is running: lives are doubled when a toast is presented. The app keeps it current.
    public var isVoiceOverRunning: Bool
    private var chrome: [(token: Int, height: Double)] = []

    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let stopwatch: ShellStopwatch
    @ObservationIgnored private let announce: @MainActor @Sendable (String) -> Void
    @ObservationIgnored private var nextNumber = 0
    @ObservationIgnored private var nextChromeToken = 0
    @ObservationIgnored private var pending: Record?
    @ObservationIgnored private var lifeTask: Task<Void, Never>?
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var leaveTask: Task<Void, Never>?
    /// The current toast's life: what is left of it, and when that started running (nil while
    /// paused). RN `lifeRef`, with `startedAt: 0` as nil.
    @ObservationIgnored private var lifeRemaining: Duration = .zero
    @ObservationIgnored private var lifeStartedAt: Duration?
    /// The toast whose action has run: an action runs once, even if tapped again while fading.
    @ObservationIgnored private var actedID: String?

    /// - Parameters:
    ///   - clock: the timers' clock.
    ///   - isVoiceOverRunning: whether VoiceOver runs at launch.
    ///   - announce: posts a queued VoiceOver announcement.
    public init(
        clock: any Clock<Duration> = ContinuousClock(),
        isVoiceOverRunning: Bool = false,
        announce: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) {
        self.clock = clock
        stopwatch = ShellStopwatch(clock)
        self.isVoiceOverRunning = isVoiceOverRunning
        self.announce = announce
    }

    /// The height of the focused screen's bottom chrome, or nil to float above the home indicator.
    public var chromeHeight: Double? { chrome.last?.height }

    /// The message, then "<label> available" when there is an action.
    public nonisolated static func spokenText(for options: ToastOptions) -> String {
        guard let action = options.action else { return options.message }
        return "\(options.message), \(L10n.A11y.availableAction(label: action.label))"
    }

    // MARK: ToastPresenting

    @discardableResult
    public func show(_ options: ToastOptions) -> String {
        nextNumber += 1
        let now = stopwatch.now
        let record = Record(id: "toast-\(nextNumber)", options: options, shownAt: now)

        if let shown = current, shown.tone == .error, now - shown.shownAt < Self.errorHold {
            // Wait behind the error. Of several waiting the newest wins, but an error is never
            // dropped for an info toast.
            if !(pending?.tone == .error && record.tone == .info) { pending = record }
            if holdTask == nil {
                let wait = Self.errorHold - (now - shown.shownAt)
                holdTask = Task { [weak self, clock] in
                    do { try await clock.sleep(for: wait) } catch { return }
                    self?.holdEnded()
                }
            }
            return record.id
        }

        present(record)
        return record.id
    }

    public func dismiss(_ id: String) {
        if pending?.id == id { pending = nil }
        leave(id)
    }

    // MARK: Host

    /// A finger is on the toast: its life stands still. Only while the life timer runs.
    public func pause() {
        guard let lifeTask, let startedAt = lifeStartedAt else { return }
        lifeTask.cancel()
        self.lifeTask = nil
        lifeRemaining = max(.zero, lifeRemaining - (stopwatch.now - startedAt))
        lifeStartedAt = nil
    }

    /// The finger lifted: the life runs again, never less than 2.5 s. Only after ``pause()``.
    public func resume() {
        guard let shown = current, lifeTask == nil, lifeStartedAt == nil else { return }
        startLife(shown.id, max(lifeRemaining, Self.resumeFloor))
    }

    /// The action button: runs the toast's action once, then dismisses it. Not while leaving
    /// (the button is disabled then).
    public func performAction(of id: String) {
        guard let shown = current, shown.id == id, !leaving, actedID != id, let action = shown.action else { return }
        actedID = id
        action.handler()
        dismiss(id)
    }

    /// Registers bottom chrome the toast has to clear; the latest registration wins. Register
    /// only a positive height, and only while the screen is focused; take it back when it loses
    /// focus (RN `useBottomChrome`).
    public func registerChrome(height: Double) -> ChromeRegistration {
        nextChromeToken += 1
        chrome.append((nextChromeToken, height))
        return ChromeRegistration(token: nextChromeToken)
    }

    /// Takes a registration back.
    public func unregisterChrome(_ registration: ChromeRegistration) {
        chrome.removeAll { $0.token == registration.token }
    }

    // MARK: Lifecycle

    private func present(_ record: Record) {
        leaveTask?.cancel()
        leaveTask = nil
        let shown = Record(id: record.id, options: record.options, shownAt: stopwatch.now)
        current = shown
        leaving = false

        let base = record.options.baseDuration
        startLife(shown.id, isVoiceOverRunning ? base * 2 : base)
        announce(shown.spokenText)
    }

    private func holdEnded() {
        holdTask = nil
        let next = pending
        pending = nil
        if let next { present(next) }
    }

    private func startLife(_ id: String, _ life: Duration) {
        lifeTask?.cancel()
        lifeRemaining = life
        lifeStartedAt = stopwatch.now
        lifeTask = Task { [weak self, clock] in
            do { try await clock.sleep(for: life) } catch { return }
            self?.lifeEnded(id)
        }
    }

    private func lifeEnded(_ id: String) {
        lifeTask = nil
        leave(id)
    }

    private func leave(_ id: String) {
        guard current?.id == id else { return }
        lifeTask?.cancel()
        lifeTask = nil
        leaving = true
        leaveTask?.cancel()
        leaveTask = Task { [weak self, clock] in
            do { try await clock.sleep(for: Self.exitDuration) } catch { return }
            self?.remove(id)
        }
    }

    private func remove(_ id: String) {
        guard current?.id == id else { return }
        leaveTask = nil
        current = nil
        leaving = false
    }
}
