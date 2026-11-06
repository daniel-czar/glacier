import Foundation
@testable import OmniCore
import Testing

// `/span` (C82, spec 98b6b449394ee04e): the golden blocks are pinned byte for
// byte, including the en dash in the echo and `≈` only on `k`/`M` lines.

private let utc = TimeZone(secondsFromGMT: 0)!
/// Sunday 11 Oct 2026, 12:00 on the injected clock.
private let fixedNow: Date = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    return calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 12, minute: 0))!
}()

private func span(_ payload: String) -> SpanResult? {
    SpanCalculator.result(payload: payload, now: fixedNow, timeZone: utc)
}

private func block(_ payload: String) -> String? { span(payload)?.block }

private let twoYears = """
Total period: 2 years (1 Oct 2014 – 30 Sep 2016, both days counted)
= 2.00 years
= 24.0 months
= 104 weeks
= 731 days
≈ 17.5k hours
"""

private let overnight = """
Total period: 1 day, 14 hours, 47 minutes (24 Oct 2026 23:59 – 26 Oct 2026 14:46)
= 1.62 days
= 38.8 hours
= 2,327 minutes
"""

// MARK: Golden blocks (spec section 7)

@Test func goldenTwoYearPeriodCountsBothDays() {
    #expect(block("1 october 2014 to 30 september 2016") == twoYears)
}

@Test func goldenElapsedTimesInferTheYearAndIgnoreDaylightSaving() {
    #expect(block("24 october 23:59 to 26 october 14:46") == overnight)
    // BST ends on 25 Oct 2026; the wall clock is what counts (section 4).
    #expect(block("24 oct 2026 23:59 to 26 oct 2026 14:46") == overnight)
}

@Test func goldenExclusivePeriodIsThePlainDifference() {
    #expect(block("1 october 2014 to 30 september 2016 excl") == """
    Total period: 1 year, 11 months, 29 days (1 Oct 2014 – 30 Sep 2016, last day not counted)
    = 2.00 years
    = 24.0 months
    = 104 weeks
    = 730 days
    ≈ 17.5k hours
    """)
    #expect(block("1 october 2014 to 30 september 2016 exclusive") == block("1 october 2014 to 30 september 2016 excl"))
}

@Test func goldenYearlessRangeRunsIntoTheNextYear() {
    #expect(block("24 dec to 2 jan") == """
    Total period: 10 days (24 Dec 2026 – 2 Jan 2027, both days counted)
    = 1.43 weeks
    = 10 days
    = 240 hours
    """)
}

@Test func goldenOneDateRunsUntilToday() {
    #expect(block("14 march 1990") == """
    Total period: 36 years, 6 months, 27 days (14 Mar 1990 – today)
    = 36.6 years
    = 439 months
    = 1,909 weeks
    = 13,360 days
    ≈ 321k hours
    """)
}

@Test func equivalentSpellingsProduceTheFirstBlockVerbatim() {
    for payload in [
        "2014-10-01 – 30.09.2016",
        "1. Oktober 2014 bis 30. September 2016",
        "30 sep 2016 to 1 oct 2014",
        "1 october 2014\n30 september 2016",
        "1 Oct 2014 - 30 Sep 2016 incl",
        "1/10/2014 → 30/9/2016",
        "october 1, 2014 until september 30, 2016",
        "1 oct 2014 -> 30 sep 2016 inclusive",
        "01.10.2014 / 30.09.2016",
        "1 oct 2014 till 30 sep 2016",
        "1 oct 2014 — 30 sep 2016",
        "October 1st, 2014 to September 30th, 2016",
        "1st of october 2014 to 30th of september 2016",
    ] {
        #expect(block(payload) == twoYears, "\(payload)")
    }
}

// MARK: Pinned edge cases

@Test func aSameDayPeriodIsOneDay() {
    #expect(block("5 may 2026 to 5 may 2026") == """
    Total period: 1 day (5 May 2026 – 5 May 2026, both days counted)
    = 1 day
    = 24 hours
    """)
    // Exclusive, nothing is left: the breakdown says so and no line follows.
    #expect(block("5 may 2026 to 5 may 2026 excl") == "Total period: 0 days (5 May 2026 – 5 May 2026, last day not counted)")
}

@Test func aLeapDayRangeKeepsFoundationsBreakdown() {
    // Foundation counts 29 Feb 2024 + 1 year as 28 Feb 2025, then one more day.
    #expect(block("29 feb 2024 to 28 feb 2025") == """
    Total period: 1 year, 1 day (29 Feb 2024 – 28 Feb 2025, both days counted)
    = 1.00 years
    = 12.0 months
    = 52.3 weeks
    = 366 days
    = 8,784 hours
    """)
}

@Test func aMonthEndRangeKeepsFoundationsClamping() {
    // 31 Jan + 1 month clamps to 28 Feb in Foundation; the inclusive end
    // (1 Mar) is one day later. Pinned for stability, not hand-rolled.
    #expect(block("31 jan 2026 to 28 feb 2026") == """
    Total period: 1 month, 1 day (31 Jan 2026 – 28 Feb 2026, both days counted)
    = 4.14 weeks
    = 29 days
    = 696 hours
    """)
}

@Test func tomorrowIsAKeywordAgainstTheInjectedClock() {
    #expect(block("tomorrow") == """
    Total period: 1 day (today – 12 Oct 2026)
    = 1 day
    = 24 hours
    """)
}

@Test func aFutureDateCountsDaysUntilIt() {
    #expect(block("24 dec") == """
    Total period: 2 months, 13 days (today – 24 Dec 2026)
    = 2.43 months
    = 10.6 weeks
    = 74 days
    = 1,776 hours
    """)
}

@Test func aDateWithATimeRunsUntilNow() {
    #expect(block("11 oct 2026 10:30") == """
    Total period: 1 hour, 30 minutes (11 Oct 2026 10:30 – now)
    = 1.50 hours
    = 90 minutes
    """)
    #expect(block("now") == "Total period: 0 minutes (11 Oct 2026 12:00 – now)")
}

@Test func minutesFromTenThousandUseTheSuffixRule() {
    // Agent-owned reading of section 6: elapsed minutes are exact below
    // 10,000 and take `k`/`M` from there, like hours.
    #expect(block("1 oct 2026 00:00 to 15 oct 2026 12:20") == """
    Total period: 14 days, 12 hours, 20 minutes (1 Oct 2026 00:00 – 15 Oct 2026 12:20)
    = 2.07 weeks
    = 14.5 days
    = 348 hours
    ≈ 20.9k minutes
    """)
}

@Test func yearInferenceFollowsTheTypedYearAndSwapsSilently() {
    // Only one endpoint lacks a year: it takes the other's, then the span
    // is unsigned and echoed in chronological order.
    #expect(span("24 dec to 2 jan 2027")?.block.hasPrefix("Total period: 11 months, 23 days (2 Jan 2027 – 24 Dec 2027, both days counted)") == true)
    // Same day, end time earlier: a swap, never a jump into next year.
    #expect(block("24 oct 18:00 to 24 oct 09:00") == """
    Total period: 9 hours (24 Oct 2026 09:00 – 24 Oct 2026 18:00)
    = 9 hours
    = 540 minutes
    """)
    // A plain date beside a timed one is midnight; only the timed one echoes a time.
    #expect(span("1 oct 2026 to 3 oct 2026 12:00")?.block.hasPrefix("Total period: 2 days, 12 hours (1 Oct 2026 – 3 Oct 2026 12:00)") == true)
}

@Test func timesStayOnTheWallClockWhateverWordsSurroundThem() {
    // 29 Mar 2026 is the UK's spring-forward day; typed times are civil.
    #expect(span("29 mar 2026 at 1am to 29 mar 2026 3:00")?.minuteCount == 120)
    #expect(span("29 mar 2026 at 1:30am to 29 mar 2026 3:00")?.minuteCount == 90)
    #expect(span("29 feb at 9am to 1 mar 2028")?.block.hasPrefix("Total period: 15 hours (29 Feb 2028 09:00 – 1 Mar 2028)") == true)
    // A time in words after a date is refused, never converted.
    #expect(span("29 mar 2026 at one am") == nil)
    // A detector phrase with a typed clock keeps that clock (system clock).
    let friday = SpanCalculator.result(payload: "next friday 10:00 am")
    #expect(friday?.query.mode == .elapsed)
    #expect(friday?.query.end.time == SpanTime(hour: 10, minute: 0))
    #expect(SpanCalculator.result(payload: "next friday at noon")?.query.end.time == SpanTime(hour: 12, minute: 0))
}

@Test func aWeekdayBeforeADateNeverHandsTheYearToTheDetector() {
    // Both yearless: the end runs into next year, as `24 oct to 2 jan` does.
    #expect(span("sat 24 oct to 2 jan")?.dayCount == 71)
    #expect(span("sat 24 oct to 2 jan")?.query.start == SpanEndpoint(year: 2026, month: 10, day: 24))
    // One yearless: it takes the other's year.
    #expect(span("wednesday 3 march to 1 jun 2026")?.dayCount == 91)
    // The day is checked against the year the rule gives.
    #expect(span("tuesday 29 feb to 1 mar 2028")?.dayCount == 2)
    #expect(span("tuesday 29 feb to 1 mar 2028")?.query.start == SpanEndpoint(year: 2028, month: 2, day: 29))
}

@Test func ordinalsFollowTheYearInferenceRule() {
    // An ordinal never hands the year to the detector's guess.
    #expect(block("1st jan") == block("1 jan"))
    #expect(span("1st jan")?.query.start == SpanEndpoint(year: 2026, month: 1, day: 1))
    #expect(span("march 3rd to 1 jun 2026")?.block.hasPrefix("Total period: 2 months, 30 days (3 Mar 2026 – 1 Jun 2026, both days counted)") == true)
    #expect(span("march 3rd to 1 jun 2026")?.dayCount == 91)
}

@Test func theFooterHeadlineConfirmsTheParse() {
    #expect(span("1 october 2014 to 30 september 2016")?.headline == "1 Oct 2014 – 30 Sep 2016 · 2 years · 731 days")
    #expect(span("24 october 23:59 to 26 october 14:46")?.headline == "24 Oct 2026 23:59 – 26 Oct 2026 14:46 · 1 day, 14 h, 47 min · 38.8 hours")
    #expect(span("14 march 1990")?.headline == "14 Mar 1990 – today · 36 years, 6 months, 27 days · 13,360 days")
    #expect(span("11 oct 2026 11:59")?.headline == "11 Oct 2026 11:59 – now · 1 min · 1 minute")
}

// MARK: Grammar table (spec section 4)

@Test func everyEndpointFormParses() {
    let parser = SpanParser(now: fixedNow, timeZone: utc)
    let table: [(String, TypedEndpoint)] = [
        ("1 october 2014", TypedEndpoint(year: 2014, month: 10, day: 1)),
        ("1 oct 2014", TypedEndpoint(year: 2014, month: 10, day: 1)),
        ("1. oktober 2014", TypedEndpoint(year: 2014, month: 10, day: 1)),
        ("24 october", TypedEndpoint(year: nil, month: 10, day: 24)),
        ("24. okt", TypedEndpoint(year: nil, month: 10, day: 24)),
        ("24. okt.", TypedEndpoint(year: nil, month: 10, day: 24)),
        ("october 1, 2014", TypedEndpoint(year: 2014, month: 10, day: 1)),
        ("october 1 2014", TypedEndpoint(year: 2014, month: 10, day: 1)),
        ("oct 1", TypedEndpoint(year: nil, month: 10, day: 1)),
        ("2014-10-01", TypedEndpoint(year: 2014, month: 10, day: 1)),
        ("01.10.2014", TypedEndpoint(year: 2014, month: 10, day: 1)),
        ("24.10.", TypedEndpoint(year: nil, month: 10, day: 24)),
        ("24.10", TypedEndpoint(year: nil, month: 10, day: 24)),
        ("1/10/2014", TypedEndpoint(year: 2014, month: 10, day: 1)),
        ("24/10", TypedEndpoint(year: nil, month: 10, day: 24)),
        ("today", TypedEndpoint(year: 2026, month: 10, day: 11)),
        ("yesterday", TypedEndpoint(year: 2026, month: 10, day: 10)),
        ("tomorrow", TypedEndpoint(year: 2026, month: 10, day: 12)),
        ("now", TypedEndpoint(year: 2026, month: 10, day: 11, time: SpanTime(hour: 12, minute: 0))),
        ("tomorrow 9am", TypedEndpoint(year: 2026, month: 10, day: 12, time: SpanTime(hour: 9, minute: 0))),
        ("24 october 23:59", TypedEndpoint(year: nil, month: 10, day: 24, time: SpanTime(hour: 23, minute: 59))),
        ("1 oct 2014 7:05", TypedEndpoint(year: 2014, month: 10, day: 1, time: SpanTime(hour: 7, minute: 5))),
        ("1 oct 2014 2pm", TypedEndpoint(year: 2014, month: 10, day: 1, time: SpanTime(hour: 14, minute: 0))),
        ("1 oct 2014 9:30 am", TypedEndpoint(year: 2014, month: 10, day: 1, time: SpanTime(hour: 9, minute: 30))),
        ("1 oct 2014 12am", TypedEndpoint(year: 2014, month: 10, day: 1, time: SpanTime(hour: 0, minute: 0))),
        ("1 oct 2014 12 pm", TypedEndpoint(year: 2014, month: 10, day: 1, time: SpanTime(hour: 12, minute: 0))),
        ("2014-10-01 14:00", TypedEndpoint(year: 2014, month: 10, day: 1, time: SpanTime(hour: 14, minute: 0))),
        ("1 sept 2026", TypedEndpoint(year: 2026, month: 9, day: 1)),
        ("3 märz 2026", TypedEndpoint(year: 2026, month: 3, day: 3)),
        ("3 ma\u{0308}rz 2026".precomposedStringWithCanonicalMapping, TypedEndpoint(year: 2026, month: 3, day: 3)),
        ("3 maerz 2026", TypedEndpoint(year: 2026, month: 3, day: 3)),
        ("3 mär 2026", TypedEndpoint(year: 2026, month: 3, day: 3)),
        ("5 mai 2026", TypedEndpoint(year: 2026, month: 5, day: 5)),
        ("24 dez", TypedEndpoint(year: nil, month: 12, day: 24)),
        ("1 dezember 2026", TypedEndpoint(year: 2026, month: 12, day: 1)),
        ("1 januar 2026", TypedEndpoint(year: 2026, month: 1, day: 1)),
        ("1st oct 2014", TypedEndpoint(year: 2014, month: 10, day: 1)),
        ("1st of march 2026", TypedEndpoint(year: 2026, month: 3, day: 1)),
        ("march 3rd", TypedEndpoint(year: nil, month: 3, day: 3)),
        ("oct 22nd, 2014", TypedEndpoint(year: 2014, month: 10, day: 22)),
        // The time part may follow `,`, `at` or `um`, still on the wall clock.
        ("1 oct 2014 at 9am", TypedEndpoint(year: 2014, month: 10, day: 1, time: SpanTime(hour: 9, minute: 0))),
        ("1 oct 2014 at 9:15am", TypedEndpoint(year: 2014, month: 10, day: 1, time: SpanTime(hour: 9, minute: 15))),
        ("1 oct 2014, 10:00 am", TypedEndpoint(year: 2014, month: 10, day: 1, time: SpanTime(hour: 10, minute: 0))),
        ("1. oktober 2014 um 14:00", TypedEndpoint(year: 2014, month: 10, day: 1, time: SpanTime(hour: 14, minute: 0))),
        ("tomorrow at 9:15am", TypedEndpoint(year: 2026, month: 10, day: 12, time: SpanTime(hour: 9, minute: 15))),
        ("24 october at 23:59", TypedEndpoint(year: nil, month: 10, day: 24, time: SpanTime(hour: 23, minute: 59))),
        ("29 feb at 9am", TypedEndpoint(year: nil, month: 2, day: 29, time: SpanTime(hour: 9, minute: 0))),
        // `noon` is the grammar's too.
        ("1 oct 2014 at noon", TypedEndpoint(year: 2014, month: 10, day: 1, time: SpanTime(hour: 12, minute: 0))),
        ("2014-10-01 at noon", TypedEndpoint(year: 2014, month: 10, day: 1, time: SpanTime(hour: 12, minute: 0))),
        // A leading weekday is read past, in English or German.
        ("wednesday, 1 october 2014", TypedEndpoint(year: 2014, month: 10, day: 1)),
        ("sat 24 oct", TypedEndpoint(year: nil, month: 10, day: 24)),
        ("samstag, 24.10.2026", TypedEndpoint(year: 2026, month: 10, day: 24)),
        ("sat 2026-10-24", TypedEndpoint(year: 2026, month: 10, day: 24)),
    ]
    for (text, expected) in table {
        #expect(parser.endpoint(text) == expected, "\(text)")
    }
}

@Test func payloadsAreCaseAndCompositionInsensitive() {
    #expect(block("1 OCTOBER 2014 TO 30 SEPTEMBER 2016") == twoYears)
    // A decomposed ä (as some keyboards and pastes produce) still reads as März.
    #expect(span("3 Ma\u{0308}rz 2026 to 3 März 2026")?.dayCount == 1)
    #expect(block("  1 october 2014    to   30 september 2016  ") == twoYears)
}

@Test func theDetectorFallbackReadsOnlyPhrasesWithNoDateInThem() {
    // A time after `at` is the grammar's own.
    #expect(block("24 october at 23:59 to 26 october 14:46") == overnight)
    // A relative phrase follows the system clock (the detector takes no
    // reference date), so only its shape is pinned.
    let friday = SpanCalculator.result(payload: "next friday")
    #expect(friday?.query.mode == .days)
    #expect((1...14).contains(friday?.dayCount ?? 0))
}

@Test func unparseablePayloadsAreRefused() {
    for payload in [
        "",
        "   ",
        "excl",
        "hello",
        // Three endpoints, by words, by lines and mixed.
        "1 oct 2014 to 2 oct 2014 to 3 oct 2014",
        "1 oct 2014\n2 oct 2014\n3 oct 2014",
        "1 oct 2014 to 2 oct 2014 - 3 oct 2014",
        // Two-digit years are never guessed, even by the detector.
        "1 oct 14",
        "1/10/14",
        "01.10.14",
        "14-10-01",
        "1/10/14 to 30/9/16",
        "1 oct 14 to 30 sep 16",
        // No such day, no such time, trailing words.
        "31 feb 2026",
        "29 feb 2026 to 1 mar 2026",
        "1 oct 2014 25:00",
        "1 oct 2014 13pm",
        "now 9:00",
        "1 oct 2014 sometime",
        // Two-digit years before words, and short numbers after a date.
        "14-10-01 9am",
        "14/10/01 9am",
        "1/10/14 9am",
        "1.10.14 9am",
        "1/10/14 at 9",
        "1st oct 14",
        // Seconds, a 24-hour hour with am/pm, a time that moves the day.
        "1 oct 2014 23:59:30",
        "1 oct 2014 13:00 pm",
        "1 oct 2014 midnight",
        // A zone after a time (the detector would convert it), and a short
        // number beside a typed day (a two-digit year).
        "24 oct 2026 at 9am pst",
        "24 oct 2026 at 9am utc",
        "sat 24 oct 14",
        // A zone read by the detector would move the time off the wall clock.
        "1 oct 2014 at noon pst",
        "tomorrow noon pst",
        "next friday at noon utc",
        "next friday 9.30am pst",
        "24 oct at noon pst to 26 oct at noon",
        "next friday 0:30 pm",
        // A weekday never lets an impossible day roll over.
        "sat 30 feb to 1 mar 2028",
        "sat 31 feb",
        "mon 31 jun",
        // A typed date the grammar does not read never goes to the detector,
        // which would decide its year and roll impossible days over.
        "october the 1st, 2014",
        "the 24th of oct",
        "1 oct 2014 morning",
        "9:00 to 17:30",
        "may",
        // Digits are ASCII only, and only ASCII words reach the detector.
        "1 oct \u{FF12}\u{FF10}\u{FF11}\u{FF14}",
        "1 oct \u{FF12}\u{FF10}\u{FF11}\u{FF14} to 30 sep 2016",
        "friday \u{FF13}:\u{FF10}\u{FF10}",
        "\u{FF4F}\u{FF43}\u{FF54}\u{FF4F}\u{FF42}\u{FF45}\u{FF52} 5",
        // A time in words other than `noon` is never invented or dropped.
        "friday morning",
        "friday at twelve pm",
        "friday at twelve",
        "tonight",
        "friday lunch to friday 15:00",
        "next friday midday",
        "friday lunchtime",
        // Beside a typed clock, only date words: a second time is refused.
        "friday noon 3pm",
        "friday at noon 3pm",
        "noon friday 0:00",
        "friday morning 9pm",
        "friday afternoon 3am",
        "friday night 1am",
        // Before the Gregorian switch Foundation counts Julian days.
        "4 oct 1582 to 15 oct 1582",
        "0001-01-01",
    ] {
        #expect(span(payload) == nil, "\(payload)")
    }
}

// MARK: Rules (spec section 6)

@Test func numbersFollowTheThreeSignificantFigureRule() {
    #expect(SpanCalculator.significant(2.0014) == "2.00")
    #expect(SpanCalculator.significant(24.016) == "24.0")
    #expect(SpanCalculator.significant(104.43) == "104")
    #expect(SpanCalculator.significant(1_908.57) == "1,909")
    #expect(SpanCalculator.significant(9.996) == "10.0", "rounding up recounts the decimals")
    #expect(SpanCalculator.significant(99.96) == "100")
    #expect(SpanCalculator.significant(348.5) == "349", "half away from zero")
    #expect(SpanCalculator.grouped(1_234_567) == "1,234,567")
    #expect(SpanCalculator.grouped(999) == "999")
}

@Test func hoursAndMinutesSwitchToSuffixesOnTheRoundedValue() {
    #expect(SpanCalculator.clockValue(240, unit: "hour").line == "= 240 hours")
    #expect(SpanCalculator.clockValue(1, unit: "hour").line == "= 1 hour")
    #expect(SpanCalculator.clockValue(38.783, unit: "hour").line == "= 38.8 hours")
    #expect(SpanCalculator.clockValue(9_999, unit: "hour").line == "= 9,999 hours")
    #expect(SpanCalculator.clockValue(9_999.6, unit: "hour").line == "≈ 10.0k hours", "the rounded value decides")
    #expect(SpanCalculator.clockValue(17_544, unit: "hour").line == "≈ 17.5k hours")
    #expect(SpanCalculator.clockValue(320_640, unit: "hour").line == "≈ 321k hours")
    #expect(SpanCalculator.clockValue(999_600, unit: "hour").line == "≈ 1.00M hours")
    #expect(SpanCalculator.clockValue(1_660_000, unit: "minute").line == "≈ 1.66M minutes")
    #expect(SpanCalculator.clockValue(2_327, unit: "minute").line == "= 2,327 minutes")
}

// MARK: Payload extraction

@Test func theCommandTextKeepsItsLineBreaks() {
    #expect(SpanCalculator.payload(fromCommandText: "/span 1 october 2014\n30 september 2016") == "1 october 2014\n30 september 2016")
    #expect(SpanCalculator.payload(fromCommandText: "/span\n24 october 23:59\n\n26 october 14:46 /offline") == "24 october 23:59\n26 october 14:46")
    #expect(SpanCalculator.payload(fromCommandText: "1 oct 2014 to 30 sep 2016 /span") == "1 oct 2014 to 30 sep 2016")
    // The module keeps the given payload when the raw text is not its source.
    #expect(SpanCalculator.payload(rawText: "/span a\nb", payloadText: "a b") == "a\nb")
    #expect(SpanCalculator.payload(rawText: "/span", payloadText: "1 oct 2014") == "1 oct 2014")
}
