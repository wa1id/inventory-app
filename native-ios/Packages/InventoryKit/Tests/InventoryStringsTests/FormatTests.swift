import Foundation
import Testing
@testable import InventoryStrings

// Port of src/i18n/__tests__/format.test.ts, plus the Swift-only checks of
// spec 08 §11 (e) and (f) and the vectors generated from format.ts.

@Suite("plural")
struct PluralTests {
    @Test("picks the form by count")
    func picksTheFormByCount() {
        #expect(Format.plural(1, "item", "items") == "1 item")
        #expect(Format.plural(0, "item", "items") == "0 items")
        #expect(Format.plural(3, "item", "items") == "3 items")
    }
}

@Suite("sentenceList")
struct SentenceListTests {
    @Test("joins like a sentence, without a serial comma")
    func joinsLikeASentenceWithoutASerialComma() {
        #expect(Format.sentenceList([]) == "")
        #expect(Format.sentenceList(["a"]) == "a")
        #expect(Format.sentenceList(["a", "b"]) == "a and b")
        #expect(Format.sentenceList(["a", "b", "c"]) == "a, b and c")
    }
}

private let minute: Int64 = 60_000
private let hour = 60 * minute
private let day = 24 * hour

/// The `it.each` table of format.test.ts: elapsed milliseconds and the words.
private let agoCases: [(Int64, String)] = [
        (Int64(0), "just now"),
        (59_000, "just now"),
        (minute, "1 minute ago"),
        (5 * minute, "5 minutes ago"),
        (hour, "1 hour ago"),
        (3 * hour, "3 hours ago"),
        (day, "yesterday"),
        (47 * hour, "yesterday"),
        (2 * day, "2 days ago"),
        (29 * day, "29 days ago"),
        (30 * day, "1 month ago"),
        (64 * day, "2 months ago"),
        (365 * day, "1 year ago"),
        (800 * day, "2 years ago"),
    ]

@Suite("ago")
struct AgoTests {
    /// `Date.UTC(2026, 9, 2, 12)`.
    static let now: Int64 = 1_790_942_400_000

    @Test("%p ms ago reads %p", arguments: agoCases)
    func msAgoReads(elapsed: Int64, expected: String) {
        #expect(Format.ago(Self.now - elapsed, now: Self.now) == expected)
    }

    @Test("reads a time from a phone with a fast clock as just now")
    func readsAFastClockAsJustNow() {
        #expect(Format.ago(Self.now + 5 * minute, now: Self.now) == "just now")
    }

    @Test("keeps format.ts's bucket edges")
    func bucketEdges() {
        #expect(Format.ago(Self.now - (2 * day - 1), now: Self.now) == "yesterday")
        #expect(Format.ago(Self.now - 360 * day, now: Self.now) == "12 months ago")
        #expect(Format.ago(Self.now - 364 * day, now: Self.now) == "12 months ago")
        #expect(Format.ago(Self.now - (hour - 1), now: Self.now) == "59 minutes ago")
    }

    @Test("does not trap on extreme times")
    func extremeTimes() {
        #expect(Format.ago(.min, now: Self.now).hasSuffix("years ago"))
        #expect(Format.ago(.max, now: Self.now) == "just now")
    }

    @Test("takes Dates as well as milliseconds")
    func dates() {
        let now = Date(timeIntervalSince1970: Double(Self.now) / 1000)
        #expect(Format.ago(now.addingTimeInterval(-3 * 3600), now: now) == "3 hours ago")
    }
}

@Suite("longDate")
struct LongDateTests {
    @Test("formats en-GB with the month spelled out")
    func formatsEnGBWithTheMonthSpelledOut() {
        // Noon UTC is 2 September in every time zone within ±11 hours, as in the RN test.
        #expect(Format.longDate(1_788_350_400_000) == "2 September 2026")
    }

    @Test("pins the Gregorian calendar and en-GB, whatever the device uses")
    func pinsCalendarAndLocale() {
        let style = Format.longDateStyle(timeZone: .gmt)
        #expect(style.calendar.identifier == .gregorian)
        #expect(style.locale.identifier == "en_GB")
        let buddhist = Date.FormatStyle(
            date: .omitted, time: .omitted, locale: Locale(identifier: "en_GB"),
            calendar: Calendar(identifier: .buddhist), timeZone: .gmt
        ).day().month(.wide).year()
        let date = Date(timeIntervalSince1970: 1_788_350_400)
        #expect(date.formatted(buddhist) != date.formatted(style))
        #expect(date.formatted(style) == "2 September 2026")
    }
}

@Suite("format.ts vectors")
struct FormatVectorTests {
    static let vectors = StringsFixture.shared.format

    @Test("plural matches format.ts")
    func plural() {
        for v in Self.vectors.plural {
            #expect(sameText(Format.plural(v.count, v.one, v.other), v.expected), "plural(\(v.count))")
        }
    }

    @Test("sentenceList matches format.ts")
    func sentenceList() {
        for v in Self.vectors.sentenceList {
            #expect(sameText(Format.sentenceList(v.parts), v.expected), "\(v.parts)")
        }
    }

    @Test("ago matches format.ts")
    func ago() {
        for v in Self.vectors.ago {
            #expect(sameText(Format.ago(v.ms, now: v.now), v.expected), "ago(\(v.ms), now: \(v.now))")
        }
    }

    @Test("longDate matches Intl.DateTimeFormat('en-GB') in every time zone")
    func longDate() throws {
        for v in Self.vectors.longDate {
            let zone = try #require(TimeZone(identifier: v.timeZone))
            let actual = Format.longDate(v.ms, timeZone: zone)
            #expect(sameText(actual, v.expected), "longDate(\(v.ms)) in \(v.timeZone) gave \(actual)")
        }
    }
}
