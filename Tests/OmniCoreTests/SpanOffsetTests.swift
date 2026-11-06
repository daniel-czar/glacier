import Foundation
import Testing
@testable import OmniCore

private let offsetUTC = TimeZone(secondsFromGMT: 0)!
private let offsetNow = SpanCalculator.calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 12))!

private func offset(_ text: String, timeZone: TimeZone = offsetUTC) -> SpanResult? {
    SpanCalculator.result(payload: text, now: offsetNow, timeZone: timeZone)
}

@Test func reportedSpanOffsetReturnsADateRatherThanAnInclusiveDuration() throws {
    let result = try #require(offset("5 months after 19 october 2026"))
    #expect(result.query.start == SpanEndpoint(year: 2026, month: 10, day: 19))
    #expect(result.query.end == SpanEndpoint(year: 2027, month: 3, day: 19))
    #expect(result.query.mode == .offset(amount: 5, unit: .month, direction: .after))
    #expect(result.block == "Result: 19 Mar 2027\n5 months after 19 Oct 2026")
    #expect(result.headline == "19 Mar 2027 · 5 months after 19 Oct 2026")
    #expect(result.dayCount == nil)
    #expect(result.minuteCount == nil)
}

@Test func calendarOffsetsReuseEndpointFormatsAndKeepBeforeDirection() {
    let cases = [
        ("5 months before 19 october 2026", "Result: 19 May 2026\n5 months before 19 Oct 2026"),
        ("5 MONTHS AFTER 2026-10-19", "Result: 19 Mar 2027\n5 months after 19 Oct 2026"),
        ("  5  months   after  19. Oktober 2026  ", "Result: 19 Mar 2027\n5 months after 19 Oct 2026"),
        ("5 months after\n19 oct 2026", "Result: 19 Mar 2027\n5 months after 19 Oct 2026"),
        ("5 months after october 19, 2026", "Result: 19 Mar 2027\n5 months after 19 Oct 2026"),
        ("5 months after 19 oct", "Result: 19 Mar 2027\n5 months after 19 Oct 2026"),
        ("1 week after 31 dec 2026", "Result: 7 Jan 2027\n1 week after 31 Dec 2026"),
        ("2 weeks before 10 jan 2027", "Result: 27 Dec 2026\n2 weeks before 10 Jan 2027"),
        ("1 day before 1 mar 2024", "Result: 29 Feb 2024\n1 day before 1 Mar 2024"),
        ("0 months after 19 oct 2026", "Result: 19 Oct 2026\n0 months after 19 Oct 2026"),
    ]
    for (text, expected) in cases { #expect(offset(text)?.block == expected, "\(text)") }
}

@Test func monthAndYearOffsetsUseCalendarClampingFromTheOriginalAnchor() {
    let cases = [
        ("1 month after 31 jan 2026", "28 Feb 2026"),
        ("2 months after 31 jan 2026", "31 Mar 2026"),
        ("1 month before 31 mar 2026", "28 Feb 2026"),
        ("1 month after 31 jan 2024", "29 Feb 2024"),
        ("1 year after 29 feb 2024", "28 Feb 2025"),
        ("4 years after 29 feb 2024", "29 Feb 2028"),
        ("1 year before 29 feb 2024", "28 Feb 2023"),
    ]
    for (text, expected) in cases { #expect(offset(text)?.query.end.echo == expected, "\(text)") }
}

@Test func timedOffsetsPreserveCivilTimeAndPromoteClockUnitsToMinutePrecision() {
    let cases = [
        ("5 months after 19 oct 2026 15:30", "19 Mar 2027 15:30"),
        ("2 hours after 28 mar 2026 23:30", "29 Mar 2026 01:30"),
        ("1 day after 29 mar 2026 01:30", "30 Mar 2026 01:30"),
        ("90 minutes before 19 oct 2026 00:30", "18 Oct 2026 23:00"),
        ("13 hours after 19 oct 2026", "19 Oct 2026 13:00"),
        ("1 minute before 19 oct 2026", "18 Oct 2026 23:59"),
        ("0 hours before 19 oct 2026", "19 Oct 2026 00:00"),
    ]
    for (text, expected) in cases {
        #expect(offset(text)?.query.end.echo == expected, "\(text)")
        #expect(offset(text, timeZone: TimeZone(identifier: "Europe/London")!)?.query.end.echo == expected, "\(text)")
    }
}

@Test func keywordOffsetAnchorsUseTheInjectedLocalCivilClock() {
    #expect(offset("5 months after today")?.query.end.echo == "11 Mar 2027")
    #expect(offset("1 day before tomorrow")?.query.end.echo == "11 Oct 2026")
    #expect(offset("2 hours after now")?.query.end.echo == "11 Oct 2026 14:00")
    #expect(offset("2 hours after now", timeZone: TimeZone(identifier: "America/New_York")!)?.query.end.echo == "11 Oct 2026 10:00")
}

@Test func offsetsRejectMalformedAmbiguousAndOutOfDomainInputsWithoutOverflow() {
    for text in [
        "5 months after", "five months after today", "-5 months after today", "+5 months after today",
        "1.5 months after today", "５ months after today", "5 business days after today",
        "5 months and 1 day after today", "5 months after 19 oct 2026 to 20 oct 2026",
        "5 months after 31 feb 2026", "1 month after 29 feb 2026", "1 month after 1 oct 26",
        "1 month after 1 oct 2026 incl", "1 month after 1 oct 2026 excl",
        "1 day before 1 jan 1583", "1 minute after 31 dec 9999 23:59",
        "10000 years before 1 jan 9999", "10000 years after 1 jan 1583",
        "9223372036854775807 minutes after today", "9223372036854775808 days before today",
        "999999999999999999999999999999 months after today", "1 hour after 19 oct 2026 12:00 pst",
    ] {
        #expect(offset(text) == nil, "\(text)")
    }
}
