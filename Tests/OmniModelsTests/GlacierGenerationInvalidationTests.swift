import Foundation
import OmniCore
import OmniModels
import Testing

private actor SuspendedGenerationGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var starts = 0
    private(set) var observedCancellation = false

    func suspendIgnoringCancellation() async {
        starts += 1
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if !released {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        observedCancellation = Task.isCancelled
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private struct LateProbeDriver: ModelProviderDriver {
    let driverID: ModelDriverID = .cerebrasHTTP
    let capabilities: Set<ModelCapability> = Set(ModelCapability.allCases)
    let gate: SuspendedGenerationGate

    func configurationIssue(for connection: ModelConnectionProfile) -> ModelFailureKind? { nil }
    func probe(connection: ModelConnectionProfile) async -> ModelConnectionProbe {
        await gate.suspendIgnoringCancellation()
        return ModelConnectionProbe(availability: .ready, detail: "late synthetic probe")
    }
    func generate(_ request: ModelDriverRequest) async throws -> ModelDriverResponse {
        ModelDriverResponse(text: "must not generate", observedAuthRoute: request.connection.authRoute)
    }
}

private struct LateGlacierDriver: ModelStreamingProviderDriver {
    let driverID: ModelDriverID = .cerebrasHTTP
    let capabilities: Set<ModelCapability> = Set(ModelCapability.allCases)
    let gate: SuspendedGenerationGate

    func configurationIssue(for connection: ModelConnectionProfile) -> ModelFailureKind? { nil }
    func probe(connection: ModelConnectionProfile) async -> ModelConnectionProbe {
        ModelConnectionProbe(availability: .ready, detail: "synthetic")
    }
    func generate(_ request: ModelDriverRequest) async throws -> ModelDriverResponse {
        await gate.suspendIgnoringCancellation()
        return ModelDriverResponse(text: "late result", observedAuthRoute: request.connection.authRoute)
    }
    func stream(_ request: ModelDriverRequest,
                onText: @escaping @Sendable (String) async -> Void) async throws -> ModelDriverResponse {
        await gate.suspendIgnoringCancellation()
        await onText("stale delta")
        return ModelDriverResponse(text: "1. late", observedAuthRoute: request.connection.authRoute)
    }
}

private actor GlacierDeltaRecorder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private func replacementSettings() -> ProviderRuntimeSettings {
    settingsDocument(revision: 2, profiles: [ModelProfileSettings(
        profileID: ProviderRuntimeCatalog.cerebrasFastProfileID,
        modelSelector: "replacement-model"
    )])
}

@Test func applySettingsCancelsDurableGenerationAndRejectsLateDriverSuccess() async throws {
    let gate = SuspendedGenerationGate()
    let harness = try RoutingHarness(replacing: [LateGlacierDriver(gate: gate)])
    let store = ProviderRuntimeBrokerStore(broker: try harness.broker())
    let request = generationRequest("answer.quick", selection: .init(profileID: ProviderRuntimeCatalog.cerebrasFastProfileID))
    let task = Task { try await store.execute(request) }
    await gate.waitUntilStarted()
    try await store.applySettings(replacementSettings())
    await gate.release()
    let error = await brokerError { try await task.value }
    guard case .cancelled(let record)? = error else {
        Issue.record("Expected old durable generation to be cancelled")
        return
    }
    #expect(record.settingsConfigurationVersion == 1)
    #expect(await gate.observedCancellation)
}

@Test func invalidationHookCancelsExecuteOnceEvenWhenDriverIgnoresCancellation() async throws {
    let gate = SuspendedGenerationGate()
    let harness = try RoutingHarness(replacing: [LateGlacierDriver(gate: gate)])
    let store = ProviderRuntimeBrokerStore(broker: try harness.broker())
    let request = generationRequest("answer.quick", selection: .init(profileID: ProviderRuntimeCatalog.cerebrasFastProfileID))
    let task = Task { try await store.executeOnce(request) }
    await gate.waitUntilStarted()
    await store.invalidateActiveRequests()
    await gate.release()
    let error = await brokerError { try await task.value }
    guard case .cancelled? = error else {
        Issue.record("Expected invalidated executeOnce to be cancelled")
        return
    }
    #expect(await gate.observedCancellation)
}

@Test func applySettingsDropsLateStreamingDeltaAndCompletion() async throws {
    let gate = SuspendedGenerationGate()
    let harness = try RoutingHarness(replacing: [LateGlacierDriver(gate: gate)])
    let store = ProviderRuntimeBrokerStore(broker: try harness.broker())
    let recorder = GlacierDeltaRecorder()
    let request = generationRequest("translate", selection: .init(profileID: ProviderRuntimeCatalog.cerebrasFastProfileID))
    let task = Task { try await store.stream(request) { await recorder.append($0) } }
    await gate.waitUntilStarted()
    try await store.applySettings(replacementSettings())
    await gate.release()
    let error = await brokerError { try await task.value }
    guard case .cancelled? = error else {
        Issue.record("Expected old stream to be cancelled")
        return
    }
    #expect(await recorder.values.isEmpty)
    #expect(await gate.observedCancellation)
}

@Test func policyInvalidationHookDropsLateStreamingDelta() async throws {
    let gate = SuspendedGenerationGate()
    let harness = try RoutingHarness(replacing: [LateGlacierDriver(gate: gate)])
    let store = ProviderRuntimeBrokerStore(broker: try harness.broker())
    let recorder = GlacierDeltaRecorder()
    let request = generationRequest("translate", selection: .init(profileID: ProviderRuntimeCatalog.cerebrasFastProfileID))
    let task = Task { try await store.stream(request) { await recorder.append($0) } }
    await gate.waitUntilStarted()
    await store.invalidateActiveRequests()
    await gate.release()
    let error = await brokerError { try await task.value }
    guard case .cancelled? = error else {
        Issue.record("Expected policy-invalidated stream to be cancelled")
        return
    }
    #expect(await recorder.values.isEmpty)
}

@Test func invalidationDuringPreflightDoesNotStartReplacementProbe() async throws {
    let gate = SuspendedGenerationGate()
    let harness = try RoutingHarness(replacing: [LateProbeDriver(gate: gate)])
    let store = ProviderRuntimeBrokerStore(broker: try harness.broker())
    let request = generationRequest("answer.quick", selection: .init(profileID: ProviderRuntimeCatalog.cerebrasFastProfileID))
    let task = Task { try await store.executeOnce(request) }
    await gate.waitUntilStarted()
    await store.invalidateActiveRequests()
    await gate.release()
    let error = await brokerError { try await task.value }
    guard case .cancelled(let record)? = error else {
        Issue.record("Expected preflight-invalidated generation to be cancelled")
        return
    }
    #expect(record.settingsConfigurationVersion == 1)
    #expect(await gate.starts == 1)
    #expect(await gate.observedCancellation)
}
