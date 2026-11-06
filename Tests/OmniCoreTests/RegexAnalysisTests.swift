import Foundation
import OmniCore
import Testing

@Suite struct RegexAnalysisTests {
    @Test func parsesReferencePatternAndKeepsRawTokens() throws {
        let analysis = RegexAnalysis(pattern: #"^(\d{4})-(\d{2})-(\d{2})$"#)
        #expect(analysis.compileFailure == nil)
        #expect(analysis.parseFailure == nil)
        #expect(analysis.diagramStatus == .available)
        #expect(analysis.groupCount == 3)
        #expect(analysis.anchored)
        let ast = try #require(analysis.ast)
        #expect(ast.raw == analysis.pattern)
        #expect(ast.children.contains { $0.raw == #"(\d{4})"# })
        #expect(ast.children.contains { $0.raw == "$" })
    }

    @Test func parsesAlternativesLookaroundsNamedReferencesFlagsAndLazyCount() throws {
        let analysis = RegexAnalysis(pattern: #"(?i)^(?<word>\w{1,3}?)(?=\s)\k<word>$|^b$"#)
        #expect(analysis.compileFailure == nil)
        #expect(analysis.parseFailure == nil)
        #expect(analysis.anchored)
        #expect(analysis.groupCount == 1)
        #expect(analysis.flagsSummary.contains("case-insensitive"))
        let ast = try #require(analysis.ast)
        #expect(ast.kind == .alternation)
        #expect(ast.raw.contains(#"\k<word>"#))
    }

    @Test func rejectsUnsupportedDiagramSyntaxWithoutClaimingRegexIsInvalid() {
        let analysis = RegexAnalysis(pattern: #"(?i)^\p{L}+$"#)
        #expect(analysis.compileFailure == nil)
        #expect(analysis.diagramStatus == .unparsable)
        #expect(analysis.parseFailure != nil)
        #expect(analysis.ast == nil)
        #expect(analysis.anchored)
        #expect(analysis.flagsSummary.contains("case-insensitive"))
        #expect(!analysis.metadataIsReliable)
        #expect(RegexAnalysis(pattern: #"(?i)(?-i)^\p{L}+$"#).flagsSummary.isEmpty)
    }

    @Test func longPatternStillCompilesAndMatchesButSkipsDiagram() {
        let pattern = "^" + String(repeating: "a", count: 201) + "$"
        let analysis = RegexAnalysis(pattern: pattern)
        #expect(analysis.diagramStatus == .tooLong)
        #expect(analysis.compileFailure == nil)
        #expect(analysis.ast == nil)
        #expect(analysis.anchored)
        let result = RegexSelectionMatches.evaluate(pattern: pattern, selection: String(repeating: "a", count: 201))
        #expect(result.matchingLineCount == 1)
    }

    @Test func malformedPatternIsLocalFailureAndProseIsProse() {
        #expect(RegexInputClassification.classify("[unclosed") == .invalidPattern(reason: RegexAnalysis(pattern: "[unclosed").compileFailure ?? ""))
        #expect(RegexInputClassification.classify("a.b") == .pattern)
        #expect(RegexInputClassification.classify("find an email address") == .prose)
    }

    @Test func flagsAndGroupedAnchorsDoNotMisstatePattern() {
        let disabled = RegexAnalysis(pattern: "(?i)(?-i)a")
        #expect(disabled.flagsSummary.isEmpty)
        let scoped = RegexAnalysis(pattern: "(?i:a)b")
        #expect(scoped.flagsSummary == ["scoped case-insensitive"])
        let extended = RegexAnalysis(pattern: "(?x)a b")
        #expect(extended.compileFailure == nil)
        #expect(extended.diagramStatus == .unparsable)
        #expect(RegexAnalysis(pattern: "(?:^a|^b)").anchored)
        #expect(!RegexAnalysis(pattern: "^a|b").anchored)
    }

    @Test func combinedCharacterClassHasReadableName() throws {
        let ast = try #require(RegexAnalysis(pattern: #"[A-Z\d]"#).ast)
        #expect(ast.children.first?.kind == .characterClass("A–Z, digit"))
    }

    @Test func matchesSelectionByLineAndPreservesUTF16OffsetsAndCaptures() throws {
        let result = RegexSelectionMatches.evaluate(pattern: #"(\d{2})"#,
                                                    selection: "😀12\r\nabc\n34\n56", visibleLimit: 2)
        #expect(result.compileFailure == nil)
        #expect(result.matchFailure == nil)
        #expect(result.totalLineCount == 4)
        #expect(result.matchingLineCount == 3)
        #expect(result.lines.count == 2)
        let match = try #require(result.lines.first?.matches.first)
        #expect(match.range == NSRange(location: 2, length: 2))
        #expect(match.captures == ["12"])
        #expect(result.lines[1].matched == false)
    }
}
