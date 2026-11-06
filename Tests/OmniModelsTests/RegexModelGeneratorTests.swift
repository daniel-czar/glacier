import OmniCore
import OmniModels
import Testing

@Test func regexRequestUsesHighProfileAndLocallyValidatedJSONContract() {
    let request = RegexModelGenerator.request(intent: "UK postcode", runID: "test")
    #expect(request.commandID == "regex.write")
    #expect(request.dispatch?.selection?.profileID == ProviderRuntimeCatalog.cerebrasRegexHighProfileID)
    #expect(request.outputConstraint.shape == .plainText)
    #expect(request.prompt.contains("ICU"))
    #expect(request.prompt.contains("at least 3"))
    #expect(!request.prompt.contains("draw a diagram for the user"))
}

@Test func regexModelReplyValidatesContractButPreservesInvalidPattern() throws {
    let valid = #"{"pattern":"[","flavor":"icu","name":"bad pattern","shouldMatch":["a","b","c"],"shouldNotMatch":["x","y"],"note":"Known limitation"}"#
    let pattern = try RegexModelGenerator.parse(valid)
    #expect(pattern.pattern == "[")
    #expect(pattern.evaluateExamples().compileError != nil)
    #expect(throws: RegexModelError.self) { try RegexModelGenerator.parse("Here: " + valid) }
    #expect(throws: RegexModelError.self) {
        try RegexModelGenerator.parse(#"{"pattern":"a","flavor":"javascript","name":"a","shouldMatch":["a","a","a"],"shouldNotMatch":["b","c"]}"#)
    }
    #expect(throws: RegexModelError.self) {
        try RegexModelGenerator.parse(#"{"pattern":"a","flavor":"icu","name":"a","shouldMatch":["a","a"],"shouldNotMatch":["b","c"]}"#)
    }
    #expect(throws: RegexModelError.self) {
        try RegexModelGenerator.parse(#"{"pattern":"a","flavor":"icu","name":"a","shouldMatch":["a","a","a"],"shouldNotMatch":["b","c"],"note":"one two three four five six seven eight nine ten eleven twelve thirteen"}"#)
    }
}
