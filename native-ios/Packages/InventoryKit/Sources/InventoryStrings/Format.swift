import Foundation

/// English formatting rules for copy: a port of src/i18n/format.ts.
///
/// Dates and lists are pinned to en-GB as in the RN app (DECISIONS U9). Counts
/// are never grouped (`"1234 items"`), like JS template literals.
public enum Format {
    static let minute: Int64 = 60_000
    static let hour: Int64 = 60 * minute
    static let day: Int64 = 24 * hour

    /// `plural(3, "item", "items")` → "3 items". `one` is used for exactly 1, so 0 reads "0 items".
    public static func plural(_ count: Int, _ one: String, _ other: String) -> String {
        "\(count) \(count == 1 ? one : other)"
    }

    /// "a", "a and b", "a, b and c": no serial comma (en-GB), "" for no parts.
    ///
    /// Copy with a fixed number of parts bakes the joiner into its catalog entry
    /// instead (spec 08 §2.2(11)); this is the runtime helper format.ts exports.
    public static func sentenceList(_ parts: [String]) -> String {
        guard parts.count > 1, let last = parts.last else { return parts.first ?? "" }
        return "\(parts.dropLast().joined(separator: ", ")) and \(last)"
    }

    /// How long ago, in words: "just now", "5 minutes ago", "yesterday", "2 months ago".
    ///
    /// Both times are epoch milliseconds, the unit of `created_at` and `updated_at`.
    /// A time in the future (clock skew between phones) reads "just now". The buckets
    /// are format.ts's, not the calendar's: "yesterday" is 24 to 48 hours ago, a month
    /// is 30 days (so 360 to 364 days read "12 months ago") and a year is 365 days.
    public static func ago(_ ms: Int64, now: Int64 = nowMilliseconds()) -> String {
        let (difference, overflow) = now.subtractingReportingOverflow(ms)
        let diff = overflow ? (ms < now ? Int64.max : 0) : max(0, difference)
        if diff < minute { return AgoKeys.justNow }
        if diff < hour { return AgoKeys.minutes(count: Int(diff / minute)) }
        if diff < day { return AgoKeys.hours(count: Int(diff / hour)) }
        if diff < 2 * day { return AgoKeys.yesterday }
        let days = diff / day
        if days < 30 { return AgoKeys.days(count: Int(days)) }
        if days < 365 { return AgoKeys.months(count: Int(days / 30)) }
        return AgoKeys.years(count: Int(days / 365))
    }

    /// `ago(_:now:)` for `Date` values, truncated to whole milliseconds.
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        ago(milliseconds(date), now: milliseconds(now))
    }

    /// "2 September 2026": en-GB, Gregorian, in the device time zone.
    public static func longDate(_ ms: Int64) -> String {
        longDate(ms, timeZone: .current)
    }

    static func longDate(_ ms: Int64, timeZone: TimeZone) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000).formatted(longDateStyle(timeZone: timeZone))
    }

    /// Pins the calendar as well as the locale: `Date.FormatStyle` otherwise follows
    /// the device calendar (a Buddhist or Japanese year), while RN's
    /// `Intl.DateTimeFormat('en-GB')` is always Gregorian.
    static func longDateStyle(timeZone: TimeZone) -> Date.FormatStyle {
        Date.FormatStyle(
            date: .omitted,
            time: .omitted,
            locale: Locale(identifier: "en_GB"),
            calendar: Calendar(identifier: .gregorian),
            timeZone: timeZone
        )
        .day()
        .month(.wide)
        .year()
    }

    /// `Date.now()` in JS: whole epoch milliseconds.
    @usableFromInline
    static func nowMilliseconds() -> Int64 {
        milliseconds(Date())
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
}
