import Foundation

// `/span` (C82, spec 98b6b449394ee04e): date/time ranges and calendar offsets,
// computed on this Mac with no model and rendered as one copyable block.
//
// - Two plain dates are a calendar *period*: both days count unless the
//   payload ends in `excl` (S1).
// - One endpoint alone runs until today (a plain date: whole days) or until
//   now (a date with a time: minutes) (S3).
// - A time on either endpoint makes the span *elapsed*: the exact wall-clock
//   difference at minute precision.
//
// Arithmetic runs on the civil components as typed, in a Gregorian calendar
// pinned to UTC, so daylight-saving changes never move the answer.

/// An hour and minute on the wall clock (24-hour).
public struct SpanTime: Sendable, Equatable {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }
}

/// Calendar units for an integer offset. Months and years use Foundation's
/// calendar clamping, not a fixed number of elapsed days.
public enum SpanOffsetUnit: String, Sendable, Equatable, CaseIterable {
    case year, month, week, day, hour, minute

    var component: Calendar.Component {
        switch self {
        case .year: .year
        case .month: .month
        case .week: .weekOfYear
        case .day: .day
        case .hour: .hour
        case .minute: .minute
        }
    }

    var carriesTime: Bool { self == .hour || self == .minute }

    /// More than the entire supported date domain, but small enough to keep
    /// untrusted integer input away from Foundation's overflow boundaries.
    var maximumMagnitude: Int {
        switch self {
        case .year: 10_000
        case .month: 120_000
        case .week: 530_000
        case .day: 3_700_000
        case .hour: 90_000_000
        case .minute: 5_400_000_000
        }
    }
}

public enum SpanOffsetDirection: String, Sendable, Equatable {
    case after, before
}

/// One resolved endpoint: civil date components, an optional time, and the
/// word it echoes as when it was inferred rather than typed (S3).
public struct SpanEndpoint: Sendable, Equatable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let time: SpanTime?
    /// `today` or `now` for the inferred endpoint of a one-endpoint query.
    public let inferredWord: String?

    public init(year: Int, month: Int, day: Int, time: SpanTime? = nil, inferredWord: String? = nil) {
        self.year = year
        self.month = month
        self.day = day
        self.time = time
        self.inferredWord = inferredWord
    }

    /// `D Mon YYYY`, plus ` HH:MM` when the endpoint carries a time.
    public var echo: String {
        if let inferredWord { return inferredWord }
        let date = "\(day) \(SpanCalculator.echoMonths[month - 1]) \(year)"
        guard let time else { return date }
        return date + " " + String(format: "%02d:%02d", time.hour, time.minute)
    }

    var instant: Date? {
        SpanCalculator.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: time?.hour ?? 0, minute: time?.minute ?? 0))
    }
}

/// A parsed `/span` payload. Range endpoints are chronological; an offset
/// keeps its anchor in `start` and its answer in `end`, including `before`.
public struct SpanQuery: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        /// Two plain dates (S1): both days count when `inclusive`.
        case period(inclusive: Bool)
        /// One plain date against today (S3): whole days, last day not added.
        case days
        /// A time on either endpoint, typed or `now`: exact minutes.
        case elapsed
        /// One calendar offset, whose answer is a date rather than a duration.
        case offset(amount: Int, unit: SpanOffsetUnit, direction: SpanOffsetDirection)
    }

    public let start: SpanEndpoint
    public let end: SpanEndpoint
    public let mode: Mode

    public init(start: SpanEndpoint, end: SpanEndpoint, mode: Mode) {
        self.start = start
        self.end = end
        self.mode = mode
    }

    /// Nil when the payload is empty, has more than two endpoints, or an
    /// endpoint does not parse. `now` and its time zone (whose civil clock
    /// gives `today`, `now` and the current year) are injected for tests.
    public init?(payload: String, now: Date = Date(), timeZone: TimeZone = .current) {
        guard let query = SpanParser(now: now, timeZone: timeZone).query(payload) else { return nil }
        self = query
    }
}

/// The computed span: the block a second Enter copies and the footer headline.
public struct SpanResult: Sendable, Equatable {
    public let query: SpanQuery
    /// Calendar breakdown, e.g. `1 year, 11 months, 29 days`.
    public let breakdown: String
    /// Whole days in a period or day span; nil for elapsed spans and offsets.
    public let dayCount: Int?
    /// Exact minutes in an elapsed span; nil for periods, day spans and offsets.
    public let minuteCount: Int?
    /// The whole block: the `Total period:` line, then one line per unit.
    public let block: String
    /// The footer route line while typing (section 3 of the spec).
    public let headline: String

    public init?(_ query: SpanQuery) {
        let calendar = SpanCalculator.calendar
        guard let start = query.start.instant, let endInstant = query.end.instant else { return nil }
        if case .offset(let amount, let unit, let direction) = query.mode {
            guard (0...unit.maximumMagnitude).contains(amount) else { return nil }
            self.query = query
            breakdown = SpanCalculator.counted(String(amount), unit.rawValue)
            dayCount = nil
            minuteCount = nil
            let operation = "\(breakdown) \(direction.rawValue) \(query.start.echo)"
            block = "Result: \(query.end.echo)\n\(operation)"
            headline = "\(query.end.echo) · \(operation)"
            return
        }
        let end: Date
        if case .period(inclusive: true) = query.mode {
            guard let next = calendar.date(byAdding: .day, value: 1, to: endInstant) else { return nil }
            end = next
        } else {
            end = endInstant
        }
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start, to: end)
        let elapsed = query.mode == .elapsed
        let units: [(Int?, String, String)] = [
            (parts.year, "year", "year"),
            (parts.month, "month", "month"),
            (parts.day, "day", "day"),
            (elapsed ? parts.hour : nil, "hour", "h"),
            (elapsed ? parts.minute : nil, "minute", "min"),
        ]
        func describe(abbreviated: Bool) -> String {
            let words = units.compactMap { item -> String? in
                let (value, unit, short) = item
                guard let value, value != 0 else { return nil }
                if abbreviated, unit == "hour" || unit == "minute" { return "\(value) \(short)" }
                return SpanCalculator.counted(String(value), unit)
            }
            return words.isEmpty ? (elapsed ? "0 minutes" : "0 days") : words.joined(separator: ", ")
        }

        let days: Double
        var lines: [String] = []
        let third: String
        if elapsed {
            let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
            dayCount = nil
            minuteCount = minutes
            days = Double(minutes) / 1440
            let hours = Double(minutes) / 60
            lines = SpanCalculator.derivedLines(days: days, exactDays: nil, hours: hours, minutes: minutes)
            third = hours >= 1 ? SpanCalculator.clockValue(hours, unit: "hour").text : SpanCalculator.clockValue(Double(minutes), unit: "minute").text
        } else {
            guard let count = calendar.dateComponents([.day], from: start, to: end).day else { return nil }
            dayCount = count
            minuteCount = nil
            days = Double(count)
            lines = SpanCalculator.derivedLines(days: days, exactDays: count, hours: days * 24, minutes: nil)
            third = SpanCalculator.counted(SpanCalculator.grouped(count), "day")
        }
        let tail: String = switch query.mode {
        case .period(inclusive: true): ", both days counted"
        case .period(inclusive: false): ", last day not counted"
        case .days, .elapsed, .offset: ""
        }
        let range = "\(query.start.echo) – \(query.end.echo)"
        self.query = query
        breakdown = describe(abbreviated: false)
        block = (["Total period: \(breakdown) (\(range)\(tail))"] + lines).joined(separator: "\n")
        headline = "\(range) · \(describe(abbreviated: true)) · \(third)"
    }
}

public enum SpanCalculator {
    /// The refusal for an empty or unparseable payload (spec section 3).
    public static let hint = "Two dates or times, one date for time since, or an offset, e.g. 5 months after 19 oct 2026"

    /// The `/span` payload of a whole command text with its line breaks kept.
    /// `SlashTokenSyntax.payloadText` joins every atom with one space, which
    /// would erase the newline between two endpoints typed on separate lines;
    /// this applies the same atom rule line by line and drops empty lines.
    public static func payload(fromCommandText text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { SlashTokenSyntax.payloadText(from: String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The payload a module should parse: the line-preserving form of the
    /// raw text when it carries exactly the input's payload atoms, otherwise
    /// the payload as given (inputs built without the raw command text).
    public static func payload(rawText: String, payloadText: String) -> String {
        let lined = payload(fromCommandText: rawText)
        return lined.replacingOccurrences(of: "\n", with: " ") == payloadText ? lined : payloadText
    }

    /// Parse and compute in one step; nil when the payload does not parse.
    public static func result(payload: String, now: Date = Date(), timeZone: TimeZone = .current) -> SpanResult? {
        SpanQuery(payload: payload, now: now, timeZone: timeZone).flatMap(SpanResult.init)
    }

    // MARK: Formatting

    static let echoMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// One line per derived unit, in order, each only when at least 1.
    static func derivedLines(days: Double, exactDays: Int?, hours: Double, minutes: Int?) -> [String] {
        var lines: [String] = []
        for (value, unit) in [(days / 365.25, "year"), (days / 30.4375, "month"), (days / 7, "week")] where value >= 1 {
            lines.append("= " + counted(significant(value), unit))
        }
        if days >= 1 {
            // A period's day count is exact and never abbreviated.
            lines.append("= " + counted(exactDays.map(grouped) ?? significant(days), "day"))
        }
        if hours >= 1 {
            lines.append(clockValue(hours, unit: "hour").line)
        }
        if let minutes, minutes >= 1 {
            lines.append(clockValue(Double(minutes), unit: "minute").line)
        }
        return lines
    }

    /// Hours and minutes: whole values below 10,000 exactly, others to three
    /// significant figures, and from 10,000 (decided on the rounded value)
    /// with a `k` or `M` suffix behind `≈`.
    static func clockValue(_ value: Double, unit: String) -> (text: String, line: String) {
        let whole = value == value.rounded()
        let plain = whole ? grouped(Int(value)) : significant(value)
        if (Double(plain.replacingOccurrences(of: ",", with: "")) ?? value) < 10_000 {
            let text = counted(plain, unit)
            return (text, "= " + text)
        }
        var scaled = significant(value / 1_000)
        var suffix = "k"
        if (Double(scaled.replacingOccurrences(of: ",", with: "")) ?? 0) >= 1_000 {
            scaled = significant(value / 1_000_000)
            suffix = "M"
        }
        let text = counted(scaled + suffix, unit)
        return (text, "≈ " + text)
    }

    /// Three significant figures: `max(0, 3 − integer digits)` decimals,
    /// thousands separators, decimals recounted when rounding adds a digit.
    static func significant(_ value: Double) -> String {
        func decimals(_ value: Double) -> Int { max(0, 3 - String(Int(value.magnitude)).count) }
        // Half away from zero (348.5 → 349), not printf's half-to-even.
        func render(_ value: Double, _ places: Int) -> String {
            let factor = pow(10, Double(places))
            return String(format: "%.*f", places, (value * factor).rounded(.toNearestOrAwayFromZero) / factor)
        }
        var places = decimals(value)
        var text = render(value, places)
        if let rounded = Double(text), decimals(rounded) < places {
            places = decimals(rounded)
            text = render(rounded, places)
        }
        let pieces = text.split(separator: ".", maxSplits: 1).map(String.init)
        let integer = Int(pieces[0]).map(grouped) ?? pieces[0]
        return pieces.count == 2 ? integer + "." + pieces[1] : integer
    }

    /// An integer with comma thousands separators, independent of locale.
    static func grouped(_ value: Int) -> String {
        let digits = String(value.magnitude)
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return value < 0 ? "-" + out : out
    }

    /// `1 day` for the exact integer 1, plural for everything else.
    static func counted(_ number: String, _ unit: String) -> String {
        "\(number) \(unit)\(number == "1" ? "" : "s")"
    }
}

// MARK: - Parser

/// An endpoint as typed: the year may be missing until inference.
struct TypedEndpoint: Equatable {
    var year: Int?
    var month: Int
    var day: Int
    var time: SpanTime?
}

private enum EndpointParse {
    case typed(TypedEndpoint)
    /// The grammar recognised a date but not all of the text: refused.
    case refused
    /// No grammar form starts the text: the detector may try it, if eligible.
    case unrecognised
}

struct SpanParser {
    let today: (year: Int, month: Int, day: Int)
    let now: TypedEndpoint

    init(now: Date, timeZone: TimeZone) {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let parts = local.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        today = (parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
        self.now = TypedEndpoint(year: today.year, month: today.month, day: today.day, time: SpanTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0))
    }

    static let separators = [" to ", " until ", " till ", " bis ", " -> ", " → ", " – ", " — ", " - ", " / "]

    func query(_ payload: String) -> SpanQuery? {
        let normalised = payload.precomposedStringWithCanonicalMapping.lowercased()
        // Digits are ASCII only: `２０１４` would match a pattern but not parse.
        guard !normalised.contains(where: { $0.isNumber && !$0.isASCII }) else { return nil }
        var lines = normalised.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        // Offset recognition precedes range flags and splitting. It therefore
        // never applies inclusive-day counting or silently consumes `excl`.
        if let shifted = offset(lines.joined(separator: " ")) { return shifted }

        // A final `excl`/`incl` token is a flag, not part of an endpoint.
        var inclusive = true
        var lastWords = lines[lines.count - 1].split(separator: " ").map(String.init)
        if let flag = lastWords.last, ["excl", "exclusive", "incl", "inclusive"].contains(flag) {
            inclusive = flag.hasPrefix("incl")
            lastWords.removeLast()
            lines[lines.count - 1] = lastWords.joined(separator: " ")
            lines = lines.filter { !$0.isEmpty }
        }
        guard !lines.isEmpty else { return nil }

        let endpoints: [String]
        if lines.count > 1 {
            endpoints = lines
        } else if let separator = Self.separators.first(where: { lines[0].contains($0) }),
                  let range = lines[0].range(of: separator) {
            endpoints = [String(lines[0][..<range.lowerBound]), String(lines[0][range.upperBound...])]
        } else {
            endpoints = lines
        }
        // Three endpoints, or a separator left inside one, are refused.
        guard endpoints.count <= 2,
              endpoints.allSatisfy({ endpoint in !endpoint.isEmpty && !Self.separators.contains { endpoint.contains($0) } })
        else { return nil }

        let typed = endpoints.compactMap(endpoint)
        guard typed.count == endpoints.count else { return nil }
        return typed.count == 2 ? range(typed[0], typed[1], inclusive: inclusive) : single(typed[0])
    }

    private func offset(_ text: String) -> SpanQuery? {
        guard let regex = try? NSRegularExpression(pattern: #"^([0-9]+) (years?|months?|weeks?|days?|hours?|minutes?) (after|before) (.+)$"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        let ns = text as NSString
        let unitText = ns.substring(with: match.range(at: 2))
        let singular = unitText.hasSuffix("s") ? String(unitText.dropLast()) : unitText
        guard let amount = Int(ns.substring(with: match.range(at: 1))),
              let unit = SpanOffsetUnit(rawValue: singular),
              amount <= unit.maximumMagnitude,
              let direction = SpanOffsetDirection(rawValue: ns.substring(with: match.range(at: 3))),
              var anchor = endpoint(ns.substring(with: match.range(at: 4)))
        else { return nil }
        if anchor.year == nil { anchor.year = today.year }
        guard let base = resolved(anchor), let instant = base.instant,
              let shifted = SpanCalculator.calendar.date(
                byAdding: unit.component,
                value: direction == .before ? -amount : amount,
                to: instant
              )
        else { return nil }
        let parts = SpanCalculator.calendar.dateComponents([.era, .year, .month, .day, .hour, .minute], from: shifted)
        guard parts.era == 1, let year = parts.year, (1583...9999).contains(year),
              let month = parts.month, let day = parts.day
        else { return nil }
        let time: SpanTime?
        if base.time != nil || unit.carriesTime {
            guard let hour = parts.hour, let minute = parts.minute else { return nil }
            time = SpanTime(hour: hour, minute: minute)
        } else {
            time = nil
        }
        let answer = SpanEndpoint(year: year, month: month, day: day, time: time)
        return SpanQuery(start: base, end: answer, mode: .offset(amount: amount, unit: unit, direction: direction))
    }

    /// Two endpoints: infer missing years, then count (S1).
    private func range(_ first: TypedEndpoint, _ second: TypedEndpoint, inclusive: Bool) -> SpanQuery? {
        var start = first
        var end = second
        switch (start.year, end.year) {
        case (nil, nil):
            start.year = today.year
            end.year = today.year
            // `24 dec to 2 jan` runs into the next year. Dates, not instants,
            // decide, so two times on one day swap instead of jumping a year.
            if (end.month, end.day) < (start.month, start.day) { end.year = today.year + 1 }
        case (nil, let year?): start.year = year
        case (let year?, nil): end.year = year
        default: break
        }
        guard var a = resolved(start), var b = resolved(end) else { return nil }
        if Self.precedes(b, a) { swap(&a, &b) }
        let mode: SpanQuery.Mode = a.time != nil || b.time != nil ? .elapsed : .period(inclusive: inclusive)
        return SpanQuery(start: a, end: b, mode: mode)
    }

    /// One endpoint (S3): until now when it carries a time, else until today.
    private func single(_ typed: TypedEndpoint) -> SpanQuery? {
        var typed = typed
        if typed.year == nil { typed.year = today.year }
        guard let endpoint = resolved(typed) else { return nil }
        let other: SpanEndpoint
        let mode: SpanQuery.Mode
        if endpoint.time != nil {
            other = SpanEndpoint(year: now.year ?? today.year, month: now.month, day: now.day, time: now.time, inferredWord: "now")
            mode = .elapsed
        } else {
            other = SpanEndpoint(year: today.year, month: today.month, day: today.day, inferredWord: "today")
            mode = .days
        }
        let ordered = Self.precedes(other, endpoint) ? (other, endpoint) : (endpoint, other)
        return SpanQuery(start: ordered.0, end: ordered.1, mode: mode)
    }

    /// Chronological order on the wall clock; an endpoint without a time is midnight.
    private static func precedes(_ a: SpanEndpoint, _ b: SpanEndpoint) -> Bool {
        func key(_ e: SpanEndpoint) -> [Int] { [e.year, e.month, e.day, e.time?.hour ?? 0, e.time?.minute ?? 0] }
        return key(a).lexicographicallyPrecedes(key(b))
    }

    /// Checks the date exists (no 31 Feb) once the year is known. Years
    /// start at 1583: before 15 Oct 1582 Foundation's Gregorian calendar
    /// counts Julian days, which would silently change the answer.
    private func resolved(_ typed: TypedEndpoint) -> SpanEndpoint? {
        guard let year = typed.year, (1583...9999).contains(year), (1...12).contains(typed.month), typed.day >= 1 else { return nil }
        let calendar = SpanCalculator.calendar
        guard let first = calendar.date(from: DateComponents(year: year, month: typed.month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: first),
              days.contains(typed.day)
        else { return nil }
        return SpanEndpoint(year: year, month: typed.month, day: typed.day, time: typed.time)
    }

    // MARK: Endpoint grammar

    func endpoint(_ text: String) -> TypedEndpoint? {
        switch grammar(text) {
        case .typed(let endpoint): endpoint
        case .refused: nil
        case .unrecognised: Self.detectorEligible(text) ? Self.detected(text) : nil
        }
    }

    private func grammar(_ text: String) -> EndpointParse {
        let ns = text as NSString
        // A leading weekday (`sat 24 oct`, `Samstag, 24.10.2026`) is read past
        // and not checked: the grammar reads the date after it, so the
        // detector never guesses its year or rolls an impossible day over.
        if let weekday = Self.first(Self.weekday, in: text) {
            let remainder = ns.substring(from: weekday.range.length)
            switch grammar(remainder) {
            case .typed(let date): return .typed(date)
            case .refused: return .refused
            case .unrecognised: break
            }
        }
        var date: TypedEndpoint?
        var consumed = 0

        if let match = Self.first(Self.keyword, in: text) {
            let word = ns.substring(with: match.range(at: 1))
            consumed = match.range.length
            if word == "now" {
                return consumed == ns.length ? .typed(now) : .refused
            }
            let offset = ["yesterday": -1, "today": 0, "tomorrow": 1][word] ?? 0
            guard let base = SpanCalculator.calendar.date(from: DateComponents(year: today.year, month: today.month, day: today.day)),
                  let shifted = SpanCalculator.calendar.date(byAdding: .day, value: offset, to: base)
            else { return .refused }
            let parts = SpanCalculator.calendar.dateComponents([.year, .month, .day], from: shifted)
            date = TypedEndpoint(year: parts.year, month: parts.month ?? 1, day: parts.day ?? 1)
        } else {
            for form in Self.numericForms {
                guard let match = Self.first(form.pattern, in: text) else { continue }
                let numbers = (1..<match.numberOfRanges).map { index -> Int? in
                    let range = match.range(at: index)
                    return range.location == NSNotFound ? nil : Int(ns.substring(with: range))
                }
                date = form.read(numbers)
                consumed = match.range.length
                break
            }
            if date == nil {
                for form in Self.wordForms {
                    guard let match = Self.first(form.pattern, in: text) else { continue }
                    let group = { (index: Int) -> String? in
                        let range = match.range(at: index)
                        return range.location == NSNotFound ? nil : ns.substring(with: range)
                    }
                    guard let month = group(form.month).flatMap({ Self.months[$0] }),
                          let day = group(form.day).flatMap({ Int($0) })
                    else { continue }
                    date = TypedEndpoint(year: group(form.year).flatMap { Int($0) }, month: month, day: day)
                    consumed = match.range.length
                    break
                }
            }
        }

        guard var date else { return .unrecognised }
        let rest = ns.substring(from: consumed)
        guard !rest.isEmpty else { return .typed(date) }
        guard let lead = rest.first, lead.isWhitespace || lead == "," else { return .refused }
        // The time part, optionally after `,`, `at` or `um`, is the grammar's
        // own, read on the wall clock as typed.
        var tail = rest.trimmingCharacters(in: .whitespaces)
        if tail.hasPrefix(",") { tail = String(tail.dropFirst()).trimmingCharacters(in: .whitespaces) }
        for word in ["at ", "um "] where tail.hasPrefix(word) {
            tail = String(tail.dropFirst(word.count)).trimmingCharacters(in: .whitespaces)
        }
        guard let time = Self.time(tail) else {
            // A two-digit year (`1 oct 14`), a bad time (`13pm`), a zone
            // (`9am pst`) or any other words: refused, never guessed.
            return .refused
        }
        date.time = time
        return .typed(date)
    }

    /// `HH:MM` (24-hour), or `H am`, `H:MM pm`, `Hpm`, or `noon`.
    private static func time(_ text: String) -> SpanTime? {
        if text == "noon" { return SpanTime(hour: 12, minute: 0) }
        let ns = text as NSString
        if let match = first(clock24, in: text), match.range.length == ns.length,
           let hour = Int(ns.substring(with: match.range(at: 1))), let minute = Int(ns.substring(with: match.range(at: 2))),
           (0...23).contains(hour), (0...59).contains(minute) {
            return SpanTime(hour: hour, minute: minute)
        }
        if let match = first(clock12, in: text), match.range.length == ns.length,
           let hour = Int(ns.substring(with: match.range(at: 1))), (1...12).contains(hour) {
            let minuteRange = match.range(at: 2)
            let minute = minuteRange.location == NSNotFound ? 0 : Int(ns.substring(with: minuteRange)) ?? -1
            guard (0...59).contains(minute) else { return nil }
            let pm = ns.substring(with: match.range(at: 3)) == "pm"
            return SpanTime(hour: hour % 12 + (pm ? 12 : 0), minute: minute)
        }
        return nil
    }

    /// Only phrases with no date in them reach the detector: ASCII words, no
    /// month name and no digit outside a valid clock time, and at least one
    /// word. A typed date is the grammar's alone, so its year follows the
    /// inference rule and a two-digit year or an impossible day is never
    /// guessed. What is left is relative (`next friday`, `friday 13:00`).
    private static func detectorEligible(_ text: String) -> Bool {
        let clockless = withoutClockTimes(text)
        let words = clockless.split(whereSeparator: { !$0.isLetter }).map(String.init)
        return !words.isEmpty && clockless.allSatisfy(\.isASCII) && !clockless.contains(where: \.isNumber) && !words.contains { months[$0] != nil }
    }

    /// The text with each clock time the grammar accepts blanked out.
    private static func withoutClockTimes(_ text: String) -> String {
        let ns = text as NSString
        var out = text
        for match in typedClock.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed()
        where time(ns.substring(with: match.range)) != nil {
            out = (out as NSString).replacingCharacters(in: match.range, with: " ")
        }
        return out
    }

    /// The fallback (spec section 4): one detector match over the whole
    /// endpoint, never a range, never a zone. Relative phrases follow the
    /// system clock.
    private static func detected(_ text: String) -> TypedEndpoint? {
        // Seconds are not accepted, and a 24-hour hour takes no am/pm; the
        // detector would drop the one and read the other.
        guard let detector, first(seconds, in: text) == nil, first(hour24Meridiem, in: text) == nil else { return nil }
        let length = (text as NSString).length
        let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: length))
        // A zone would convert the typed time away from the wall clock.
        guard matches.count == 1, let match = matches.first,
              match.range == NSRange(location: 0, length: length), match.duration == 0, match.timeZone == nil,
              let date = match.date
        else { return nil }
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let parts = local.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        let read = SpanTime(hour: parts.hour ?? -1, minute: parts.minute ?? -1)
        let noon = SpanTime(hour: 12, minute: 0)
        let words = Set(withoutClockTimes(text).split(whereSeparator: { !$0.isLetter }).map(String.init))
        // A time comes only from a typed clock or `noon`, read back unchanged
        // (a daylight-saving gap would move a clock), and every other word is
        // a date word: a time in other words (`morning`, `twelve pm`, `lunch`,
        // a second time beside a clock) cannot be checked and is refused.
        // With neither, the detector's noon is its "no time" marker.
        let clockWords = dateWords.union(["at", "um"])
        let time: SpanTime?
        if let typed = typedClockTime(in: text) {
            guard typed == read, words.isSubset(of: clockWords.union(typed == noon ? ["uhr", "noon"] : ["uhr"])) else { return nil }
            time = typed
        } else if words.contains("noon") {
            guard read == noon, words.isSubset(of: clockWords.union(["noon"])) else { return nil }
            time = noon
        } else {
            guard read == noon, words.isSubset(of: dateWords) else { return nil }
            time = nil
        }
        return TypedEndpoint(year: year, month: month, day: day, time: time)
    }

    /// The only words a detector phrase with no time may hold: relative
    /// days and weekdays, never a word the detector could read as a time.
    private static let dateWords: Set<String> = [
        "next", "this", "coming", "last", "on", "the", "day", "after", "before", "week",
        "today", "tomorrow", "yesterday",
        "monday", "mon", "tuesday", "tues", "tue", "wednesday", "wed", "thursday", "thurs", "thur", "thu",
        "friday", "fri", "saturday", "sat", "sunday", "sun",
        "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag", "sonntag",
        "mo", "di", "mi", "do", "fr", "sa", "so",
    ]


    /// The first clock time typed anywhere in the text, on a 24-hour clock.
    private static func typedClockTime(in text: String) -> SpanTime? {
        let ns = text as NSString
        return typedClock.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .lazy.compactMap { time(ns.substring(with: $0.range)) }.first
    }

    // MARK: Patterns

    private struct NumericForm {
        let pattern: NSRegularExpression
        let read: @Sendable ([Int?]) -> TypedEndpoint?
    }

    private struct WordForm {
        let pattern: NSRegularExpression
        let day: Int
        let month: Int
        let year: Int
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Literal patterns: a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern)
    }

    private static func first(_ pattern: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        pattern.firstMatch(in: text, options: [.anchored], range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func dmy(_ numbers: [Int?], day: Int, month: Int, year: Int?) -> TypedEndpoint? {
        guard let d = numbers[day], let m = numbers[month] else { return nil }
        return TypedEndpoint(year: year.flatMap { numbers[$0] }, month: m, day: d)
    }

    private static let keyword = regex(#"(today|now|tomorrow|yesterday)(?![\p{L}])"#)
    private static let clock24 = regex(#"([0-9]{1,2}):([0-9]{2})"#)
    private static let clock12 = regex(#"([0-9]{1,2})(?::([0-9]{2}))?\s*(am|pm)"#)
    private static let seconds = regex(#".*[0-9]:[0-9]{2}:[0-9]{2}"#)
    private static let hour24Meridiem = regex(#".*(?<![0-9:])(?:1[3-9]|2[0-9]|00?)(?::[0-9]{2})?\s*(?:am|pm)\b"#)
    private static let typedClock = regex(#"(?<![0-9:])[0-9]{1,2}(?::[0-9]{2})?\s*(?:am|pm)\b|(?<![0-9:])[0-9]{1,2}:[0-9]{2}(?![0-9:])"#)
    private static let weekday = regex(#"(?:monday|mon|tuesday|tues|tue|wednesday|wed|thursday|thurs|thur|thu|friday|fri|saturday|sat|sunday|sun|montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonntag|mo|di|mi|do|fr|sa|so)\.?,?\s+"#)
    /// Built once: the footer parses on every keystroke.
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// Numeric forms, longest first: ISO, German dotted, day-first slashed.
    private static let numericForms: [NumericForm] = [
        NumericForm(pattern: regex(#"([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})(?![0-9])"#)) { dmy($0, day: 2, month: 1, year: 0) },
        NumericForm(pattern: regex(#"([0-9]{1,2})\.([0-9]{1,2})\.([0-9]{4})(?![0-9])"#)) { dmy($0, day: 0, month: 1, year: 2) },
        NumericForm(pattern: regex(#"([0-9]{1,2})\.([0-9]{1,2})\.?(?![0-9.])"#)) { dmy($0, day: 0, month: 1, year: nil) },
        NumericForm(pattern: regex(#"([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})(?![0-9])"#)) { dmy($0, day: 0, month: 1, year: 2) },
        NumericForm(pattern: regex(#"([0-9]{1,2})/([0-9]{1,2})(?![0-9/])"#)) { dmy($0, day: 0, month: 1, year: nil) },
    ]

    /// `D Month [YYYY]` (German ordinal dot, English `1st` and `1st of`
    /// allowed), then `Month D[,] [YYYY]` (`march 3rd`). Ordinals stay in the
    /// grammar so a missing year follows the inference rule, not the
    /// detector's guess.
    private static let wordForms: [WordForm] = [
        WordForm(pattern: regex(#"([0-9]{1,2})(?:st|nd|rd|th)?(?:\.\s*|\s+)(?:of\s+)?(\p{L}+)\.?(?:,?\s+([0-9]{4})(?![0-9]))?"#), day: 1, month: 2, year: 3),
        WordForm(pattern: regex(#"(\p{L}+)\.?\s+([0-9]{1,2})(?:st|nd|rd|th)?(?![0-9\p{L}])(?:,?\s+([0-9]{4})(?![0-9]))?"#), day: 2, month: 1, year: 3),
    ]

    /// English full and three-letter names plus `sept`; German full and short.
    static let months: [String: Int] = {
        let names: [[String]] = [
            ["january", "jan", "januar"],
            ["february", "feb", "februar"],
            ["march", "mar", "märz", "maerz", "mär"],
            ["april", "apr"],
            ["may", "mai"],
            ["june", "jun", "juni"],
            ["july", "jul", "juli"],
            ["august", "aug"],
            ["september", "sep", "sept"],
            ["october", "oct", "oktober", "okt"],
            ["november", "nov"],
            ["december", "dec", "dezember", "dez"],
        ]
        var map: [String: Int] = [:]
        for (index, group) in names.enumerated() {
            for name in group { map[name] = index + 1 }
        }
        return map
    }()
}
