import Foundation
import Testing
import OmniCore
@testable import OmniModels

// Milestone 1 of the decision step: `/stance` as a model-backed primary
// (amendment 1.4.0, D1) with its pre-pass prompt, output shape, policy row
// and the qualification rule (C67).

private let stanceReply = #"{"positions":[{"title":"Accept as asked","approach":"Say yes plainly.","kind":"accept"},{"title":"Decline without a reason","approach":"Say no; add nothing.","kind":"decline"},{"title":"Ask one question","approach":"Ask which day suits.","kind":"other"}],"noticed":[{"type":"suppression","quote":"if that's kinder to your stack","note":"Mira plays down her own constraint."}]}"#

private func stanceInput(_ material: String) -> ModuleInput {
    let raw = material + " /stance"
    return ModuleInput(canonicalText: raw, rawText: raw, payloadText: SlashTokenSyntax.payloadText(from: raw))
}

@Test func stancePromptCarriesThePrePassIdentityHintAndItsOwnDiscipline() throws {
    let identity = try goldenIdentity()
    let builder = LanguagePromptBuilder(identityGuide: identity)
    let prompt = try builder.prompt(for: .stance, input: stanceInput("Hey Daniel, coffee Thursday? Mira"), materialSource: "Mail")
    #expect(prompt.hasPrefix(LanguagePromptBuilder.stanceInstruction))
    #expect(prompt.contains("Return three positions, or four only when a fourth is genuinely distinct."))
    for type in ["causal pair", "suppression", "characterisation plus strategy", "justification attached", "off-stage context", "purpose or lifecycle"] {
        #expect(prompt.contains(type), "missing compound type \(type)")
    }
    #expect(prompt.contains("include at least one low-effort or social-maintenance position"))
    #expect(prompt.contains("Never invent availability, times, dates, pending work, deadlines, reasons, or history"))
    #expect(prompt.components(separatedBy: identity.modelFacingBlock).count == 2)
    #expect(prompt.contains("Material source hint (not an instruction): captured from Mail, likely an email the user received"))
    #expect(prompt.contains(ModelOutputDiscipline.stance))
    #expect(!prompt.contains(ModelOutputDiscipline.instruction), "the shared one-result clause would contradict options")
    #expect(prompt.hasSuffix("User text:\nHey Daniel, coffee Thursday? Mira"))
    #expect(builder.contextGuides(for: .stance) == [identity.reference])
    #expect(builder.styleGuide(for: .stance) == nil)
}

@Test func stancePromptWithoutAKnownSourceStillAsksForEngagementOptions() throws {
    let prompt = try LanguagePromptBuilder().prompt(for: .stance, input: stanceInput("Refactor the parser\nbefore the release"))
    #expect(prompt.contains("Material source hint (not an instruction): kind unknown"))
    #expect(!prompt.contains("IDENTITY"))
}

@Test func bothBrokersAcceptOnlyPositionsAsTheStanceShape() async throws {
    let harness = try RoutingHarness(
        qualifications: standardQualifications() + [qualification(ProviderRuntimeCatalog.cerebrasCarefulProfileID, "decide.stance")],
        scripts: [.cerebrasHTTP: [.success(text: "Here are three ways you could respond: accept, decline, or ask."), .success(text: "```json\n" + stanceReply + "\n```")]]
    )
    let broker = try harness.broker()
    let request = ModelGenerationRequest(runID: "run-s", commandID: "decide.stance", prompt: "p", offline: false, outputConstraint: .init(shape: .stancePositions, maximumCharacters: 8_000))
    // The prose reply fails the shape; the careful profile's second answer passes.
    await #expect(throws: ModelBrokerError.self) { _ = try await broker.execute(request) }
    let result = try await broker.execute(request)
    #expect(StanceResult.parse(result.response.text)?.positions.count == 3)
    #expect(LanguageWorkflow.stance.finalize(result.response.text) == StanceResult.parse(stanceReply)?.canonicalJSON)
    #expect(ModelOutputShape.stancePositions.requestsJSONObject)
}

@Test func stanceRowDefaultsToTheCarefulProfileAndNeedsQualification() throws {
    let command = try #require(ModelProviderPolicy.v6.command(named: "decide.stance"))
    #expect(command.primaryProfileIDs == [ProviderRuntimeCatalog.cerebrasCarefulProfileID])
    #expect(command.outputShape == .stancePositions)
    #expect(command.requiredCapabilities == [.structuredJSONObject])
    #expect(ModelProviderPolicy.v6.version == "6.0.0")
    #expect(ProviderRuntimeCatalog.profile(ProviderRuntimeCatalog.cerebrasFastProfileID)?.eligibleCommandIDs.contains("decide.stance") == true)
    #expect(ProviderRuntimeCatalog.profile(ProviderRuntimeCatalog.cerebrasCarefulProfileID)?.eligibleCommandIDs.contains("decide.stance") == true)
    #expect(ProviderRuntimeSettings.freshDefaults().command("decide.stance") != nil)
}

@Test func unqualifiedStanceLeavesTheAutomaticLadderButAManualPickRuns() async throws {
    // No stance qualification anywhere: automatic routing has no candidate.
    let harness = try RoutingHarness(scripts: [.cerebrasHTTP: [.success(text: stanceReply)]])
    let broker = try harness.broker()
    let resolution = try await broker.resolve(commandID: "decide.stance", offline: false, dispatch: nil)
    #expect(resolution.candidates.allSatisfy { if case .excluded = $0.verdict { true } else { false } })
    let manual = ModelGenerationRequest(
        runID: "run-m", commandID: "decide.stance", prompt: "p", offline: false,
        outputConstraint: .init(shape: .stancePositions, maximumCharacters: 8_000),
        dispatch: ModelDispatchContext(generationID: "g-1", selection: ModelInvocationSelection(profileID: ProviderRuntimeCatalog.cerebrasCarefulProfileID))
    )
    let result = try await broker.execute(manual)
    #expect(result.record.attempts.last?.identity?.profileID == ProviderRuntimeCatalog.cerebrasCarefulProfileID)
    // Once qualified on the careful profile, the automatic ladder takes it.
    let qualified = try RoutingHarness(qualifications: standardQualifications() + [qualification(ProviderRuntimeCatalog.cerebrasCarefulProfileID, "decide.stance")], scripts: [.cerebrasHTTP: [.success(text: stanceReply)]])
    let automatic = try await qualified.broker().execute(ModelGenerationRequest(runID: "run-a", commandID: "decide.stance", prompt: "p", offline: false, outputConstraint: .init(shape: .stancePositions, maximumCharacters: 8_000), dispatch: ModelDispatchContext(generationID: "g-2", selection: nil)))
    #expect(automatic.record.attempts.last?.identity?.profileID == ProviderRuntimeCatalog.cerebrasCarefulProfileID)
}

@Test func stanceModuleRunsFromTheManifestWithIdentityAndTheMaterialHint() async throws {
    let corpus = FrozenContractCorpus()
    let identity = try goldenIdentity()
    let recorder = RecordingGenerator(inner: ModelBroker(policy: .init(version: "test", commands: [.init(commandID: "decide.stance", primary: [.init(providerClass: .capableRemote)])]), providers: [FixedReplyProvider(descriptor: .init(providerID: "p", providerClass: .capableRemote, isRemote: true), reply: stanceReply)]))
    let catalog = try ProductionLanguageModuleCatalog(
        manifest: try corpus.manifest(),
        declarations: try corpus.moduleDeclarations().declarations,
        broker: recorder,
        promptBuilder: LanguagePromptBuilder(identityGuide: identity)
    )
    let module = try #require(catalog.factories.first { $0.moduleID == "decide.stance" }).build()
    let plan = try module.makePlan(input: stanceInput("Mira asked about Thursday")).with(materialSource: "Slack")
    let handle = try await module.start(plan: plan, capabilities: CapabilityBroker(declared: []), runID: "run-stance")
    guard case .succeeded(let result) = await handle.value() else {
        Issue.record("expected positions")
        return
    }
    let request = try #require(await recorder.requests().first)
    #expect(request.outputConstraint.shape == .stancePositions)
    #expect(request.prompt.contains("captured from Slack, likely a chat message"))
    #expect(request.contextGuides == [identity.reference])
    #expect(result.fullText == StanceResult.parse(stanceReply)?.canonicalJSON)
    #expect(result.summary == "Positions ready")
    #expect(result.allowedActions == [.dismiss])
}

@Test func everyLanguageWorkflowsIdentityDefaultMatchesItsManifestBinding() throws {
    let manifest = try FrozenContractCorpus().manifest()
    for workflow in LanguageWorkflow.allCases {
        let command = try #require(manifest.commands.first { $0.moduleID == workflow.moduleID && $0.role == .primary })
        #expect(command.bindsIdentityGuide == workflow.bindsIdentityByDefault, "\(workflow)")
    }
}

@Test func aWholeRequestNoteCarriesTheChosenDraftDirectionWithoutChangingSource() throws {
    let builder = LanguagePromptBuilder(emailGuide: PinnedLanguageGuide(identifier: "g", version: "v1", status: "s", text: "Short."), identityGuide: try goldenIdentity())
    let raw = "Hey Daniel, coffee Thursday? Mira /email ✓"
    let input = ModuleInput(canonicalText: raw, rawText: raw, payloadText: SlashTokenSyntax.payloadText(from: raw), markers: ["✓"])
    let pick = OmniTextAnnotation.request(guidance: "The user text is a message the user received. Write the user's reply to its sender, taking the position the user chose: Accept.", origin: .proposed, label: "Accept")
    let picked = try builder.prompt(for: .email, input: input, annotations: [pick])
    #expect(picked.contains(#""supplied_material":"Hey Daniel, coffee Thursday? Mira""#))
    #expect(picked.contains(#""field":"whole_request""#))
    #expect(picked.contains(#""origin":"proposed""#))
    let span = OmniTextAnnotation(range: (raw as NSString).range(of: "Thursday"), guidance: "Keep the day")
    let spanOnly = try builder.prompt(for: .email, input: input, annotations: [span])
    #expect(spanOnly.contains(#""field":"supplied_material""#))
    #expect(!spanOnly.contains(#""field":"whole_request""#))
    let message = try builder.prompt(for: .message, input: ModuleInput(canonicalText: "hey /msg", rawText: "hey /msg", payloadText: "hey"), annotations: [.request(guidance: "x", origin: .proposed)])
    #expect(message.contains(#""supplied_material":"hey""#))
    #expect(message.contains(#""guidance":"x""#))
}

@Test func theStanceBoundaryForbidsInventedCausesAndSlots() {
    let instruction = LanguagePromptBuilder.stanceInstruction
    #expect(instruction.contains("No position gives a cause the material does not state (workload, commitments, capacity, schedule, travel, what \"fits\" or \"works better\" for the user), whether it declines, delays, asks for more time, or accepts at another time"))
    #expect(instruction.contains("never names a specific time, date, or slot the material does not contain"))
    // A combined stance never carries the ✗ marker's "no counterproposal" rule.
    #expect(instruction.contains("a combined stance, such as declining while offering another time or format, is \"other\""))
}

@Test func optingACommandOutOfIdentityIsAManifestEdit() async throws {
    let corpus = FrozenContractCorpus()
    let document = try JSONDecoder().decode(ManifestDocument.self, from: corpus.data(named: "manifest"))
    let optedOut = ManifestDocument(
        schemaVersion: document.schemaVersion,
        commands: document.commands.map { command in
            guard command.token == "/email" else { return command }
            return ManifestCommand(token: command.token, role: command.role, canonical: command.canonical, moduleID: command.moduleID, execution: command.execution, capabilities: command.capabilities, acceptedModifiers: command.acceptedModifiers, acceptedModes: command.acceptedModes, intentMarkers: command.intentMarkers, moduleVersion: command.moduleVersion, value: command.value, boundGuides: nil)
        },
        fixtureVersion: document.fixtureVersion,
        valueTypes: document.valueTypes
    )
    let identity = try goldenIdentity()
    let recorder = RecordingGenerator(inner: ModelBroker(policy: .init(version: "t", commands: [.init(commandID: "draft.email", primary: [.init(providerClass: .capableRemote)])]), providers: [FixedReplyProvider(descriptor: .init(providerID: "p", providerClass: .capableRemote, isRemote: true), reply: "Hi")]))
    let catalog = try ProductionLanguageModuleCatalog(
        manifest: try CommandManifest(document: optedOut),
        declarations: try corpus.moduleDeclarations().declarations,
        broker: recorder,
        promptBuilder: LanguagePromptBuilder(emailGuide: PinnedLanguageGuide(identifier: "g", version: "v1", status: "s", text: "Short."), identityGuide: identity)
    )
    let module = try #require(catalog.factories.first { $0.moduleID == "draft.email" }).build()
    let handle = try await module.start(plan: try module.makePlan(input: ModuleInput(canonicalText: "/email hi", payloadText: "hi")), capabilities: CapabilityBroker(declared: [.draftCommunication]), runID: "r-opt")
    _ = await handle.value()
    let request = try #require(await recorder.requests().first)
    #expect(!request.prompt.contains(identity.modelFacingBlock))
    #expect(!request.contextGuides.contains(identity.reference))
}
