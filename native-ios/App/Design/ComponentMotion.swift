import SwiftUI
import InventoryAppModels

/// The animations the shared components run, computed from RN's motion tokens (08 §8;
/// `Motion`). Under Reduce Motion every one of them is nil or zero, so the change is instant: a
/// chip's stepper appears without the fade, a toast shows without its rise, a short swipe on a
/// toast snaps back without a spring. Delays (the skeleton's wait, the button spinner) are
/// timing, not motion, and are not touched (08 §8.2).
enum ComponentMotion {
    /// RN `animateNextLayout` (180 ms ease-in-out): a row expanding its quantity controls.
    static func expand(reduceMotion: Bool) -> Animation? {
        curve(ms: Motion.duration(reduceMotion: reduceMotion).expand) { .easeInOut(duration: $0) }
    }

    /// The toast's fade-in and rise (RN `toastIn`, 160 ms, `easing.out`).
    static func toastIn(reduceMotion: Bool) -> Animation? {
        curve(Motion.Easing.out, ms: Motion.duration(reduceMotion: reduceMotion).toastIn)
    }

    /// The toast's fade-out (RN `toastOut`, 120 ms, `easing.exit`).
    static func toastOut(reduceMotion: Bool) -> Animation? {
        curve(Motion.Easing.exit, ms: Motion.duration(reduceMotion: reduceMotion).toastOut)
    }

    /// How far a toast rises as it appears (RN: 8 pt, starting at 0 when reduced).
    static func toastRise(reduceMotion: Bool) -> CGFloat {
        reduceMotion ? 0 : 8
    }

    /// A toast dragged less than the dismiss distance going back (RN: a spring, none when
    /// reduced).
    static func toastSettle(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring
    }

    /// A `Motion` curve over `ms` milliseconds; nil for 0 ms (Reduce Motion).
    static func curve(_ curve: Motion.Curve, ms: Int) -> Animation? {
        self.curve(ms: ms) { .timingCurve(curve.x1, curve.y1, curve.x2, curve.y2, duration: $0) }
    }

    private static func curve(ms: Int, _ make: (TimeInterval) -> Animation) -> Animation? {
        ms > 0 ? make(Double(ms) / 1000) : nil
    }
}
