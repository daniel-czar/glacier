import Foundation
import OmniCore
import OmniModels
import Testing

private actor H13UnreachableTransport: ModelHTTPExchangeTransport {
    private(set) var requests: [URLRequest] = []

    func exchange(_ request: URLRequest) async throws -> ModelHTTPExchange {
        requests.append(request)
        throw URLError(.cannotConnectToHost)
    }

    var requestCount: Int { requests.count }
    var firstRequest: URLRequest? { requests.first }
}

private actor H13ProbeState {
    var probes = 0
    var generations = 0
    func didProbe() { probes += 1 }
    func didGenerate() { generations += 1 }
}

private struct H13LoginProbeDriver: ModelProviderDriver {
    let driverID: ModelDriverID = .codexAppServer
    let capabilities: Set<ModelCapability> = [.plainText, .structuredJSONObject, .reasoningLevel]
    let state: H13ProbeState
    var probeDelay: Duration = .zero

    func configurationIssue(for connection: ModelConnectionProfile) -> ModelFailureKind? { nil }
    func probe(connection: ModelConnectionProfile) async -> ModelConnectionProbe {
        await state.didProbe()
        if probeDelay > .zero { try? await Task.sleep(for: probeDelay) }
        return ModelConnectionProbe(availability: .needsLogin, detail: "test login absent")
    }
    func generate(_ request: ModelDriverRequest) async throws -> ModelDriverResponse {
        await state.didGenerate()
        throw ModelDriverFailure(.needsLogin)
    }
}

private struct H13MissingCredentialProbeDriver: ModelProviderDriver {
    let driverID: ModelDriverID = .cerebrasHTTP
    let capabilities: Set<ModelCapability> = Set(ModelCapability.allCases)
    let state: H13ProbeState

    func configurationIssue(for connection: ModelConnectionProfile) -> ModelFailureKind? { nil }
    func probe(connection: ModelConnectionProfile) async -> ModelConnectionProbe {
        await state.didProbe()
        return ModelConnectionProbe(availability: .needsConfiguration, detail: "credential not found")
    }
    func generate(_ request: ModelDriverRequest) async throws -> ModelDriverResponse {
        await state.didGenerate()
        throw ModelDriverFailure(.authRequired)
    }
}

private actor H13IsolationGate {
    private var began = false
    private var beganWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitForStart() async {
        if began { return }
        await withCheckedContinuation { beganWaiter = $0 }
    }

    func failAfterRelease() async throws -> ModelDriverResponse {
        began = true
        beganWaiter?.resume()
        beganWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
        throw ModelDriverFailure(.isolationViolation, detail: "old settings isolation failure")
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private struct H13DelayedIsolationDriver: ModelProviderDriver {
    let driverID: ModelDriverID = .claudePrint
    let capabilities: Set<ModelCapability> = [.plainText, .structuredJSONObject, .reasoningLevel]
    let gate: H13IsolationGate

    func configurationIssue(for connection: ModelConnectionProfile) -> ModelFailureKind? { nil }
    func probe(connection: ModelConnectionProfile) async -> ModelConnectionProbe { .init(availability: .ready) }
    func generate(_ request: ModelDriverRequest) async throws -> ModelDriverResponse {
        try await gate.failAfterRelease()
    }
}

@Test func manualSelectionBypassesOnlyQualificationAndEligibility() async throws {
    let harness = try RoutingHarness(qualifications: [], scripts: [.cerebrasHTTP: [.success(text: "manual answer")]])
    let broker = try harness.broker()
    let selection = ModelInvocationSelection(profileID: ProviderRuntimeCatalog.cerebrasFastProfileID)
    let manual = try broker.resolve(commandID: "tier2.proposal", offline: false,
                                    dispatch: ModelDispatchContext(generationID: "manual-tier2", selection: selection))
    #expect(manual.effectiveProfileID == ProviderRuntimeCatalog.cerebrasFastProfileID)
    #expect(manual.candidates.first?.qualificationEvidence == nil)
    let automatic = try broker.resolve(commandID: "tier2.proposal", offline: false, dispatch: nil)
    #expect(automatic.effectiveProfileID == nil)
    #expect(automatic.candidates.allSatisfy { !$0.isEligible })

    let result = try await broker.execute(generationRequest("answer.quick", selection: selection))
    #expect(result.response.text == "manual answer")
    #expect(result.record.route?.selectionSource == .invocationOverride(generationID: result.record.route?.generationID ?? ""))
    #expect(result.record.attempts.last?.identity?.qualificationEvidence == nil)
}

@Test func unqualifiedSavedFallbackRunsAfterPrimaryFailure() async throws {
    let selected = ProviderRuntimeCatalog.chatGPTCapableProfileID
    let fallback = ProviderRuntimeCatalog.cerebrasFastProfileID
    let settings = settingsDocument(revision: 4, commands: [
        .init(commandID: "draft.email", savedProfileID: selected, savedFallbackProfileIDs: [fallback])
    ])
    let harness = try RoutingHarness(qualifications: [], scripts: [
        .codexAppServer: [.failure(ModelDriverFailure(.providerFailure, detail: "synthetic primary failure"))],
        .cerebrasHTTP: [.success(text: "saved fallback answer")],
    ])
    let broker = try harness.broker(settings: settings)
    let route = try broker.resolve(commandID: "draft.email", offline: false, dispatch: nil)
    #expect(route.candidates[0].isEligible)
    #expect(route.candidates[1].isEligible)
    #expect(route.candidates.allSatisfy { $0.qualificationEvidence == nil })
    let result = try await broker.execute(generationRequest("draft.email"))
    #expect(result.response.text == "saved fallback answer")
    #expect(result.record.route?.selectionSource == .savedCommandOptIn(settingsRevision: 4))
    #expect(result.record.attempts.map(\.outcome) == [.failed, .succeeded])
    #expect(result.record.attempts.last?.identity?.profileID == fallback)
    #expect(result.record.attempts.last?.identity?.qualificationEvidence == nil)
}

@Test func authPreflightBlocksManualPickAndAllowsQualifiedSavedFallback() async throws {
    let state = H13ProbeState()
    let login = H13LoginProbeDriver(state: state)
    let selected = ProviderRuntimeCatalog.chatGPTCapableProfileID
    let fallback = ProviderRuntimeCatalog.cerebrasFastProfileID
    let harness = try RoutingHarness(qualifications: [],
                                     scripts: [.cerebrasHTTP: [.success(text: "fallback answer")]],
                                     replacing: [login])
    let broker = try harness.broker()
    let store = ProviderRuntimeBrokerStore(broker: broker)
    let dispatch = ModelDispatchContext(generationID: "login-preflight", selection: .init(profileID: selected))
    let ready = try await store.resolveReadiness(commandID: "draft.email", offline: false, dispatch: dispatch)
    #expect(exclusionKind(ready.candidates.first) == .needsLogin)
    #expect(ready.candidates.first?.unavailabilityReason == "ChatGPT: not logged in")
    let blocked = await brokerError { try await store.execute(generationRequest("draft.email", generationID: "login-preflight", selection: .init(profileID: selected))) }
    #expect(blocked?.description == "Model unavailable: ChatGPT: not logged in")
    #expect(await state.generations == 0)
    #expect(await state.probes == 1) // The submit reuses the cached auth probe.

    let settings = settingsDocument(revision: 3, commands: [
        .init(commandID: "draft.email", savedProfileID: selected, savedFallbackProfileIDs: [fallback])
    ])
    try await store.applySettings(settings)
    let result = try await store.execute(generationRequest("draft.email"))
    #expect(result.response.text == "fallback answer")
    #expect(result.record.attempts.first?.identity?.failure == .needsLogin)
    #expect(result.record.attempts.last?.identity?.profileID == fallback)
    #expect(result.record.attempts.last?.identity?.qualificationEvidence == nil)
    #expect(await state.generations == 0)
    #expect(await state.probes == 2) // Settings revision invalidated the probe cache.
}

@Test func implicitOfflineFallbackStillNeedsQualification() throws {
    let saved = ProviderRuntimeCatalog.chatGPTCapableProfileID
    let settings = settingsDocument(revision: 5, commands: [.init(commandID: "answer.quick", savedProfileID: saved)])
    let harness = try RoutingHarness(qualifications: [])
    let route = try harness.broker(settings: settings).resolve(commandID: "answer.quick", offline: true, dispatch: nil)
    #expect(route.selectionSource == .savedCommandOptIn(settingsRevision: 5))
    #expect(route.candidates.first?.profileID == saved)
    #expect(exclusionKind(route.candidates.first) == .offlineExcludesRemote)
    let implicitLocal = route.candidates.first { $0.profileID == ProviderRuntimeCatalog.localFastProfileID }
    #expect(exclusionKind(implicitLocal) == .unqualified)
}

@Test func concurrentManualReadinessSharesOneConnectionProbe() async throws {
    let state = H13ProbeState()
    let login = H13LoginProbeDriver(state: state, probeDelay: .milliseconds(80))
    let harness = try RoutingHarness(qualifications: [], replacing: [login])
    let store = ProviderRuntimeBrokerStore(broker: try harness.broker())
    let dispatch = ModelDispatchContext(generationID: "shared-probe", selection: .init(profileID: ProviderRuntimeCatalog.chatGPTCapableProfileID))
    async let first = store.resolveReadiness(commandID: "draft.email", offline: false, dispatch: dispatch)
    async let second = store.resolveReadiness(commandID: "draft.email", offline: false, dispatch: dispatch)
    let (firstRoute, secondRoute) = try await (first, second)
    #expect(exclusionKind(firstRoute.candidates.first) == .needsLogin)
    #expect(exclusionKind(secondRoute.candidates.first) == .needsLogin)
    #expect(await state.probes == 1)
    #expect(await state.generations == 0)
}

@Test func readinessChecksEveryExplicitSavedCandidate() async throws {
    let loginState = H13ProbeState()
    let credentialState = H13ProbeState()
    let selected = ProviderRuntimeCatalog.chatGPTCapableProfileID
    let fallback = ProviderRuntimeCatalog.cerebrasFastProfileID
    let harness = try RoutingHarness(qualifications: [], replacing: [
        H13LoginProbeDriver(state: loginState),
        H13MissingCredentialProbeDriver(state: credentialState),
    ])
    let settings = settingsDocument(revision: 6, commands: [
        .init(commandID: "draft.email", savedProfileID: selected, savedFallbackProfileIDs: [fallback])
    ])
    let store = ProviderRuntimeBrokerStore(broker: try harness.broker(settings: settings))
    let route = try await store.resolveReadiness(commandID: "draft.email", offline: false, dispatch: nil)
    #expect(exclusionKind(route.candidates[0]) == .needsLogin)
    #expect(exclusionKind(route.candidates[1]) == .authRequired)
    #expect(route.candidates[1].unavailabilityReason == "Cerebras: credential is missing")
    #expect(await loginState.probes == 1)
    #expect(await credentialState.probes == 1)
    let failure = await brokerError { try await store.execute(generationRequest("draft.email")) }
    #expect(failure?.record?.attempts.count == 2)
    #expect(await loginState.generations == 0)
    #expect(await credentialState.generations == 0)
}

@Test func unreachableLocalServiceHasSpecificHumanPreflightReason() async throws {
    let transport = H13UnreachableTransport()
    let harness = try RoutingHarness(qualifications: [], replacing: [OllamaHTTPDriver(transport: transport)])
    let store = ProviderRuntimeBrokerStore(broker: try harness.broker())
    let dispatch = ModelDispatchContext(generationID: "local-down", selection: .init(profileID: ProviderRuntimeCatalog.localFastProfileID))
    let route = try await store.resolveReadiness(commandID: "answer.quick", offline: false, dispatch: dispatch)
    #expect(exclusionKind(route.candidates.first) == .needsConfiguration)
    #expect(route.candidates.first?.unavailabilityReason == "Local: service is not running")
    let readiness = await store.readiness(probe: true)
    let local = try #require(readiness.first { $0.connectionID == ProviderRuntimeCatalog.localConnectionID })
    #expect(local.unavailabilityReason == "Local: service is not running")
    #expect(await transport.requestCount == 1)
    #expect(await transport.firstRequest?.httpMethod == "GET")
    #expect(await transport.firstRequest?.url?.path == "/api/tags")
}

@Test func danglingAPIReferenceShowsMissingCredentialWithoutRawDetail() async throws {
    let transport = H13UnreachableTransport()
    let credentials = ModelReferenceCredentialResolver(environment: { _ in nil })
    let harness = try RoutingHarness(qualifications: [], replacing: [
        CerebrasHTTPDriver(transport: transport, credentials: credentials)
    ])
    let settings = settingsDocument(revision: 7, connections: connectionsEnabling(
        ProviderRuntimeCatalog.cerebrasConnectionID,
        credential: .environmentVariable(name: "H13_DANGLING_REFERENCE")
    ))
    let store = ProviderRuntimeBrokerStore(broker: try harness.broker(settings: settings))
    let route = try await store.resolveReadiness(commandID: "answer.quick", offline: false,
        dispatch: .init(generationID: "api-credential", selection: .init(profileID: ProviderRuntimeCatalog.cerebrasFastProfileID)))
    #expect(exclusionKind(route.candidates.first) == .authRequired)
    #expect(route.candidates.first?.unavailabilityReason == "Cerebras: credential is missing")
    let readiness = await store.readiness(probe: true)
    let cerebras = try #require(readiness.first { $0.connectionID == ProviderRuntimeCatalog.cerebrasConnectionID })
    #expect(cerebras.unavailabilityReason == "Cerebras: credential is missing")
    #expect(await transport.requestCount == 0)
}

@Test func localTagsRequireTheSelectedInstalledModel() async throws {
    let missingTransport = CapturingExchangeTransport(json: #"{"models":[]}"#)
    let missingHarness = try RoutingHarness(qualifications: [], replacing: [OllamaHTTPDriver(transport: missingTransport)])
    let missingStore = ProviderRuntimeBrokerStore(broker: try missingHarness.broker())
    let dispatch = ModelDispatchContext(generationID: "local-model-check", selection: .init(profileID: ProviderRuntimeCatalog.localFastProfileID))
    let missing = try await missingStore.resolveReadiness(commandID: "answer.quick", offline: false, dispatch: dispatch)
    #expect(exclusionKind(missing.candidates.first) == .modelMismatch)
    #expect(missing.candidates.first?.unavailabilityReason == "Local: model is not installed")
    let readiness = await missingStore.readiness(probe: true)
    let local = try #require(readiness.first { $0.connectionID == ProviderRuntimeCatalog.localConnectionID })
    #expect(local.unavailabilityReason == "Local: model is not installed")
    let blocked = await brokerError {
        try await missingStore.execute(generationRequest("answer.quick", generationID: "local-model-check", selection: .init(profileID: ProviderRuntimeCatalog.localFastProfileID)))
    }
    #expect(blocked?.description == "Model unavailable: Local: model is not installed")
    #expect(await missingTransport.requestCount == 1)
    #expect(await missingTransport.requests.first?.httpMethod == "GET")

    let matchingTransport = CapturingExchangeTransport(json: #"{"models":[{"name":"qwen3:8b","model":"qwen3:8b"}]}"#)
    let matchingHarness = try RoutingHarness(qualifications: [], replacing: [OllamaHTTPDriver(transport: matchingTransport)])
    let matchingStore = ProviderRuntimeBrokerStore(broker: try matchingHarness.broker())
    let matching = try await matchingStore.resolveReadiness(commandID: "answer.quick", offline: false, dispatch: dispatch)
    #expect(matching.candidates.first?.isEligible == true)
    #expect(matching.candidates.first?.unavailabilityReason == nil)
    #expect(await matchingTransport.requestCount == 1)

    // Fixture probes intentionally carry no installed-model metadata.
    let fixture = try RoutingHarness(qualifications: [])
    let fixtureStore = ProviderRuntimeBrokerStore(broker: try fixture.broker())
    let fixtureRoute = try await fixtureStore.resolveReadiness(commandID: "answer.quick", offline: false, dispatch: dispatch)
    #expect(fixtureRoute.candidates.first?.isEligible == true)
}

@Test func localTagsHTTPErrorDoesNotClaimIsolationFailure() async throws {
    let transport = CapturingExchangeTransport(status: 503, json: #"{"error":"service busy"}"#)
    let harness = try RoutingHarness(qualifications: [], replacing: [OllamaHTTPDriver(transport: transport)])
    let store = ProviderRuntimeBrokerStore(broker: try harness.broker())
    let route = try await store.resolveReadiness(commandID: "answer.quick", offline: false,
        dispatch: .init(generationID: "tags-http-error", selection: .init(profileID: ProviderRuntimeCatalog.localFastProfileID)))
    #expect(exclusionKind(route.candidates.first) == .needsConfiguration)
    #expect(route.candidates.first?.unavailabilityReason == "Local: service returned an error")
    let readiness = await store.readiness(probe: true)
    let local = try #require(readiness.first { $0.connectionID == ProviderRuntimeCatalog.localConnectionID })
    #expect(local.unavailabilityReason == "Local: service returned an error")
    #expect(await transport.requestCount == 1)
    #expect(await transport.requests.first?.httpMethod == "GET")
}

@Test func observedIsolationFailureBlocksAuthOnlyReadinessUntilSettingsChange() async throws {
    let harness = try RoutingHarness(qualifications: [], scripts: [
        .claudePrint: [.failure(ModelDriverFailure(.isolationViolation, detail: "synthetic plugin load"))]
    ])
    let store = ProviderRuntimeBrokerStore(broker: try harness.broker())
    let selection = ModelInvocationSelection(profileID: ProviderRuntimeCatalog.claudeCapableProfileID)
    let failure = await brokerError { try await store.execute(generationRequest("answer.quick", selection: selection)) }
    #expect(failure?.record?.attempts.first?.identity?.failure == .isolationViolation)

    let route = try await store.resolveReadiness(commandID: "answer.quick", offline: false,
        dispatch: .init(generationID: "after-isolation-failure", selection: selection))
    #expect(exclusionKind(route.candidates.first) == .isolationViolation)
    #expect(route.candidates.first?.unavailabilityReason == "Claude: cannot run in the required safe environment")
    let readiness = await store.readiness(probe: false)
    let claude = try #require(readiness.first { $0.connectionID == ProviderRuntimeCatalog.claudeConnectionID })
    #expect(claude.availability == .unsupported)
    #expect(claude.unavailabilityReason == "Claude: cannot run in the required safe environment")
    #expect(await store.probe(connectionID: ProviderRuntimeCatalog.claudeConnectionID, force: true)?.availability == .unsupported)
    #expect(await harness.driver(.claudePrint).callCount() == 1)

    try await store.applySettings(settingsDocument(revision: 2))
    let recovered = try await store.resolveReadiness(commandID: "answer.quick", offline: false,
        dispatch: .init(generationID: "after-settings-change", selection: selection))
    #expect(recovered.candidates.first?.isEligible == true)
}

@Test func expiredIsolationBlockAllowsFreshProbeAndRepairedDispatch() async throws {
    let harness = try RoutingHarness(qualifications: [], scripts: [
        .claudePrint: [
            .failure(ModelDriverFailure(.isolationViolation, detail: "synthetic old CLI plugins")),
            .success(text: "repaired CLI answer"),
        ]
    ])
    let store = ProviderRuntimeBrokerStore(broker: try harness.broker(), isolationBlockTTL: 0)
    let selection = ModelInvocationSelection(profileID: ProviderRuntimeCatalog.claudeCapableProfileID)
    let failed = await brokerError { try await store.execute(generationRequest("answer.quick", selection: selection)) }
    #expect(failed?.record?.attempts.first?.identity?.failure == .isolationViolation)

    let expired = await store.readiness(probe: false)
    let beforeProbe = try #require(expired.first { $0.connectionID == ProviderRuntimeCatalog.claudeConnectionID })
    #expect(beforeProbe.availability != .unsupported)
    let route = try await store.resolveReadiness(commandID: "answer.quick", offline: false,
        dispatch: .init(generationID: "repaired-cli", selection: selection))
    #expect(route.candidates.first?.isEligible == true)
    let recovered = try await store.execute(generationRequest("answer.quick", selection: selection))
    #expect(recovered.response.text == "repaired CLI answer")
    #expect(await harness.driver(.claudePrint).callCount() == 2)
}

@Test func oldInFlightIsolationFailureCannotBlockNewSettings() async throws {
    let gate = H13IsolationGate()
    let harness = try RoutingHarness(qualifications: [], replacing: [H13DelayedIsolationDriver(gate: gate)])
    let store = ProviderRuntimeBrokerStore(broker: try harness.broker())
    let selection = ModelInvocationSelection(profileID: ProviderRuntimeCatalog.claudeCapableProfileID)
    let oldRun = Task {
        await brokerError { try await store.execute(generationRequest("answer.quick", selection: selection)) }
    }
    await gate.waitForStart()
    try await store.applySettings(settingsDocument(revision: 2))
    await gate.release()
    let failure = await oldRun.value
    // The settings update cancels the old attempt before its isolation result
    // can publish or install a block against the new configuration.
    guard case .cancelled? = failure else {
        Issue.record("Expected old in-flight request to be cancelled")
        return
    }
    let record = try #require(failure?.record)
    // The deadline child or the old driver may win cancellation. The outer
    // epoch fence can therefore produce a receipt with no completed attempt.
    // Neither path may publish the stale isolation failure or new settings.
    #expect(record.route?.settingsRevision == 1)
    #expect(record.attempts.allSatisfy { $0.outcome == .cancelled && $0.identity?.failure == .cancelled })

    let current = try await store.resolveReadiness(commandID: "answer.quick", offline: false,
        dispatch: .init(generationID: "after-old-failure", selection: selection))
    #expect(current.candidates.first?.isEligible == true)
    let readiness = await store.readiness(probe: false)
    let claude = try #require(readiness.first { $0.connectionID == ProviderRuntimeCatalog.claudeConnectionID })
    #expect(claude.availability == .ready)
}

@Test func physicalAndCostReasonsStayHuman() throws {
    let harness = try RoutingHarness(qualifications: [])
    let noDriver = try ModelProviderRegistry(qualifications: [], drivers: [])
    let absent = try ProviderRuntimeBroker(registry: noDriver)
    let selected = ModelDispatchContext(generationID: "physical", selection: .init(profileID: ProviderRuntimeCatalog.chatGPTCapableProfileID))
    let missing = try absent.resolve(commandID: "draft.email", offline: false, dispatch: selected)
    #expect(exclusionKind(missing.candidates.first) == .unconfigured)
    #expect(missing.candidates.first?.unavailabilityReason == "ChatGPT: no driver is available")

    let disabled = try harness.broker().resolve(commandID: "draft.email", offline: false,
        dispatch: ModelDispatchContext(generationID: "disabled", selection: .init(profileID: ProviderRuntimeCatalog.openAIAPICapableProfileID)))
    #expect(disabled.candidates.first?.unavailabilityReason == "OpenAI API: connection is off")
    let offline = try harness.broker().resolve(commandID: "draft.email", offline: true, dispatch: selected)
    #expect(offline.candidates.first?.unavailabilityReason == "ChatGPT: unavailable while offline")
    #expect(ModelHumanFailure.reason(kind: .needsConfiguration, driverID: .codexAppServer, detail: "CLI not found") == "Codex CLI not found")
    #expect(ModelHumanFailure.reason(kind: .authRequired, driverID: .cerebrasHTTP) == "credential is missing")
    #expect(ModelHumanFailure.reason(kind: .unsupportedCapability, driverID: .claudePrint) == "cannot provide this command's required output")
    #expect(ModelHumanFailure.reason(kind: .apiRoutePermissionRequired, driverID: .openAIHTTP) == "paid API route needs permission")
}

@Test func missingCLIAndCredentialStillBlockManualPicks() throws {
    let codex = CodexAppServerDriver(launchOwner: CodexLaunchOwner(providerRoot: FileManager.default.temporaryDirectory))
    let registry = try ModelProviderRegistry(drivers: [codex])
    let savedConnections = ProviderRuntimeSettings.freshDefaults().connections.map { saved in
        guard saved.connectionID == ProviderRuntimeCatalog.chatGPTConnectionID else { return saved }
        return ModelConnectionSettings(connectionID: saved.connectionID, enabled: true,
            cliProfile: .init(executable: "omni-h13-deliberately-missing-cli", configurationDirectory: "codex-home"),
            revision: saved.revision + 1)
    }
    let broker = try ProviderRuntimeBroker(registry: registry,
        settings: settingsDocument(revision: 2, connections: savedConnections))
    let codexRoute = try broker.resolve(commandID: "draft.email", offline: false,
        dispatch: .init(generationID: "missing-cli", selection: .init(profileID: ProviderRuntimeCatalog.chatGPTCapableProfileID)))
    #expect(exclusionKind(codexRoute.candidates.first) == .needsConfiguration)
    #expect(codexRoute.candidates.first?.unavailabilityReason == "ChatGPT: Codex CLI not found")

    let cerebras = CerebrasHTTPDriver(transport: CapturingExchangeTransport(json: openAICompletion),
                                      credentials: RecordingCredentialResolver())
    let noCredential = try ProviderRuntimeBroker(registry: ModelProviderRegistry(drivers: [cerebras]))
    let credentialRoute = try noCredential.resolve(commandID: "answer.quick", offline: false,
        dispatch: .init(generationID: "missing-credential", selection: .init(profileID: ProviderRuntimeCatalog.cerebrasFastProfileID)))
    #expect(exclusionKind(credentialRoute.candidates.first) == .needsConfiguration)
    #expect(credentialRoute.candidates.first?.unavailabilityReason == "Cerebras: credential is missing")
}

@Test func requiredOutputCapabilityStillBlocksManualPick() throws {
    let original = try #require(ProviderRuntimeCatalog.profile(ProviderRuntimeCatalog.cerebrasFastProfileID))
    let limited = ModelProfile(id: original.id, connectionID: original.connectionID,
                               modelSelector: original.modelSelector, options: original.options,
                               capabilities: [.plainText, .reasoningLevel, .outputTokenLimit, .temperature],
                               eligibleCommandIDs: original.eligibleCommandIDs)
    let profiles = ProviderRuntimeCatalog.profiles.map { $0.id == original.id ? limited : $0 }
    let harness = try RoutingHarness(qualifications: [], profiles: profiles)
    let route = try harness.broker().resolve(commandID: "tier2.proposal", offline: false,
        dispatch: .init(generationID: "no-json", selection: .init(profileID: original.id)))
    #expect(exclusionKind(route.candidates.first) == .unsupportedCapability)
    #expect(route.candidates.first?.unavailabilityReason == "Cerebras: cannot provide this command's required output")
}

@Test func everyFailureKindUsesHumanCopy() {
    for kind in ModelFailureKind.allCases {
        let reason = ModelHumanFailure.reason(kind: kind, driverID: .codexAppServer)
        #expect(!reason.isEmpty)
        #expect(reason != kind.rawValue)
        #expect(!reason.contains("chatgpt-capable"))
    }
    #expect(ModelHumanFailure.reason(kind: .apiRoutePermissionRequired, driverID: .openAIHTTP) == "paid API route needs permission")
}

@Test func userLocalBinFindsCLIsWithoutShellWhenHostPathIsMissing() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-cli-resolver-\(UUID().uuidString)")
    let userLocalBin = root.appendingPathComponent(".local/bin")
    try FileManager.default.createDirectory(at: userLocalBin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for executable in ["codex", "claude"] {
        let fixture = userLocalBin.appendingPathComponent(executable)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fixture, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let resolved = CLIExecutableResolver.resolve(executable, searchPath: "/nonexistent", userLocalBin: userLocalBin)
        #expect(resolved == fixture, "\(executable) must resolve from the user-local binary directory")
        #expect(FileManager.default.isExecutableFile(atPath: fixture.path))
    }
}
