import Foundation

public enum BasicCalculationState: Equatable, Sendable {
    case ordinary
    case incomplete
    case result(String)
    case failure(String)
}

/// A local, bounded four-function calculator. Direct recognition deliberately
/// requires a whole numeric expression with a binary operator. Bare numbers,
/// leading slash commands, date-shaped strings, and ambiguous short `a/b`
/// literals stay in ordinary search; `/calc` explicitly opts in to arithmetic.
public enum BasicCalculator {
    public static func classify(_ input: String) -> BasicCalculationState {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let forced: Bool
        let expression: String
        if trimmed == "/calc" {
            forced = true
            expression = ""
        } else if trimmed.hasPrefix("/calc"), trimmed.dropFirst(5).first?.isWhitespace == true {
            forced = true
            expression = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            forced = false
            expression = trimmed
        }

        if !forced {
            guard !expression.isEmpty, !expression.hasPrefix("/"), !expression.contains("\n"),
                  !expression.contains("\r"), expression.unicodeScalars.allSatisfy(isArithmeticScalar),
                  !looksLikeDateOrIdentifier(expression), hasBinaryCandidate(expression)
            else { return .ordinary }
        }

        guard !expression.isEmpty else { return forced ? .incomplete : .ordinary }
        guard expression.count <= 256 else { return .failure("Expression is too long.") }

        do {
            let tokens = try tokenize(expression)
            var parser = Parser(tokens: tokens)
            let value = try parser.parse()
            if !forced && !parser.sawBinaryOperator { return .ordinary }
            var display = value
            if parser.roundedDivision {
                var rounded = Decimal()
                NSDecimalRound(&rounded, &display, 12, .plain)
                // A tiny nonzero quotient must never be displayed as zero.
                if rounded != 0 || display == 0 { display = rounded }
            }
            let number = NSDecimalNumber(decimal: display)
            guard number != .notANumber else { return .failure("Result is outside the supported range.") }
            return .result(number == 0 ? "0" : number.stringValue)
        } catch CalculatorError.incomplete {
            return .incomplete
        } catch CalculatorError.invalid(let message) {
            return .failure(message)
        } catch {
            return .failure("Invalid expression.")
        }
    }

    private static func isArithmeticScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 32, 9, 43, 45, 42, 47, 46, 40, 41, 0x00D7, 0x00F7, 0x2212:
            return true
        default:
            return false
        }
    }

    private static func hasBinaryCandidate(_ text: String) -> Bool {
        // Parentheses or a unary sign alone must not steal a numeric search.
        let chars = Array(text)
        for index in chars.indices where "+-*/×÷−".contains(chars[index]) {
            if index > 0 && chars[..<index].contains(where: { $0.isASCII && $0.isNumber || $0 == ")" }) {
                return true
            }
        }
        return false
    }

    private static func looksLikeDateOrIdentifier(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace }
        let chars = Array(compact)
        // Compact short slash pairs are plausible day/month literals. Spaces,
        // parentheses, other operations, and `/calc` disambiguate division.
        if chars.filter({ $0 == "/" }).count == 1,
           let slash = chars.firstIndex(of: "/"),
           slash > 0, slash + 1 < chars.count,
           chars.allSatisfy({ $0.isASCII && $0.isNumber || $0 == "/" }),
           text == compact,
           let left = Int(String(chars[..<slash])), let right = Int(String(chars[(slash + 1)...])),
           (1...31).contains(left), (1...12).contains(right) {
            return true
        }
        // Three compact numeric components using date separators are more
        // likely a date or ID than a request for chained subtraction/division.
        for separator: Character in ["-", "/", "."] {
            let parts = compact.split(separator: separator, omittingEmptySubsequences: false)
            if text == compact && parts.count == 3 && parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) {
                return true
            }
        }
        // Long hyphenated digits are commonly IDs. Arithmetic remains
        // available with spaces or an explicit `/calc` prefix.
        let hyphenParts = compact.split(separator: "-", omittingEmptySubsequences: false)
        if hyphenParts.count == 2, text == compact,
           let first = Int(hyphenParts[0]), let second = Int(hyphenParts[1]),
           hyphenParts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
           hyphenParts[1].allSatisfy({ $0.isASCII && $0.isNumber }) {
            if hyphenParts[0].count == 4 && (1...12).contains(second) { return true } // year-month
            if hyphenParts[0].count == 2 && hyphenParts[1].count == 2,
               (1...12).contains(first), (1...31).contains(second) { return true } // month-day
        }
        if hyphenParts.count == 2, hyphenParts.allSatisfy({ $0.count >= 4 && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }), text == compact {
            return true
        }
        return false
    }

    private enum Token {
        case number(Decimal)
        case symbol(Character)
    }

    private enum CalculatorError: Error {
        case incomplete
        case invalid(String)
    }

    private static func tokenize(_ text: String) throws -> [Token] {
        let chars = Array(text)
        var tokens: [Token] = []
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char.isWhitespace { index += 1; continue }
            if char.isASCII && char.isNumber || char == "." {
                let start = index
                var digits = 0
                var dots = 0
                while index < chars.count, chars[index].isASCII && chars[index].isNumber || index < chars.count && chars[index] == "." {
                    if chars[index] == "." { dots += 1 } else { digits += 1 }
                    index += 1
                }
                if digits == 0 && index == chars.count { throw CalculatorError.incomplete }
                guard digits > 0, dots <= 1 else { throw CalculatorError.invalid("Invalid number.") }
                if chars[index - 1] == "." && index == chars.count { throw CalculatorError.incomplete }
                if chars[index - 1] == "." { throw CalculatorError.invalid("Invalid number.") }
                guard digits <= 38 else { throw CalculatorError.invalid("Number is outside the supported range.") }
                let literal = String(chars[start..<index])
                guard let value = Decimal(string: literal, locale: Locale(identifier: "en_US_POSIX")),
                      NSDecimalNumber(decimal: value) != .notANumber
                else { throw CalculatorError.invalid("Invalid number.") }
                tokens.append(.number(value))
            } else if "+-*/()×÷−".contains(char) {
                tokens.append(.symbol(char))
                index += 1
            } else {
                throw CalculatorError.invalid("Use numbers and +, −, ×, ÷, or parentheses.")
            }
            if tokens.count > 128 { throw CalculatorError.invalid("Expression is too complex.") }
        }
        return tokens
    }

    private struct Parser {
        let tokens: [Token]
        var index = 0
        var depth = 0
        var sawBinaryOperator = false
        var roundedDivision = false

        mutating func parse() throws -> Decimal {
            let value = try expression()
            guard index == tokens.count else { throw CalculatorError.invalid("Unexpected text after the expression.") }
            return value
        }

        private mutating func expression() throws -> Decimal {
            var value = try term()
            while let symbol = currentSymbol(), symbol == "+" || symbol == "-" || symbol == "−" {
                index += 1
                sawBinaryOperator = true
                let rhs = try term()
                value = try calculate(symbol, value, rhs)
            }
            return value
        }

        private mutating func term() throws -> Decimal {
            var value = try factor()
            while let symbol = currentSymbol(), symbol == "*" || symbol == "/" || symbol == "×" || symbol == "÷" {
                index += 1
                sawBinaryOperator = true
                let rhs = try factor()
                value = try calculate(symbol, value, rhs)
            }
            return value
        }

        private mutating func factor() throws -> Decimal {
            guard index < tokens.count else { throw CalculatorError.incomplete }
            if let symbol = currentSymbol(), symbol == "+" || symbol == "-" || symbol == "−" {
                index += 1
                let value = try factor()
                return symbol == "+" ? value : -value
            }
            switch tokens[index] {
            case .number(let value):
                index += 1
                return value
            case .symbol("("):
                index += 1
                depth += 1
                guard depth <= 32 else { throw CalculatorError.invalid("Too many nested parentheses.") }
                let value = try expression()
                guard index < tokens.count else { throw CalculatorError.incomplete }
                guard currentSymbol() == ")" else { throw CalculatorError.invalid("Missing closing parenthesis.") }
                index += 1
                depth -= 1
                return value
            default:
                throw CalculatorError.invalid("Expected a number or opening parenthesis.")
            }
        }

        private func currentSymbol() -> Character? {
            guard index < tokens.count, case .symbol(let symbol) = tokens[index] else { return nil }
            return symbol
        }

        private mutating func calculate(_ symbol: Character, _ lhs: Decimal, _ rhs: Decimal) throws -> Decimal {
            var left = lhs
            var right = rhs
            var result = Decimal()
            let status: NSDecimalNumber.CalculationError
            switch symbol {
            case "+": status = NSDecimalAdd(&result, &left, &right, .plain)
            case "-", "−": status = NSDecimalSubtract(&result, &left, &right, .plain)
            case "*", "×": status = NSDecimalMultiply(&result, &left, &right, .plain)
            case "/", "÷":
                guard rhs != 0 else { throw CalculatorError.invalid("Cannot divide by zero.") }
                status = NSDecimalDivide(&result, &left, &right, .plain)
                var quotient = result
                var divisor = right
                var reconstructed = Decimal()
                let reverseStatus = NSDecimalMultiply(&reconstructed, &quotient, &divisor, .plain)
                if reverseStatus != .noError || reconstructed != lhs { roundedDivision = true }
            default: throw CalculatorError.invalid("Unsupported operation.")
            }
            guard status == .noError || ((symbol == "/" || symbol == "÷") && status == .lossOfPrecision) else {
                throw CalculatorError.invalid("Result is outside the supported range or precision.")
            }
            guard NSDecimalNumber(decimal: result) != .notANumber else {
                throw CalculatorError.invalid("Result is outside the supported range.")
            }
            if symbol != "/" && symbol != "÷" && !roundedDivision {
                let rendered = NSDecimalNumber(decimal: result).stringValue
                let digits = rendered.filter(\.isNumber)
                guard digits.count <= 38, !rendered.lowercased().contains("e") else {
                    throw CalculatorError.invalid("Result is outside the supported range or precision.")
                }
                if symbol == "+" || symbol == "-" || symbol == "−" {
                    var recovered = Decimal()
                    var output = result
                    var original = lhs
                    let reverse = symbol == "+"
                        ? NSDecimalSubtract(&recovered, &output, &original, .plain)
                        : NSDecimalSubtract(&recovered, &original, &output, .plain)
                    guard reverse == .noError, recovered == rhs else {
                        throw CalculatorError.invalid("Result is outside the supported range or precision.")
                    }
                }
            }
            return result
        }
    }
}
