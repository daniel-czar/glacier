import Foundation
import OmniCore
import OmniModels
import Testing

private enum StubProviderError: Error { case failed }

private struct StubProvider: ModelProvider {
    enum Behavior: Sendable { case success(String); case failure; case wait }

    let descriptor: ModelProviderDescriptor
    let behavior: Behavior

    func generate(_ request: ModelGenerationRequest) async throws -> ModelProviderResponse {
        switch behavior {
        case .success(let text): return ModelProviderResponse(text: text, usage: ModelUsage(inputTokens: 3, outputTokens: 5))
        case .failure: throw StubProviderError.failed
        case .wait:
            try await Task.sleep(for: .seconds(10))
            return ModelProviderResponse(text: "late")
        }
    }
}

private actor CapturingTransport: ModelHTTPTransport {
    private var requests: [URLRequest] = []
    private let response: ModelHTTPResponse

    init(response: ModelHTTPResponse) { self.response = response }

    func send(_ request: URLRequest) async throws -> ModelHTTPResponse {
        requests.append(request)
        return response
    }

    func recordedRequests() -> [URLRequest] { requests }
}

private actor CallCountingProvider: ModelProvider {
    nonisolated let descriptor: ModelProviderDescriptor
    private var calls = 0

    init(descriptor: ModelProviderDescriptor) { self.descriptor = descriptor }

    func generate(_ request: ModelGenerationRequest) async throws -> ModelProviderResponse {
        calls += 1
        return ModelProviderResponse(text: "unexpected provider call")
    }

    func callCount() -> Int { calls }
}

/// Scripted newline-JSON transport for the policy 6.0.0 `CodexAppServerDriver`.
/// Inbound messages are replayed in order; after they are exhausted the
/// transport either closes or parks until the caller's deadline/cancellation.
/// Shared with `ProviderRuntimeTests.swift`.
actor ScriptedCodexTransport: CodexAppServerTransport {
    private var inbound: [Data]
    private var outbound: [Data] = []
    private let waitAfterInbound: Bool
    private let holdShutdown: Bool
    private var shutdownCount = 0

    init(inbound: [Data], waitAfterInbound: Bool = false, holdShutdown: Bool = false) {
        self.inbound = inbound
        self.waitAfterInbound = waitAfterInbound
        self.holdShutdown = holdShutdown
    }

    func send(_ message: Data) async throws { outbound.append(message) }

    func receive(until deadline: ContinuousClock.Instant) async throws -> Data {
        if !inbound.isEmpty { return inbound.removeFirst() }
        guard waitAfterInbound else { throw CodexAppServerProviderError.transportClosed }
        try await Task.sleep(until: deadline, clock: .continuous)
        throw CodexAppServerProviderError.deadlineExceeded
    }

    func shutdown() async {
        shutdownCount += 1
        if holdShutdown { try? await Task.sleep(for: .seconds(10)) }
    }
    func messages() -> [Data] { outbound }
    func shutdowns() -> Int { shutdownCount }
}

func codexJSON(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

func codexResult(_ id: Int, _ result: [String: Any]) throws -> Data {
    try codexJSON(["id": id, "result": result])
}

func codexEvent(_ method: String, _ params: [String: Any]) throws -> Data {
    try codexJSON(["method": method, "params": params])
}

func decodeCodexMessage(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func historicalDraftEligibilityRemainsStableForFrozenOneOneZero() {
    let eligibility = HistoricalModelEligibility.fromFrozenDeclaration(profile: "draft")
    #expect(eligibility?.declarationFixtureVersion == "1.1.0")
    #expect(eligibility?.providerClasses == [.capableRemote, .localCapable])
    #expect(ModelRuntimePolicy.phase4V1.command(named: "draft.message")?.primary.first?.providerClass == .localCapable)
}

@Test func phaseFiveCandidateMatrixIsInertAndDoesNotClaimLocalSuitability() {
    let candidates = Phase5ModelProviderMatrix.candidates
    #expect(candidates.map(\.providerID) == [
        "cerebras:gemma-4-31b:none",
        "codex-app-server:chatgpt",
        "ollama:qwen3:8b:local-fast",
        "ollama:qwen3:8b:local-capable",
    ])
    #expect(candidates.allSatisfy { !$0.isAvailable })
    #expect(Phase5ModelProviderMatrix.cerebrasGemmaFast.availabilityReasons.contains(.explicitFiniteAuthorizationRequired))
    #expect(Phase5ModelProviderMatrix.chatGPTCodex.modelID == nil)
    #expect(Phase5ModelProviderMatrix.observedQwenLocalCapable.availabilityReasons.contains(.localSuitabilityUnproven))
}

@Test func phaseFiveOfflineRouteNeverCallsRemoteCandidate() async throws {
    let remote = CallCountingProvider(descriptor: .init(
        providerID: Phase5ModelProviderMatrix.cerebrasGemmaFast.providerID,
        providerClass: .fastHosted,
        isRemote: true,
        qualityValidatedCommandIDs: ["translate"]
    ))
    let local = CallCountingProvider(descriptor: .init(
        providerID: "local-unqualified",
        providerClass: .localFast,
        isRemote: false
    ))
    do {
        _ = try await ModelBroker(policy: .phase5V1, providers: [remote, local]).execute(
            .init(runID: "offline-translate", commandID: "translate", prompt: "hello", offline: true)
        )
        Issue.record("expected unqualified offline provider to remain unavailable")
    } catch let error as ModelBrokerError {
        guard case .unavailable(let record) = error else {
            Issue.record("expected unavailable record")
            return
        }
        #expect(record.attempts.map(\.providerID) == ["local-unqualified"])
        #expect(record.attempts.first?.detail == "command quality evidence unavailable")
    }
    #expect(await remote.callCount() == 0)
    #expect(await local.callCount() == 0)
}

@Test func phaseFiveMechanicalCommandsHaveNoModelRouteOrProviderCall() async {
    let provider = CallCountingProvider(descriptor: .init(
        providerID: "unexpected-fast",
        providerClass: .fastHosted,
        isRemote: true,
        qualityValidatedCommandIDs: ["answer.quick"]
    ))
    await #expect(throws: ModelBrokerError.missingPolicy(commandID: "open.search")) {
        _ = try await ModelBroker(policy: .phase5V1, providers: [provider]).execute(
            .init(runID: "mechanical", commandID: "open.search", prompt: "ignored", offline: false)
        )
    }
    #expect(await provider.callCount() == 0)
}

@Test func phaseFiveSettingsRequireQualityEvidenceForBothRemoteLanes() throws {
    let unqualified = StubProvider(
        descriptor: .init(providerID: "chatgpt", providerClass: .capableRemote, isRemote: true),
        behavior: .success("draft")
    )
    let settings = ModelSettings(
        runtimePolicyVersion: ModelRuntimePolicy.phase5V1.version,
        configurationID: "phase5-test",
        commandSettings: [.init(commandID: "draft.email", mainProviderClass: .capableRemote)]
    )
    #expect(throws: ModelBrokerError.self) {
        try ModelBroker(policy: .phase5V1, providers: [unqualified]).validateSettings(settings)
    }
    let qualified = StubProvider(
        descriptor: .init(providerID: "chatgpt", providerClass: .capableRemote, isRemote: true, qualityValidatedCommandIDs: ["draft.email"]),
        behavior: .success("draft")
    )
    do {
        try ModelBroker(policy: .phase5V1, providers: [qualified]).validateSettings(settings)
    } catch {
        Issue.record("expected qualified capable lane to save: \(error)")
    }
}

@Test func brokerRecordsFailureThenFallbackSuccess() async throws {
    let broken = StubProvider(
        descriptor: .init(providerID: "local-primary", providerClass: .localFast, isRemote: false),
        behavior: .failure
    )
    let working = StubProvider(
        descriptor: .init(providerID: "hosted-qualified", providerClass: .fastHosted, isRemote: true, qualityValidatedCommandIDs: ["answer.quick"]),
        behavior: .success("answer")
    )
    let policy = ModelRuntimePolicy(version: "test", commands: [
        .init(commandID: "answer.quick", primary: [.init(providerClass: .localFast)], fallback: [.init(providerClass: .fastHosted, requiresQualityEvidence: true)]),
    ])
    let result = try await ModelBroker(policy: policy, providers: [broken, working]).execute(
        .init(runID: "run-1", commandID: "answer.quick", prompt: "What?", offline: false)
    )
    #expect(result.response.text == "answer")
    #expect(result.record.runtimePolicyVersion == "test")
    #expect(result.record.attempts.map(\.outcome) == [.failed, .succeeded])
    #expect(result.record.attempts.last?.usage?.outputTokens == 5)
}

@Test func offlineNeverCallsRemoteProviderEvenWhenItAppearsInTheLadder() async throws {
    let remote = StubProvider(
        descriptor: .init(providerID: "remote", providerClass: .capableRemote, isRemote: true),
        behavior: .success("remote answer")
    )
    let local = StubProvider(
        descriptor: .init(providerID: "local", providerClass: .localCapable, isRemote: false),
        behavior: .success("local answer")
    )
    let policy = ModelRuntimePolicy(version: "offline-test", commands: [
        .init(commandID: "draft.email", primary: [], offline: [.init(providerClass: .capableRemote), .init(providerClass: .localCapable)]),
    ])
    let result = try await ModelBroker(policy: policy, providers: [remote, local]).execute(
        .init(runID: "run-2", commandID: "draft.email", prompt: "Draft", offline: true)
    )
    #expect(result.response.text == "local answer")
    #expect(result.record.attempts.map(\.outcome) == [.unavailable, .succeeded])
    #expect(result.record.attempts.first?.detail == "offline excludes remote providers")
}

@Test func explicitSettingsReorderOnlyQualifiedCommandLaddersAndPinTheirIdentity() async throws {
    let local = StubProvider(
        descriptor: .init(providerID: "local", providerClass: .localFast, isRemote: false),
        behavior: .success("local")
    )
    let fast = StubProvider(
        descriptor: .init(providerID: "fast", providerClass: .fastHosted, isRemote: true, qualityValidatedCommandIDs: ["answer.quick"]),
        behavior: .success("fast")
    )
    let broker = ModelBroker(providers: [local, fast])
    let settings = ModelSettings(
        runtimePolicyVersion: ModelRuntimePolicy.phase4V1.version,
        configurationID: "saved-test",
        configurationVersion: 7,
        commandSettings: [.init(commandID: "answer.quick", mainProviderClass: .fastHosted, fallbackProviderClasses: [.localFast])]
    )
    let updated = try broker.applySettings(settings)
    let result = try await updated.execute(.init(runID: "settings-run", commandID: "answer.quick", prompt: "q", offline: false))
    #expect(result.response.text == "fast")
    #expect(result.record.settingsConfigurationID == "saved-test")
    #expect(result.record.settingsConfigurationVersion == 7)
    #expect(throws: ModelBrokerError.self) {
        try broker.validateSettings(.init(runtimePolicyVersion: ModelRuntimePolicy.phase4V1.version, commandSettings: [.init(commandID: "open.search", mainProviderClass: .fastHosted)]))
    }
}

@Test func malformedTranslationOutputFallsBackAndRecordsTheRejectedAttempt() async throws {
    let malformed = StubProvider(
        descriptor: .init(providerID: "a-malformed", providerClass: .localFast, isRemote: false),
        behavior: .success("Here is a translation: hello")
    )
    let good = StubProvider(
        descriptor: .init(providerID: "b-good", providerClass: .localFast, isRemote: false),
        behavior: .success("1. hallo")
    )
    let result = try await ModelBroker(providers: [malformed, good]).execute(
        .init(runID: "translation-run", commandID: "translate", prompt: "hello", offline: false, outputConstraint: .init(shape: .numberedTranslations, maximumCharacters: 100))
    )
    #expect(result.response.text == "1. hallo")
    #expect(result.record.attempts.map(\.outcome) == [.failed, .succeeded])
}

@Test func brokerCancellationReturnsAttemptRecord() async {
    let slow = StubProvider(
        descriptor: .init(providerID: "slow-local", providerClass: .localFast, isRemote: false),
        behavior: .wait
    )
    let broker = ModelBroker(policy: .init(version: "cancel-test", commands: [
        .init(commandID: "answer.quick", primary: [.init(providerClass: .localFast)]),
    ]), providers: [slow])
    let task = Task<Result<ModelBrokerResult, ModelBrokerError>, Never> {
        do {
            return .success(try await broker.execute(.init(runID: "run-3", commandID: "answer.quick", prompt: "wait", offline: false)))
        } catch let error as ModelBrokerError {
            return .failure(error)
        } catch {
            Issue.record("unexpected error: \(error)")
            return .failure(.missingPolicy(commandID: "unexpected"))
        }
    }
    try? await Task.sleep(for: .milliseconds(10))
    task.cancel()
    let result = await task.value
    guard case .failure(.cancelled(let record)) = result else {
        Issue.record("expected cancellation record")
        return
    }
    #expect(record.attempts.last?.outcome == .cancelled)
}

@Test func ollamaProviderUsesOnlyInjectedTransportAndLocalEndpoint() async throws {
    let transport = CapturingTransport(response: .init(
        statusCode: 200,
        body: Data("{\"response\":\"Bonjour\",\"prompt_eval_count\":2,\"eval_count\":1}".utf8)
    ))
    let configuration = try ModelProviderConfiguration(
        descriptor: .init(providerID: "ollama", providerClass: .localFast, isRemote: false),
        endpoint: try #require(URL(string: "http://127.0.0.1:11434")),
        model: "local-test"
    )
    let provider = try OllamaModelProvider(configuration: configuration, transport: transport)
    let response = try await provider.generate(.init(runID: "run-4", commandID: "translate", prompt: "Hello", offline: true))
    #expect(response.text == "Bonjour")
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.path == "/api/generate")
    let requestBody = try #require(request.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
    #expect(body["model"] as? String == "local-test")
    #expect(body["stream"] as? Bool == false)
    #expect(body["think"] as? Bool == false)
    #expect((body["options"] as? [String: Any])?["num_predict"] as? Int == 2048)
    #expect(body["format"] == nil)
}

@Test func ollamaProviderRequestsNativeJSONOnlyForJSONObjectConstraints() async throws {
    let transport = CapturingTransport(response: .init(
        statusCode: 200,
        body: Data("{\"response\":\"{\\\"alternatives\\\":[]}\"}".utf8)
    ))
    let configuration = try ModelProviderConfiguration(
        descriptor: .init(providerID: "ollama-json", providerClass: .localCapable, isRemote: false),
        endpoint: try #require(URL(string: "http://127.0.0.1:11434")),
        model: "local-test"
    )
    let provider = try OllamaModelProvider(configuration: configuration, transport: transport)
    _ = try await provider.generate(.init(
        runID: "run-json",
        commandID: "tier2.proposal",
        prompt: "proposal",
        offline: true,
        outputConstraint: .init(shape: .jsonObject, maximumCharacters: 12_000)
    ))
    let request = try #require(await transport.recordedRequests().first)
    let requestBody = try #require(request.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
    #expect(body["format"] as? String == "json")
}

@Test func languageCatalogBuildsOnlyFrozenModelModulesAndReturnsFullText() async throws {
    let corpus = FrozenContractCorpus()
    let manifest = try corpus.manifest()
    let declarations = try corpus.moduleDeclarations().declarations
    let provider = StubProvider(
        descriptor: .init(providerID: "email-provider", providerClass: .capableRemote, isRemote: true),
        behavior: .success("Hi Zoe,\n\nThe proposal is ready.\n\nBest,\nDaniel")
    )
    let guide = PinnedLanguageGuide(
        identifier: "c957680b82013064",
        version: "v1",
        status: "adopted-current",
        text: "Make the situation legible, say what matters, and stop."
    )
    let catalog = try ProductionLanguageModuleCatalog(
        manifest: manifest,
        declarations: declarations,
        broker: ModelBroker(providers: [provider]),
        promptBuilder: LanguagePromptBuilder(emailGuide: guide)
    )
    #expect(Set(catalog.factories.map(\.moduleID)) == Set(LanguageWorkflow.allCases.map(\.moduleID)))
    let factory = try #require(catalog.factories.first { $0.moduleID == "draft.email" })
    let module = factory.build()
    let input = ModuleInput(canonicalText: "/email update", payloadText: "Send Zoe the proposal update", modifiers: ["/style:formal"])
    let plan = try module.makePlan(input: input)
    let handle = try await module.start(plan: plan, capabilities: CapabilityBroker(declared: [.draftCommunication]), runID: "run-5")
    guard case .succeeded(let result) = await handle.value() else {
        Issue.record("expected model result")
        return
    }
    #expect(result.fullText?.contains("The proposal is ready") == true)
    #expect(result.modelRecord?.attempts.last?.outcome == .succeeded)
    #expect(result.modelRecord?.styleGuide?.identifier == "c957680b82013064")
    #expect(result.allowedActions.contains(.openComposer))
}

@Test func languagePromptTreatsAdoptedGuidesAsStyleOnlyAndMakesMarkersDirect() throws {
    let guide = PinnedLanguageGuide(
        identifier: "email-guide",
        version: "v1",
        status: "adopted-current",
        text: "Example: ask Alex whether 14 or 21 October works before Wednesday."
    )
    let shared = PinnedLanguageGuide(
        identifier: "shared-guide",
        version: "v1",
        status: "adopted-current",
        text: "Example: I hope your final submission is going well."
    )
    let input = ModuleInput(
        canonicalText: "/email /style:formal ✓ confirm the meeting time",
        payloadText: "Confirm the meeting time works for Alex.",
        modifiers: ["/style:formal"],
        markers: ["✓"]
    )
    let prompt = try LanguagePromptBuilder(emailGuide: guide, sharedGuide: shared).prompt(for: .email, input: input)
    #expect(prompt.contains("STYLE-ONLY"))
    #expect(prompt.contains("Every example, name, date, role, task, deadline, obligation, or sign-off in them is non-factual"))
    #expect(prompt.contains("Do not add generic well-wishing, implied deadlines, obligations, or purpose"))
    #expect(prompt.contains("State the acceptance directly; never turn it into a question"))
    #expect(prompt.contains("Only these supply situational facts"))
    #expect(prompt.contains("\"user_request\":\"confirm the meeting time\""))
}

@Test func translateLangcodeSelectsTheTargetLanguageAndOmittedValueUsesEnglish() throws {
    let targeted = ModuleInput(
        canonicalText: "/translate:de hello",
        payloadText: "hello",
        tokenValues: ["/translate": .langcode("de")]
    )
    let targetedPrompt = try LanguagePromptBuilder().prompt(for: .translation, input: targeted)
    #expect(targetedPrompt.contains("Translate into German (de)."))
    let defaulted = ModuleInput(canonicalText: "/translate hello", payloadText: "hello")
    let defaultPrompt = try LanguagePromptBuilder().prompt(for: .translation, input: defaulted)
    #expect(defaultPrompt.contains("Detect the predominant source language"))
    #expect(defaultPrompt.contains("Translate into English (en)."))
}

@Test func languageCancellationBeforeValuePreventsProviderCallAndExposesCancelledRecord() async throws {
    let corpus = FrozenContractCorpus()
    let provider = CallCountingProvider(descriptor: .init(
        providerID: "counting-email",
        providerClass: .capableRemote,
        isRemote: true
    ))
    let guide = PinnedLanguageGuide(
        identifier: "c957680b82013064",
        version: "v1",
        status: "adopted-current",
        text: "Make the situation legible, say what matters, and stop."
    )
    let catalog = try ProductionLanguageModuleCatalog(
        manifest: corpus.manifest(),
        declarations: corpus.moduleDeclarations().declarations,
        broker: ModelBroker(providers: [provider]),
        promptBuilder: LanguagePromptBuilder(emailGuide: guide)
    )
    let factory = try #require(catalog.factories.first { $0.moduleID == "draft.email" })
    let module = factory.build()
    let plan = try module.makePlan(input: ModuleInput(canonicalText: "/email cancel", payloadText: "Cancel before generation"))
    let handle = try await module.start(
        plan: plan,
        capabilities: CapabilityBroker(declared: [.draftCommunication]),
        runID: "cancel-before-value"
    )
    let acknowledgement = await handle.requestCancellation()
    #expect(acknowledgement.requestObserved)
    #expect(await provider.callCount() == 0)
    #expect(await handle.value() == .interrupted(effectCertainty: .certain))
    #expect(await provider.callCount() == 0)
    let record = try #require(await handle.modelExecutionRecord())
    #expect(record.runID == "cancel-before-value")
    #expect(record.attempts.isEmpty)
    #expect(record.runtimePolicyVersion == ModelRuntimePolicy.phase4V1.version)
}

@Test func proposalInferenceReturnsRawJSONWithoutToolSurface() async throws {
    let raw = "{\"alternatives\":[{\"id\":\"capture-todo\",\"title\":\"Capture task\",\"commands\":[\"/todo buy milk\"]}]}"
    let provider = StubProvider(
        descriptor: .init(providerID: "proposal", providerClass: .capableRemote, isRemote: true),
        behavior: .success(raw)
    )
    let result = try await ConstrainedProposalInference(broker: ModelBroker(providers: [provider]))
        .proposeRawJSON(runID: "run-6", prompt: "bounded synthetic proposal context", offline: false)
    #expect(result.response.text == raw)
    #expect(result.record.commandID == "tier2.proposal")
}

@Test func proposalInferenceRejectsNonObjectJSONBeforeIndependentPlanValidation() async throws {
    let provider = StubProvider(
        descriptor: .init(providerID: "proposal-array", providerClass: .capableRemote, isRemote: true),
        behavior: .success("[]")
    )
    do {
        _ = try await ConstrainedProposalInference(broker: ModelBroker(policy: .init(version: "proposal-shape-test", commands: [
            .init(commandID: "tier2.proposal", primary: [.init(providerClass: .capableRemote)])
        ]), providers: [provider]))
            .proposeRawJSON(runID: "run-array", prompt: "bounded synthetic proposal context", offline: false)
        Issue.record("expected the broker to reject a non-object JSON response")
    } catch let error as ModelBrokerError {
        guard case .failed(let record) = error else {
            Issue.record("expected a shape-validation failure")
            return
        }
        #expect(record.attempts.last?.detail == "invalid response shape")
    }
}
