/// Motion lengths, waits and curves, in one place (RN src/ui/motion.ts; 08 §8).
///
/// Two kinds of number, and Reduce Motion treats them differently:
/// - ``Durations`` are motion. Under Reduce Motion every one of them becomes 0
///   (``duration(reduceMotion:)``, RN `motionMs`), and code that would animate a layout
///   change does not animate at all.
/// - ``Delays`` are timing, not motion, and Reduce Motion leaves them alone: a skeleton still
///   waits 180 ms so fast reads never flash, a toast still lasts 5 s.
///
/// All values are milliseconds, as in RN; sleep on a clock with `.milliseconds(value)`.
public enum Motion {
    /// Motion lengths in ms (RN `duration`). All become 0 under Reduce Motion.
    public struct Durations: Sendable, Hashable {
        /// Unused in RN.
        public let press: Int
        /// Toast appearing: fade in and an 8 pt rise, `Easing.out`.
        public let toastIn: Int
        /// Toast leaving: fade out, `Easing.exit`; the toast is removed after this long.
        public let toastOut: Int
        /// A layout change (a row expanding or leaving a list), ease-in-out.
        public let expand: Int
        /// The Add form's step fade.
        public let stepSwap: Int
        /// How long the scanner holds the locked reticle before acting.
        public let reticleLock: Int
        /// Unused in RN (the camera's focus square has its own 700 ms).
        public let focusSpot: Int
        /// The shutter's white flash (half in, half out).
        public let shutterFlash: Int

        /// The lengths, or all zeros when `reduceMotion` is on.
        public init(reduceMotion: Bool = false) {
            func length(_ ms: Int) -> Int { Motion.motionMs(ms, reduced: reduceMotion) }
            press = length(100)
            toastIn = length(160)
            toastOut = length(120)
            expand = length(180)
            stepSwap = length(180)
            reticleLock = length(250)
            focusSpot = length(700)
            shutterFlash = length(120)
        }
    }

    /// Waits in ms (RN `delay`). Reduce Motion does not change them.
    public struct Delays: Sendable, Hashable {
        /// Show a skeleton or spinner only once loading has lasted this long.
        public let skeleton = 180
        /// A button's spinner joins its label after this long.
        public let spinner = 150
        /// The boot screen's caption appears after this long.
        public let bootCaption = 400
        /// The connection retry delay.
        public let reconnect = 2500
        /// Search debounce (0 when the trimmed query equals the settled one).
        public let searchDebounce = 200
        /// Older search results give way to a skeleton after this long.
        public let searchSkeleton = 600
        /// A toast's life (doubled while VoiceOver runs; at least half of it after a touch).
        public let toast = 5000
        /// A toast's life when it has an action (doubled while VoiceOver runs).
        public let toastWithAction = 9000
        /// Hold before the stepper starts repeating.
        public let stepRepeat = 400
        /// The stepper's repeat interval.
        public let stepRepeatEvery = 80

        public init() {}
    }

    /// A cubic Bézier timing curve through (0, 0), (x1, y1), (x2, y2), (1, 1), as SwiftUI's
    /// `.timingCurve(x1, y1, x2, y2, duration:)` takes it.
    public struct Curve: Sendable, Hashable {
        public let x1: Double
        public let y1: Double
        public let x2: Double
        public let y2: Double

        public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
            self.x1 = x1
            self.y1 = y1
            self.x2 = x2
            self.y2 = y2
        }
    }

    /// RN `easing`.
    public enum Easing {
        /// `Easing.bezier(0.2, 0.8, 0.2, 1)`: the photo viewer settling.
        public static let settle = Curve(0.2, 0.8, 0.2, 1)
        /// `Easing.out(Easing.cubic)`, 1 − (1 − t)³, as its usual Bézier fit (08 §8.1): things arriving.
        public static let out = Curve(0.33, 1, 0.68, 1)
        /// `Easing.bezier(0.4, 0, 1, 1)`: things leaving.
        public static let exit = Curve(0.4, 0, 1, 1)
    }

    /// The motion lengths with Reduce Motion off.
    public static let duration = Durations()

    /// The waits.
    public static let delay = Delays()

    /// The motion lengths for the current Reduce Motion setting.
    public static func duration(reduceMotion: Bool) -> Durations {
        Durations(reduceMotion: reduceMotion)
    }

    /// A motion length, or 0 when the person asked for less motion (RN `motionMs`).
    public static func motionMs(_ ms: Int, reduced: Bool) -> Int {
        reduced ? 0 : ms
    }
}
