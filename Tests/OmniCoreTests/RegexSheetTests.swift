import OmniCore
import Testing

@Test func regexSheetSearchUsesNamesAndSavedIntents() {
    let entries = [
        RegexSheetEntry(name: "Email", pattern: #"[^@]+@[^@]+"#, intentAliases: ["email address", "email addresses"]),
        RegexSheetEntry(name: "URL", pattern: #"https?://"#),
        RegexSheetEntry(name: "ISO date", pattern: #"\d{4}-\d{2}-\d{2}"#),
    ]
    let empty = RegexSheetMatcher.search("", in: entries)
    #expect(empty.sheet == entries)
    #expect(!empty.shouldGenerate)
    let exact = RegexSheetMatcher.search("match email addresses", in: entries)
    #expect(exact.sheet.first?.name == "Email")
    #expect(exact.strongHit && !exact.shouldGenerate)
    let typo = RegexSheetMatcher.search("emial", in: entries)
    #expect(typo.sheet.first?.name == "Email")
    #expect(typo.strongHit)
    let unknown = RegexSheetMatcher.search("UK postcode", in: entries)
    #expect(unknown.sheet.isEmpty)
    #expect(unknown.shouldGenerate)
    let qualified = RegexSheetMatcher.search("email ending in acme dot com", in: entries)
    #expect(!qualified.strongHit && qualified.shouldGenerate)
}

@Test func regexExamplesUseICUEngineForEveryVerdict() {
    let generated = RegexGeneratedPattern(pattern: #"^\d+$"#, name: "digits",
        shouldMatch: ["123", "abc", "0"], shouldNotMatch: ["no", "456"])
    let result = generated.evaluateExamples()
    #expect(result.examples.count == 5)
    #expect(result.disagreementCount == 2)
    #expect(result.examples[1].verdict == "✗ should match · doesn't")
    #expect(result.examples[4].verdict == "✗ should not · matches")
    #expect(result.compileError == nil)

    let invalid = RegexGeneratedPattern(pattern: "[", name: "broken",
        shouldMatch: ["a", "b", "c"], shouldNotMatch: ["x", "y"]).evaluateExamples()
    #expect(invalid.compileError != nil)
    #expect(invalid.examples.count == 5)
    #expect(invalid.examples.allSatisfy { $0.doesMatch == nil })
    #expect(invalid.disagreementCount == 0)
}
