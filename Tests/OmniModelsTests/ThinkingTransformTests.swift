import Foundation
import Testing
import OmniCore
@testable import OmniModels

// Milestone 3 of the decision step: /structure, /expand:<lens> and /meaning
// (amendment 1.4.0), identity-bound text results on the fast profile.

private func transformInput(_ raw: String, values: [String: TokenValue] = [:]) -> ModuleInput {
    ModuleInput(canonicalText: raw, rawText: raw, payloadText: SlashTokenSyntax.payloadText(from: raw), tokenValues: values)
}

@Test func structurePreservesContentNamesTheConceptAndFlagsAmbiguity() throws {
    let identity = try goldenIdentity()
    let prompt = try LanguagePromptBuilder(identityGuide: identity).prompt(for: .structure, input: transformInput("prices go up because there is only one supplier and also nobody else can enter /structure"))
    #expect(prompt.hasPrefix(LanguagePromptBuilder.structureInstruction))
    #expect(prompt.contains("Preserve all semantic content"))
    #expect(prompt.contains("name it explicitly, using the established term from its field"))
    #expect(prompt.contains("flag it rather than resolving it silently"))
    #expect(prompt.components(separatedBy: identity.modelFacingBlock).count == 2)
    #expect(prompt.contains(ModelOutputDiscipline.instruction))
    #expect(prompt.hasSuffix("User text:\nprices go up because there is only one supplier and also nobody else can enter"))
    // The guide's chat conduct (no first-letter capitals) is for chat only.
    #expect(prompt.contains("Its chat-message conduct does not apply here: keep the capitalisation and register of the user text."))
    #expect(prompt.contains("Never return the text unchanged."))
}

@Test func expandRunsOneLensFromTheValuedTokenAndNeverShiftsToSecondPerson() throws {
    let builder = LanguagePromptBuilder()
    let deepen = try builder.prompt(for: .expand, input: transformInput("receipts make agents honest /expand:deepen", values: ["/expand": .enumMember("deepen")]))
    #expect(deepen.contains("Expand it through one lens. Deepen: push the core argument further."))
    #expect(deepen.contains("Never shift to second-person address"))
    #expect(deepen.contains("a genuinely different take, not a paraphrase"))
    #expect(!deepen.contains("Broaden:"))
    let challenge = try builder.prompt(for: .expand, input: transformInput("x /expand:challenge", values: ["/expand": .enumMember("challenge")]))
    #expect(challenge.contains("Challenge: find the tension."))
    // A bare /expand outside the pad expands through all five lenses.
    let bare = try builder.prompt(for: .expand, input: transformInput("receipts make agents honest /expand"))
    for lens in ["Deepen:", "Broaden:", "Concretise:", "Challenge:", "Connect:"] { #expect(bare.contains(lens)) }
}

@Test func meaningGivesAnInvariantCoreAndAMapOfNearbyTerms() throws {
    let prompt = try LanguagePromptBuilder().prompt(for: .meaning, input: transformInput("/meaning reflexivity"))
    #expect(prompt.contains("Define it at its invariant core"))
    #expect(prompt.contains("a short map of nearby terms: three to six lines, each \"term — how it differs\""))
    #expect(prompt.hasSuffix("User text:\nreflexivity"))
}

@Test func transformsRouteOnTheFastProfileAsTextAndBindIdentity() throws {
    for id in [OmniDecisionStep.structureModuleID, OmniDecisionStep.expandModuleID, OmniDecisionStep.meaningModuleID] {
        let command = try #require(ModelProviderPolicy.v6.command(named: id))
        #expect(command.primaryProfileIDs == [ProviderRuntimeCatalog.cerebrasFastProfileID])
        #expect(command.outputShape == .plainText)
        #expect(ProviderRuntimeCatalog.routineCommandIDs.contains(id))
        let workflow = try #require(LanguageWorkflow(rawValue: id))
        #expect(workflow.bindsIdentityByDefault)
        #expect(workflow.resultActions == [.copy, .dismiss])
    }
    #expect(ModelProviderPolicy.v6.version == "6.0.0")
}
