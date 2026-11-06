import Foundation

public enum RegexExampleKind: String, Sendable, Equatable {
    case shouldMatch
    case shouldNotMatch
}

public struct RegexExampleVerdict: Sendable, Equatable {
    public let text: String
    public let shouldMatch: Bool
    /// Nil means the engine could not supply a verdict (compile failure or
    /// evaluation deadline). It is not counted as a disagreement.
    public let doesMatch: Bool?
    public let agreed: Bool?
    public let kind: RegexExampleKind
    public let verdict: String

    public init(text: String, shouldMatch: Bool, doesMatch: Bool?) {
        self.text = text
        self.shouldMatch = shouldMatch
        self.doesMatch = doesMatch
        self.agreed = doesMatch.map { $0 == shouldMatch }
        self.kind = shouldMatch ? .shouldMatch : .shouldNotMatch
        switch (shouldMatch, doesMatch) {
        case (true, true): verdict = "✓ should match · does"
        case (true, false): verdict = "✗ should match · doesn't"
        case (false, true): verdict = "✗ should not · matches"
        case (false, false): verdict = "– should not · doesn't"
        case (_, nil): verdict = shouldMatch ? "? should match · unchecked" : "? should not · unchecked"
        }
    }
}

public struct RegexExampleEvaluation: Sendable, Equatable {
    public let examples: [RegexExampleVerdict]
    public let compileError: String?
    public let timedOut: Bool
    public var disagreementCount: Int { examples.filter { $0.agreed == false }.count }

    public init(examples: [RegexExampleVerdict], compileError: String?, timedOut: Bool) {
        self.examples = examples
        self.compileError = compileError
        self.timedOut = timedOut
    }
}

/// The exact model contract. Validation happens before this value is created;
/// compilation is intentionally separate so an invalid pattern still appears
/// with the engine's error and the model's examples.
public struct RegexGeneratedPattern: Sendable, Equatable {
    public let pattern: String
    public let flavor: String
    public let name: String
    public let shouldMatch: [String]
    public let shouldNotMatch: [String]
    public let note: String?

    public init(pattern: String, flavor: String = "icu", name: String, shouldMatch: [String], shouldNotMatch: [String], note: String? = nil) {
        self.pattern = pattern
        self.flavor = flavor
        self.name = name
        self.shouldMatch = shouldMatch
        self.shouldNotMatch = shouldNotMatch
        self.note = note
    }

    public var sheetEntry: RegexSheetEntry { RegexSheetEntry(name: name, pattern: pattern, note: note ?? "") }

    /// Evaluate each entire example with ICU. No model-produced verdict is
    /// accepted. Progress callbacks provide a bound for pathological patterns.
    public func evaluateExamples(deadlineSeconds: TimeInterval = 0.25) -> RegexExampleEvaluation {
        let all = shouldMatch.map { ($0, true) } + shouldNotMatch.map { ($0, false) }
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(pattern: pattern)
        } catch {
            return RegexExampleEvaluation(
                examples: all.map { RegexExampleVerdict(text: $0.0, shouldMatch: $0.1, doesMatch: nil) },
                compileError: error.localizedDescription,
                timedOut: false
            )
        }
        var timedOut = false
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.001, deadlineSeconds)
        let examples = all.map { text, expectation in
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            var matched = false
            var expired = false
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                timedOut = true
                return RegexExampleVerdict(text: text, shouldMatch: expectation, doesMatch: nil)
            }
            expression.enumerateMatches(in: text, options: [.reportProgress], range: range) { result, flags, stop in
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    expired = true
                    stop.pointee = true
                    return
                }
                if result != nil {
                    matched = true
                    stop.pointee = true
                }
                if flags.contains(.internalError) {
                    expired = true
                    stop.pointee = true
                }
            }
            timedOut = timedOut || expired
            return RegexExampleVerdict(text: text, shouldMatch: expectation, doesMatch: expired ? nil : matched)
        }
        return RegexExampleEvaluation(examples: examples, compileError: nil, timedOut: timedOut)
    }
}
