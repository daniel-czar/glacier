import Foundation
@testable import OmniCore
import Testing

@Test func calculatorEvaluatesPrecedenceParenthesesAndDecimalArithmetic() {
    let examples: [(String, String)] = [
        ("2 + 3 * 4", "14"),
        ("(2 + 3) * 4", "20"),
        ("12.5 * (8 + 2)", "125"),
        ("0.1 + 0.2", "0.3"),
        ("8 × 2", "16"),
        ("8 ÷ 2", "4"),
        ("8 / 2", "4"),
        ("100/2", "50"),
        ("2*-3", "-6"),
        ("−5 + 2", "-3"),
        ("-5 + 2", "-3"),
        ("2 - -3", "5"),
        ("2 + +3", "5"),
        (".5 + .25", "0.75"),
        ("1 / 8", "0.125"),
        ("/calc 0.123456789012345 / 1", "0.123456789012345"),
        ("1 / 3", "0.333333333333"),
    ]
    for (expression, answer) in examples {
        #expect(BasicCalculator.classify(expression) == .result(answer), "\(expression)")
    }
}

@Test func calculatorKeepsPartialArithmeticLocal() {
    for expression in ["2+", "2 + (", "2 * -", "3 ÷", "(2 + 3", "2 + .", "2 + 3."] {
        #expect(BasicCalculator.classify(expression) == .incomplete, "\(expression)")
    }
    #expect(BasicCalculator.classify("2 + * 3") == .failure("Expected a number or opening parenthesis."))
    #expect(BasicCalculator.classify("2 + 3)") == .failure("Unexpected text after the expression."))
    #expect(BasicCalculator.classify("2..3 + 4") == .failure("Invalid number."))
}

@Test func calcCommandForcesArithmeticAndKeepsErrorsLocal() {
    #expect(BasicCalculator.classify("/calc 42") == .result("42"))
    #expect(BasicCalculator.classify("/calc\t2/3") == .result("0.666666666667"))
    #expect(BasicCalculator.classify("/calc 1-2-3") == .result("-4"))
    #expect(BasicCalculator.classify("/calc") == .incomplete)
    #expect(BasicCalculator.classify("/calc   ") == .incomplete)
    #expect(BasicCalculator.classify("/calc 2 +") == .incomplete)
    #expect(BasicCalculator.classify("/calc words") == .failure("Use numbers and +, −, ×, ÷, or parentheses."))
    #expect(BasicCalculator.classify("/calc 1 / 0") == .failure("Cannot divide by zero."))
}

@Test func calculatorDoesNotStealSearchCommandsDatesPathsOrProse() {
    for text in [
        "", "42", "-5", "+5", "(42)", "1.25", "/span 1/2", "/calculate 2+2",
        "/tmp/2+3", "Documents/2026-10-21", "2026-10-21", "2026-10", "10-21", "21/10/2026",
        "1/2", "12/4", "1-2-3", "1234-5678", "hello 2+2", "2+two",
        "ISSN 1234-5678", "ABC-123", "2 + 2 = 4", "2+2\nmore",
    ] {
        #expect(BasicCalculator.classify(text) == .ordinary, "\(text)")
    }
}

@Test func calculatorRejectsUnsafeOrOversizedExpressions() {
    #expect(BasicCalculator.classify("2/0") == .failure("Cannot divide by zero."))
    #expect(BasicCalculator.classify("/calc 1 + 2; system('x')") == .failure("Use numbers and +, −, ×, ÷, or parentheses."))
    #expect(BasicCalculator.classify("/calc " + String(repeating: "9", count: 39)) == .failure("Number is outside the supported range."))
    #expect(BasicCalculator.classify("/calc " + String(repeating: "9", count: 257)) == .failure("Expression is too long."))
    #expect(BasicCalculator.classify("/calc " + String(repeating: "(", count: 33) + "1" + String(repeating: ")", count: 33)) == .failure("Too many nested parentheses."))
    let largeProduct = "/calc " + String(repeating: "9", count: 38) + " * " + String(repeating: "9", count: 38)
    if case .failure = BasicCalculator.classify(largeProduct) {
        // Expected: no bogus finite result for Decimal overflow.
    } else {
        Issue.record("Overflow was not reported as a failure")
    }
    let precisionLoss = "/calc " + String(repeating: "9", count: 38) + " + 0.1"
    if case .failure = BasicCalculator.classify(precisionLoss) {
        // Expected: adding one must not silently return the original value.
    } else {
        Issue.record("Precision loss was not reported as a failure")
    }
}
