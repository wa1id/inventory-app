import Observation
import InventoryStorage

/// Home's "This phone keeps its own inventory" notice, for a phone that has not joined the
/// household (RN `useUnpairedNotice`, src/ui/home/unpairedNotice.ts; 04 §12.8, 06 §5.5).
///
/// It keeps a phone from quietly growing an inventory of its own, and "Not now" puts it away
/// for good on this phone (`notice.unpaired.dismissed.v1` = `"1"`). Hidden until the preference
/// has been read, so it never flashes up and away. Home draws it as an info banner: title
/// `L10n.Home.Unpaired.title`, body `.body`, action `.join` (opens Household), secondary
/// `L10n.Common.notNow` with the hint `L10n.Home.Unpaired.notNowHint`.
@MainActor
@Observable
public final class UnpairedNoticeModel {
    /// nil until the preference has been read; a tap on "Not now" is never overridden by it.
    public private(set) var dismissed: Bool?

    @ObservationIgnored private let preference: UnpairedNoticePreference

    public init(preference: UnpairedNoticePreference) {
        self.preference = preference
    }

    /// Reads the preference (RN's mount effect, unpairedNotice.ts:19-32). Call it when Home
    /// appears: preferences are read only after the legacy import has run (09 §3.2).
    public func load() {
        if dismissed == nil { dismissed = preference.isDismissed }
    }

    /// "Not now": hides the notice at once and remembers it on this phone
    /// (RN unpairedNotice.ts:34-39).
    public func dismiss() {
        dismissed = true
        preference.dismiss()
    }

    /// RN `visible = !paired && dismissed === false`.
    public func isVisible(paired: Bool) -> Bool {
        !paired && dismissed == false
    }
}
