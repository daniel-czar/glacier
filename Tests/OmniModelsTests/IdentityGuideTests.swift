import Foundation
import Testing
import OmniCore
@testable import OmniModels

// Milestone 0 of the decision step (D4, C+): the identity guide is bound to
// /email and /msg, injected as a labelled block after the style guides and
// before grounding, and recorded in the receipt. Mechanical commands stay
// byte-identical (PromptGoldenTests).

private let emailGuide = PinnedLanguageGuide(identifier: "email-guide", version: "v1", status: "adopted-current", text: "Say what matters, then stop.")
private let sharedGuide = PinnedLanguageGuide(identifier: "shared-guide", version: "v1", status: "adopted-current", text: "Plain words.")
private let registeredIdentityGuide = OmniLayout.styleguideRoot.appendingPathComponent("identity-guide-v0_33d634c53d301d98.md")

private func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

@Test func identityGuideInjectsOnlyItsModelFacingBlock() throws {
    let identity = try goldenIdentity()
    #expect(identity.modelFacingBlock == "IDENTITY — who is asking. Never use it to invent circumstances.\n\nConduct\n- Takes a position without hedging.")
    #expect(identity.reference.identifier == "golden-identity")
    // The pin covers the whole file, so the receipt hash matches the document.
    #expect(identity.reference.contentSHA256 == PinnedLanguageGuide(identifier: "x", version: "v0", status: "s", text: goldenIdentityGuideText).reference.contentSHA256)
}

@Test func identityGuideWithoutAModelFacingBlockFailsComposition() {
    for text in [
        "# Guide\n\nNo block here.",
        "## Model-Facing Block\n\n## Next\n\n```text\nlate\n```",
        "## Model-Facing Block\n\n```text\nunterminated",
        "## Model-Facing Block\n\n```text\n\n```",
    ] {
        #expect(PinnedIdentityGuide.modelFacingBlock(in: text) == nil)
        #expect(throws: ProductionLanguageModuleError.self) {
            try PinnedIdentityGuide(PinnedLanguageGuide(identifier: "i", version: "v0", status: "s", text: text))
        }
    }
}

@Test func registeredIdentityGuideExtractsItsConductAndFactsBlock() throws {
    // The live guide is Daniel's file; skip when this machine lacks it.
    guard let text = try? String(contentsOf: registeredIdentityGuide, encoding: .utf8) else { return }
    let block = try #require(PinnedIdentityGuide.modelFacingBlock(in: text))
    #expect(block.hasPrefix("IDENTITY — who is asking."))
    #expect(block.contains("Conduct"))
    #expect(!block.contains("Dedupe Ledger"))
    #expect(!block.contains("Daniel Writes This Section"))
}

@Test(arguments: [LanguageWorkflow.email, .message])
func boundDraftingPromptCarriesTheIdentityBlockOnceBetweenGuidesAndGrounding(workflow: LanguageWorkflow) throws {
    let identity = try goldenIdentity()
    let builder = LanguagePromptBuilder(emailGuide: emailGuide, sharedGuide: sharedGuide, identityGuide: identity)
    let token = workflow == .email ? "/email" : "/msg"
    let raw = "\(token) tell Mira Thursday works"
    let prompt = try builder.prompt(for: workflow, input: ModuleInput(canonicalText: raw, rawText: raw, payloadText: SlashTokenSyntax.payloadText(from: raw)))
    #expect(occurrences(of: identity.modelFacingBlock, in: prompt) == 1)
    #expect(occurrences(of: "Identity guide (golden-identity v0, synthetic-test, SHA-256 \(identity.reference.contentSHA256)):", in: prompt) == 1)
    #expect(!prompt.contains("not injected"))
    #expect(!prompt.contains("Binding in Omni"))
    // Labelled, after the style guides and before grounding.
    let block = try #require(prompt.range(of: identity.modelFacingBlock))
    let shared = try #require(prompt.range(of: "Inherited Shared Voice Core"))
    let grounding = try #require(prompt.range(of: "Factual grounding:"))
    #expect(shared.upperBound <= block.lowerBound)
    #expect(block.upperBound <= grounding.lowerBound)
    // STYLE-ONLY gains a carve-out; grounding keeps the identity guide out of
    // situational facts carried by the structured request.
    #expect(prompt.contains("The identity block after the guides is different: it describes the author. Use it to choose and shape; never use it to invent circumstances. Stating a position without hedging never means supplying availability, times, or dates."))
    #expect(prompt.contains("the request JSON separates supplied material from the user's drafting request and annotations"))
    #expect(prompt.contains("The identity guide can describe the author but never supplies availability, workload, commitments or reasons."))
    let data = try #require(prompt.split(separator: "\n", omittingEmptySubsequences: false).last)
    let envelope = try #require(JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any])
    #expect(envelope["supplied_material"] as? String == "")
    #expect(envelope["user_request"] as? String == "tell Mira Thursday works")
    #expect(builder.contextGuides(for: workflow).last == identity.reference)
}

@Test func draftingPromptThatOptsOutOfIdentityKeepsItsUnboundBytes() throws {
    let raw = "/email ✓ Thursday at 15:30 works"
    let input = ModuleInput(canonicalText: raw, rawText: raw, payloadText: SlashTokenSyntax.payloadText(from: raw), markers: ["✓"])
    let unbound = try LanguagePromptBuilder(emailGuide: emailGuide, sharedGuide: sharedGuide).prompt(for: .email, input: input)
    let optedOut = try LanguagePromptBuilder(emailGuide: emailGuide, sharedGuide: sharedGuide, identityGuide: try goldenIdentity())
        .prompt(for: .email, input: input, bindsIdentity: false)
    #expect(optedOut == unbound)
    #expect(LanguagePromptBuilder(emailGuide: emailGuide, sharedGuide: sharedGuide, identityGuide: try goldenIdentity()).contextGuides(for: .email, bindsIdentity: false) == [sharedGuide.reference])
}

@Test func mechanicalAndQuickWorkflowsNeverBindIdentity() throws {
    let builder = LanguagePromptBuilder(emailGuide: emailGuide, sharedGuide: sharedGuide, identityGuide: try goldenIdentity())
    for workflow in [LanguageWorkflow.translation, .slug, .quickQuestion] {
        #expect(!workflow.bindsIdentityByDefault)
        #expect(builder.contextGuides(for: workflow).isEmpty)
    }
    #expect(LanguageWorkflow.email.bindsIdentityByDefault)
    #expect(LanguageWorkflow.message.bindsIdentityByDefault)
}

@Test func offlineEmailRunStillBindsTheIdentityGuideAndRecordsItsHash() async throws {
    let corpus = FrozenContractCorpus()
    let identity = try goldenIdentity()
    let provider = FixedReplyProvider(
        descriptor: .init(providerID: "local", providerClass: .localCapable, isRemote: false),
        reply: "Hi Mira,\n\nThursday works.\n\nDaniel"
    )
    let recorder = RecordingGenerator(inner: ModelBroker(providers: [provider]))
    let catalog = try ProductionLanguageModuleCatalog(
        manifest: try corpus.manifest(),
        declarations: try corpus.moduleDeclarations().declarations,
        broker: recorder,
        promptBuilder: LanguagePromptBuilder(emailGuide: emailGuide, sharedGuide: sharedGuide, identityGuide: identity)
    )
    let module = try #require(catalog.factories.first { $0.moduleID == "draft.email" }).build()
    let input = ModuleInput(canonicalText: "/email /offline tell Mira Thursday works", payloadText: "tell Mira Thursday works", modes: ["/offline"])
    let plan = try module.makePlan(input: input)
    #expect(plan.offline)
    let handle = try await module.start(plan: plan, capabilities: CapabilityBroker(declared: [.draftCommunication]), runID: "run-identity")
    guard case .succeeded(let result) = await handle.value() else {
        Issue.record("expected an offline email result")
        return
    }
    let request = try #require(await recorder.requests().first)
    #expect(request.offline)
    #expect(occurrences(of: identity.modelFacingBlock, in: request.prompt) == 1)
    #expect(request.contextGuides.contains(identity.reference))
    #expect(result.modelRecord?.contextGuides.contains(identity.reference) == true)
}

struct FixedReplyProvider: ModelProvider {
    let descriptor: ModelProviderDescriptor
    let reply: String

    func generate(_ request: ModelGenerationRequest) async throws -> ModelProviderResponse {
        ModelProviderResponse(text: reply, usage: ModelUsage(inputTokens: 3, outputTokens: 5))
    }
}

/// Records each generation request on its way to the wrapped broker.
actor RecordingGenerator: ModelGenerating {
    private let inner: any ModelGenerating
    private var recorded: [ModelGenerationRequest] = []

    init(inner: any ModelGenerating) { self.inner = inner }

    func requests() -> [ModelGenerationRequest] { recorded }

    func execute(_ request: ModelGenerationRequest) async throws -> ModelBrokerResult {
        recorded.append(request)
        return try await inner.execute(request)
    }

    func cancellationRecord(for request: ModelGenerationRequest) async -> ModelExecutionRecord {
        await inner.cancellationRecord(for: request)
    }
}

@Test func aBindingIsIgnoredWhereThePromptHasNoPlaceForIdentity() throws {
    // A receipt must never name a guide its prompt did not carry.
    let builder = LanguagePromptBuilder(emailGuide: emailGuide, sharedGuide: sharedGuide, identityGuide: try goldenIdentity())
    let raw = "what is a forcing function /qq"
    let input = ModuleInput(canonicalText: raw, rawText: raw, payloadText: SlashTokenSyntax.payloadText(from: raw))
    for workflow in [LanguageWorkflow.translation, .slug, .quickQuestion] {
        #expect(!workflow.rendersIdentity)
        #expect(builder.contextGuides(for: workflow, bindsIdentity: true).isEmpty)
        #expect(try builder.prompt(for: workflow, input: input, bindsIdentity: true) == builder.prompt(for: workflow, input: input, bindsIdentity: false))
    }
}

@Test func aDeclineMarkerDefersToAPositionNoteOnlyWhenOneExists() throws {
    let builder = LanguagePromptBuilder(emailGuide: emailGuide, sharedGuide: sharedGuide)
    let raw = "Mira asked about Thursday. /email ✗"
    let input = ModuleInput(canonicalText: raw, rawText: raw, payloadText: SlashTokenSyntax.payloadText(from: raw), markers: ["✗"])
    let plain = try builder.prompt(for: .email, input: input)
    #expect(plain.contains("do not add a reason, alternative date, or counterproposal unless the user supplied it"))
    let pick = OmniTextAnnotation.request(guidance: "Decline and offer an email review instead.", origin: .proposed, label: "Decline, offer email review")
    let noted = try builder.prompt(for: .email, input: input, annotations: [pick])
    #expect(noted.contains("Offer an alternative only where a whole-request note or the user's own notes ask for one, and never a date or time that neither the user text nor the user's own notes contain."))
    #expect(!noted.contains("counterproposal unless the user supplied it"))
    // A ticked item is a whole-request note too, but not a position: it never
    // licenses an alternative.
    let tick = OmniTextAnnotation.request(guidance: "suppression: No alternative format is suggested — take this into account in the response.", origin: .proposed)
    #expect(try builder.prompt(for: .email, input: input, annotations: [tick]).contains("counterproposal unless the user supplied it"))
}
