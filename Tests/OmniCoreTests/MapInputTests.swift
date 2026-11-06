import Foundation
import Testing

@Test func politePleaseAfterModalStillRefusesNativeUnsupportedForm() {
    #expect(OmniMapInput.parse("Could you please draw a Venn diagram of A and B?").refusal?.contains("Venn") == true)
    #expect(OmniMapInput.parse("Would you please draw a Venn diagram?").refusal?.contains("Venn") == true)
}
@testable import OmniCore

@Test func explicitAliasWinsAndReturnsModeRange() {
    let parsed = OmniMapInput.parse("scrum as a causal loop", pinnedForm: .tree)
    #expect(parsed.query == "scrum")
    #expect(parsed.pinnedForm == .loop)
    #expect(parsed.modeRange.map { ("scrum as a causal loop" as NSString).substring(with: $0) } == "as a causal loop")
}

@Test func comparisonAndBridgeSignals() {
    #expect(OmniMapInput.parse("book vs document").candidateForms == [.matrix, .bridge])
    #expect(OmniMapInput.parse("explain git to a librarian").suggestedForm == .bridge)
    #expect(OmniMapInput.parse("why do libraries matter?").suggestedForm == .tree)
    #expect(OmniMapInput.parse("why do libraries matter?").pinnedForm == nil)
    #expect(OmniMapInput.parse("explain git to a librarian", pinnedForm: .tree).pinnedForm == .tree)
}

@Test func refusalIsSpecificToRequestedForm() {
    #expect(OmniMapInput.parse("books as a Venn diagram").refusal?.contains("Venn") == true)
    #expect(OmniMapInput.parse("draw an ER diagram").refusal?.contains("entity–relationship") == true)
    #expect(OmniMapInput.parse("books as ER").refusal?.contains("entity–relationship") == true)
    #expect(OmniMapInput.parse("Venn of books and documents").refusal?.contains("Venn") == true)
    #expect(OmniMapInput.parse("what is ontology?").refusal == nil)
    #expect(OmniMapInput.parse("ontology as a tree").pinnedForm == .tree)
    #expect(OmniMapInput.parse("Can you draw a Venn diagram?").refusal?.contains("Venn") == true)
    #expect(OmniMapInput.parse("please draw a Venn diagram").refusal?.contains("Venn") == true)
    #expect(OmniMapInput.parse("I need a Venn diagram").refusal?.contains("Venn") == true)
    #expect(OmniMapInput.parse("what is a Venn diagram?").refusal == nil)
}

@Test func terminalPunctuationDoesNotHideTheMode() {
    let native = OmniMapInput.parse("scrum as a loop?")
    #expect(native.query == "scrum")
    #expect(native.pinnedForm == .loop)
    #expect(native.modeRange.map { ("scrum as a loop?" as NSString).substring(with: $0) } == "as a loop?")
    let refused = OmniMapInput.parse("books as a Venn diagram?")
    #expect(refused.refusal?.contains("Venn") == true)
}
