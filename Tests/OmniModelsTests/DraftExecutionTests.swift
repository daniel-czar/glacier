import Foundation
import OmniCore
import Testing
@testable import OmniModels

@Test(arguments: ["NEEDS_USER_DIRECTION", "NEEDS_USER_DIRECTION.", "needs_user_direction\nPlease choose an action.", "```\nNEEDS_USER_DIRECTION\n```"])
func draftDirectionFeedbackNeverBecomesASuccessfulDraft(reply: String) async throws {
    let corpus = FrozenContractCorpus()
    let provider = FixedReplyProvider(
        descriptor: .init(providerID: "local-direction", providerClass: .localCapable, isRemote: false),
        reply: reply
    )
    let catalog = try ProductionLanguageModuleCatalog(
        manifest: corpus.manifest(),
        declarations: corpus.moduleDeclarations().declarations,
        broker: ModelBroker(providers: [provider]),
        promptBuilder: LanguagePromptBuilder(emailGuide: .init(identifier: "test", version: "v1", status: "synthetic", text: "Be brief."))
    )
    let module = try #require(catalog.factories.first { $0.moduleID == "draft.email" }).build()
    let raw = "Hi Daniel, can you meet Thursday at 15:30? Mira /email /offline"
    let input = ModuleInput(canonicalText: raw, rawText: raw, payloadText: SlashTokenSyntax.payloadText(from: raw), modes: ["/offline"])
    let handle = try await module.start(plan: module.makePlan(input: input), capabilities: CapabilityBroker(declared: [.draftCommunication]), runID: "direction-test")
    guard case .failed(let summary) = await handle.value() else {
        Issue.record("A missing-direction response must not be shown as a draft")
        return
    }
    #expect(summary.contains("Add what you want to say"))
    #expect(!summary.contains("NEEDS_USER_DIRECTION"))
    #expect(await handle.modelExecutionRecord() != nil)
}
