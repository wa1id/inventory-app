/// One label, one answer: the QR scanner's arming rules (06 §8.4; RN `QrScanner.tsx:86-137`).
///
/// - **One scan per arming.** Each focus, and each time the host re-activates the scanner, is a
///   new arming. A read that is accepted pauses the arming it happened in, synchronously, so the
///   second and third frames of the same label are ignored rather than opening the container
///   three times. ``accept(_:)`` sets the guard before anything is awaited.
/// - **The same label after coming back.** On focus, the code handed over last is ignored as long
///   as it keeps being seen within 1500 ms of the previous sighting (each sighting refreshes the
///   time): Back from the container it opened usually finds that label still under the camera. A
///   different code, or the same one after 1500 ms out of view, ends the ignore. Re-activation
///   ("Scan again") does not set it, so the same label is accepted again.
///
/// DataScanner delivers repeated callbacks too, so the app keeps these rules on the main actor.
@MainActor
public final class ScanGuard {
    /// How long a label must be out of view after refocusing before it opens again (RN `SAME_CODE_GAP`).
    public static let sameCodeGap: Duration = .milliseconds(1500)

    /// The current arming (RN `arming`).
    public private(set) var arming = 0
    /// The arming a code was accepted in (RN `scannedRef`).
    private var scannedIn = -1
    /// The last code handed over (RN `handedRef`).
    public private(set) var handed: String?
    /// After a refocus, the code to ignore and when it was last seen (RN `ignoreRef`).
    private var ignore: (data: String, seen: Duration)?
    private let stopwatch: Stopwatch

    public init(clock: any Clock<Duration> = ContinuousClock()) {
        stopwatch = Stopwatch(clock)
    }

    /// The scanner takes codes now: nothing was accepted in this arming yet (RN `armed`).
    public var isArmed: Bool { scannedIn != arming }

    /// The code being ignored after a refocus, if any.
    public var ignoredCode: String? { ignore?.data }

    /// The screen gained focus: a new arming, ignoring the last code handed over.
    // RN: src/ui/components/QrScanner.tsx:102-109
    public func focused() {
        arming += 1
        ignore = handed.map { (data: $0, seen: stopwatch.now) }
    }

    /// The host turned the scanner back on (`active` false → true): a new arming, no ignore.
    // RN: src/ui/components/QrScanner.tsx:96-100
    public func reactivated() {
        arming += 1
    }

    /// The scanner was taken down and shown again (RN unmounted `QrScanner` and mounted a fresh
    /// one, e.g. around the Scan tab's code list): a new arming, and nothing handed over or
    /// ignored any more, as the new instance's refs started empty.
    // RN: app/(tabs)/scan.tsx:271-291 (no QrScanner in the code phase)
    public func reset() {
        arming += 1
        handed = nil
        ignore = nil
    }

    /// Whether a sighting of `data` should be handed over. True at most once per arming; marks the
    /// arming used and remembers `data` as handed. While disarmed nothing happens at all, not even
    /// a refresh of the ignored code's sighting time (RN passed the camera no scan callback then).
    // RN: src/ui/components/QrScanner.tsx:113-128
    public func accept(_ data: String) -> Bool {
        // RN passes no scan callback to the camera while disarmed, so nothing else happens.
        guard isArmed else { return false }
        if let ignore {
            let now = stopwatch.now
            // Still in view (seen within the gap): keep ignoring it. A different code, or the same
            // one after it left the frame, ends the ignore.
            if ignore.data == data && now - ignore.seen < Self.sameCodeGap {
                self.ignore = (data: data, seen: now)
                return false
            }
            self.ignore = nil
        }
        scannedIn = arming
        handed = data
        return true
    }
}
