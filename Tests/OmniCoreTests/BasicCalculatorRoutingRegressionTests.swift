import Testing
@testable import OmniCore

@Test func spacedChainedArithmeticIsNotAnUnspacedDateLiteral() {
    #expect(BasicCalculator.classify("2 - 3 - 4") == .result("-5"))
    #expect(BasicCalculator.classify("100 / 2 / 2") == .result("25"))
    #expect(BasicCalculator.classify("2026-10-21") == .ordinary)
}
