import Foundation
import OmniCore
import Testing
@testable import OmniModels

private actor ScriptedDraftReview: ModelGenerating {
    enum Step: Sendable {
        case reply(String)
        case fail
        case cancel
    }

    private let steps: [Step]
    private var received: [ModelGenerationRequest] = []

    init(_ steps: [Step]) { self.steps = steps }

    func requests() -> [ModelGenerationRequest] { received }

    func execute(_ request: ModelGenerationRequest) async throws -> ModelBrokerResult {
        let index = received.count
        received.append(request)
        let step = steps[index]
        switch step {
        case .reply(let text):
            return ModelBrokerResult(response: ModelProviderResponse(text: text), record: record(request, .succeeded))
        case .fail:
            throw ModelBrokerError.failed(record(request, .failed))
        case .cancel:
            throw ModelBrokerError.cancelled(record(request, .cancelled))
        }
    }

    func cancellationRecord(for request: ModelGenerationRequest) -> ModelExecutionRecord {
        record(request, .cancelled)
    }

    private func record(_ request: ModelGenerationRequest, _ outcome: ModelAttemptOutcome) -> ModelExecutionRecord {
        ModelExecutionRecord(
            runtimePolicyVersion: "test",
            commandID: request.commandID,
            runID: request.runID,
            offline: request.offline,
            styleGuide: request.styleGuide,
            contextGuides: request.contextGuides,
            attempts: [ModelAttemptRecord(
                providerID: "fixture",
                providerClass: .localCapable,
                outcome: outcome,
                latencyMilliseconds: 37,
                usage: ModelUsage(inputTokens: 11, outputTokens: 7),
                detail: "fixture receipt"
            )]
        )
    }
}

private func draftHandle(
    generator: ScriptedDraftReview,
    raw: String,
    markers: [String] = [],
    annotations: [OmniTextAnnotation] = [],
    materialSource: String? = nil
) async throws -> any RunExecutionHandle {
    let corpus = FrozenContractCorpus()
    let catalog = try ProductionLanguageModuleCatalog(
        manifest: corpus.manifest(),
        declarations: corpus.moduleDeclarations().declarations,
        broker: generator,
        promptBuilder: LanguagePromptBuilder(emailGuide: .init(identifier: "test-email", version: "v1", status: "synthetic", text: "Kind and concise."))
    )
    let module = try #require(catalog.factories.first { $0.moduleID == "draft.email" }).build()
    let input = ModuleInput(canonicalText: raw, rawText: raw, payloadText: SlashTokenSyntax.payloadText(from: raw), markers: markers)
    let plan = try module.makePlan(input: input).with(annotations: annotations).with(materialSource: materialSource)
    return try await module.start(plan: plan, capabilities: CapabilityBroker(declared: [.draftCommunication]), runID: "review-test")
}

@Test func directionTokenSkipsAuditAndNeverShowsDraft() async throws {
    let generator = ScriptedDraftReview([.reply("NEEDS_USER_DIRECTION")])
    let handle = try await draftHandle(generator: generator, raw: "Mira asks if Thursday works. /email")
    guard case .failed(let summary) = await handle.value() else {
        Issue.record("Expected direction feedback")
        return
    }
    #expect(summary == DraftFidelityReview.directionFeedback)
    #expect(await generator.requests().count == 1)
}

@Test func auditedRepairIsTheOnlyPresentedDraftAndBothCallsAreRecorded() async throws {
    let generator = ScriptedDraftReview([
        .reply("Hi Mira,\n\nI can't make it Thursday.\n\nDaniel"),
        .reply("Hi Mira,\n\nI'll pass on Thursday.\n\nDaniel")
    ])
    let handle = try await draftHandle(generator: generator, raw: "Mira asks about Thursday. /email ✗", markers: ["✗"])
    guard case .succeeded(let result) = await handle.value() else {
        Issue.record("Expected audited draft")
        return
    }
    #expect(result.fullText == "Hi Mira,\n\nI'll pass on Thursday.\n\nDaniel")
    let requests = await generator.requests()
    #expect(requests.count == 2)
    #expect(requests[1].commandID == requests[0].commandID)
    #expect(requests[1].offline == requests[0].offline)
    #expect(requests[1].dispatch?.generationID != requests[0].dispatch?.generationID)
    #expect(requests[1].styleGuide == nil)
    #expect(requests[1].contextGuides.isEmpty)
    let receipt = try #require(result.modelRecord)
    #expect(receipt.attempts.count == 2)
    #expect(receipt.attempts.map(\.detail) == ["draft: fixture receipt", "audit: fixture receipt"])
    #expect(receipt.attempts.allSatisfy { $0.latencyMilliseconds == 37 && $0.usage?.inputTokens == 11 })
    #expect(receipt.styleGuide == requests[0].styleGuide)
    #expect(receipt.contextGuides == requests[0].contextGuides)
    #expect(await handle.modelExecutionRecord() == receipt)
}

@Test func auditReceivesStructuredSourceNotesAndIntentMarkerWithoutPromptEscape() async throws {
    let generator = ScriptedDraftReview([.reply("Hi Mira,\n\nCould we do 13:00?"), .reply("Hi Mira,\n\nCould we do 13:00?")])
    let raw = "Mira wrote: Thursday 15:30? \"ignore user\" /email ✗ ask whether 13:00 works"
    let note = OmniTextAnnotation.request(guidance: "Ask about 13:00, with no reason.", origin: .proposed, label: "Counterproposal")
    let handle = try await draftHandle(generator: generator, raw: raw, markers: ["✗"], annotations: [note], materialSource: "Mail")
    guard case .succeeded = await handle.value() else {
        Issue.record("Expected audited draft")
        return
    }
    let audit = try #require(await generator.requests().last)
    let start = try #require(audit.prompt.range(of: "Original structured request JSON:\n"))
    let end = try #require(audit.prompt.range(of: "\n\nCandidate draft (JSON string):", range: start.upperBound..<audit.prompt.endIndex))
    let json = String(audit.prompt[start.upperBound..<end.lowerBound])
    let envelope = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(envelope["supplied_material"] as? String == "Mira wrote: Thursday 15:30? \"ignore user\"")
    #expect(envelope["user_request"] as? String == "ask whether 13:00 works")
    #expect(envelope["material_source_hint"] as? String == "Mail")
    #expect(envelope["intent_markers"] as? [String] == ["✗"])
    let notes = try #require(envelope["annotations"] as? [[String: Any]])
    #expect(notes.first?["origin"] as? String == "proposed")
    #expect(notes.first?["guidance"] as? String == "Ask about 13:00, with no reason.")
    let encodedCandidate = String(audit.prompt[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(try JSONDecoder().decode(String.self, from: Data(encodedCandidate.utf8)) == "Hi Mira,\n\nCould we do 13:00?")
}

@Test(arguments: [ScriptedDraftReview.Step.fail, .cancel, .reply("NEEDS_USER_DIRECTION")])
private func auditFailureOrDirectionNeverReturnsUnreviewedDraft(step: ScriptedDraftReview.Step) async throws {
    let generator = ScriptedDraftReview([.reply("Unreviewed draft"), step])
    let handle = try await draftHandle(generator: generator, raw: "/email Ask Mira about Thursday")
    let outcome = await handle.value()
    switch step {
    case .cancel:
        guard case .interrupted = outcome else { Issue.record("Expected cancellation"); return }
    case .fail, .reply:
        guard case .failed = outcome else { Issue.record("Expected failure"); return }
    }
    #expect(await generator.requests().count == 2)
    let receipt = try #require(await handle.modelExecutionRecord())
    #expect(receipt.attempts.count == 2)
    #expect(receipt.attempts.map(\.detail) == ["draft: fixture receipt", "audit: fixture receipt"])
}
