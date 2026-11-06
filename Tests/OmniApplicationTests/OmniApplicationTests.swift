import Foundation
import OmniApplication
import OmniCore
import OmniFixtures
import OmniRun
import Testing

private struct ApplicationTestRig {
    let envelope: URL
    let root: URL
    let owner: FixtureOwnerStore
    let store: OmniRunStore
    let service: OmniApplicationService

    static func make(
        timeout: Duration = .seconds(5),
        proposalGenerator: (any ProposalGenerating)? = nil,
        proposalSource: any Tier2ProposalSource = FakeTier2ProposalSource(),
        followUpGenerator: (any FollowUpGenerating)? = nil,
        followUpAdmissionHook: (any FollowUpAdmissionHook)? = nil,
        completedEffectGate: CompletedEffectGate? = nil
    ) async throws -> ApplicationTestRig {
        let envelope = FileManager.default.temporaryDirectory.appendingPathComponent("omni-app-tests-\(UUID().uuidString)", isDirectory: true)
        let root = envelope.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let corpus = FrozenContractCorpus()
        let manifest = try corpus.manifest()
        let declarations = try corpus.moduleDeclarations().declarations
        let validatedRoot = try OmniDevelopmentRoot(validating: root, allowedRoot: envelope)
        let catalog = try FixtureModuleCatalog(manifest: manifest, declarations: declarations, developmentRoot: validatedRoot)
        let references = try ReferenceRegistry([])
        let store = try OmniRunStore(developmentRoot: root, allowedRoot: envelope)
        let registry: ModuleRegistry
        if let completedEffectGate {
            let declaration = try #require(declarations.first { $0.moduleID == "capture.todo" })
            let command = try #require(manifest.command(for: declaration.tokens.canonical))
            let descriptor = ModuleDescriptor(
                moduleID: declaration.moduleID,
                moduleVersion: declaration.moduleVersion,
                execution: declaration.executionPath.kind,
                capabilities: Set(command.capabilities),
                policies: declaration.typedPolicies
            )
            let gatedFactory = AnyCommandModuleFactory(moduleID: declaration.moduleID) {
                GatedCompletedEffectModule(descriptor: descriptor, owner: catalog.owner, gate: completedEffectGate)
            }
            registry = try ModuleRegistry(manifest.moduleIDs.sorted().compactMap { moduleID in
                moduleID == declaration.moduleID ? gatedFactory : catalog.registry.factory(for: moduleID)
            })
        } else {
            registry = catalog.registry
        }
        let service = OmniApplicationService(
            parser: OmniParser(manifest: manifest, references: references),
            registry: registry,
            proposalSource: proposalSource,
            store: store,
            proposalGenerator: proposalGenerator,
            followUpGenerator: followUpGenerator,
            followUpAdmissionHook: followUpAdmissionHook,
            executionTimeout: timeout
        )
        return ApplicationTestRig(envelope: envelope, root: root, owner: catalog.owner, store: store, service: service)
    }

    func remove() { try? FileManager.default.removeItem(at: envelope) }
}

private struct ChosenQuickLegacyProposalSource: Tier2ProposalSource {
    func propose(for intent: ParsedIntent) async throws -> Tier2Proposal {
        let chosen = intent.canonicalText.replacingOccurrences(of: "/save", with: "/qq", options: .anchored)
        return Tier2Proposal(moduleID: "answer.quick", capabilities: [], input: chosen)
    }
}

private actor ReconciliationPlanRecorder {
    private var captured: CommandPlan?

    func record(_ plan: CommandPlan) { captured = plan }
    func plan() -> CommandPlan? { captured }
}

private struct RecordingReconciliationModule: CommandModule {
    let descriptor: ModuleDescriptor
    let recorder: ReconciliationPlanRecorder

    func validate(input: ModuleInput) throws {}

    func makePlan(input: ModuleInput) throws -> CommandPlan {
        CommandPlan(moduleID: descriptor.moduleID, input: input, capabilitySet: descriptor.capabilities)
    }

    func start(plan: CommandPlan, capabilities: CapabilityBroker, runID: String) async throws -> any RunExecutionHandle {
        throw OmniCoreError.invalidProposal
    }

    func reconcile(runID: String, plan: CommandPlan) async -> ReconciliationDisposition {
        await recorder.record(plan)
        return .interrupted(effectCertainty: .uncertain)
    }
}

private actor ControlledFollowUpGenerator: FollowUpGenerating {
    private var requests: [FollowUpGenerationRequest] = []
    private var continuations: [CheckedContinuation<FollowUpGeneration, Error>] = []

    func generate(_ request: FollowUpGenerationRequest) async throws -> FollowUpGeneration {
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func cancel(runID: String) async {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }

    func complete(with text: String) {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume(returning: FollowUpGeneration(resultText: text)) }
    }

    func fail() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume(throwing: FixtureModuleError.executionRequested) }
    }

    func capturedRequests() -> [FollowUpGenerationRequest] { requests }
}

private actor FollowUpAdmissionBarrier: FollowUpAdmissionHook {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func didReserve(runID: RunID, requestID: String) async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private func waitForFollowUpRequests(
    _ generator: ControlledFollowUpGenerator,
    count: Int = 1
) async throws {
    for _ in 0..<200 {
        if (await generator.capturedRequests()).count >= count { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting for follow-up generator request")
}

private func waitForResultVersionCount(
    _ service: OmniApplicationService,
    runID: RunID,
    count: Int
) async throws -> [OmniResultVersion] {
    for _ in 0..<200 {
        let versions = try await service.resultVersions(runID: runID)
        if versions.count == count { return versions }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw OmniApplicationError.terminalWaitTimedOut
}

@Test func completedDraftGetsImmutableInitialAndFollowUpVersionsOnTheSameRun() async throws {
    let generator = ControlledFollowUpGenerator()
    let rig = try await ApplicationTestRig.make(followUpGenerator: generator)
    defer { rig.remove() }

    let submission = try await rig.service.submit("/email Hello team")
    let runID = try #require(submission.runID)
    _ = try await rig.service.waitForTerminal(runID: runID)
    let initial = try await rig.service.resultVersions(runID: runID)
    #expect(initial.count == 1)
    #expect(initial[0].number == 1)
    #expect(initial[0].operation == .initial)
    #expect(initial[0].inputText == "/email Hello team")

    try await rig.service.submitFollowUp(
        runID: runID,
        sourceVersion: 1,
        visibleText: "Edited draft with the greeting\n/shorter"
    )
    try await waitForFollowUpRequests(generator)
    let request = try #require(await generator.capturedRequests().first)
    #expect(request.runID == runID.rawValue)
    #expect(request.sourceVersion == 1)
    #expect(request.sourceText == "Edited draft with the greeting")
    #expect(request.visibleText == "Edited draft with the greeting\n/shorter")
    #expect(request.operation == .shorter)
    #expect((await rig.service.followUpState(runID: runID))?.kind == .pending)
    #expect((await rig.store.recentRuns()).count == 1)

    await generator.complete(with: "Hello team")
    let versions = try await waitForResultVersionCount(rig.service, runID: runID, count: 2)
    #expect(versions.map(\.number) == [1, 2])
    #expect(versions[1].inputText == "Edited draft with the greeting\n/shorter")
    #expect(versions[1].resultText == "Hello team")
    #expect(versions[1].operation == .shorter)
    #expect(versions[1].sourceVersion == 1)
    #expect(await rig.service.followUpState(runID: runID) == nil)
    #expect((await rig.service.resultViewModel(runID: runID))?.fullText == "Hello team")
    #expect((await rig.store.receipt(for: runID))?.status == .succeeded)
}

@Test func followUpGuidanceReachesRequestAndCompletedVersionInEditorCoordinates() async throws {
    let generator = ControlledFollowUpGenerator()
    let rig = try await ApplicationTestRig.make(followUpGenerator: generator)
    defer { rig.remove() }
    let initialNote = OmniTextAnnotation(range: NSRange(location: 7, length: 8), guidance: "Keep this meaning")
    let submission = try await rig.service.submit("/email Original draft", annotations: [initialNote])
    let runID = try #require(submission.runID)
    _ = try await rig.service.waitForTerminal(runID: runID)
    #expect((try await rig.service.resultVersions(runID: runID)).first?.annotations == [initialNote])

    let visibleText = "Edited draft /formal"
    let note = OmniTextAnnotation(range: NSRange(location: 0, length: 6), guidance: "Preserve the opening")
    let invalidNote = OmniTextAnnotation(range: NSRange(location: 500, length: 4), guidance: "Out of bounds")
    try await rig.service.submitFollowUp(runID: runID, sourceVersion: 1, visibleText: visibleText, annotations: [note, invalidNote])
    try await waitForFollowUpRequests(generator)
    let request = try #require(await generator.capturedRequests().first)
    #expect(request.annotations == [note])
    #expect(request.sourceText == "Edited draft")
    #expect((await rig.service.followUpState(runID: runID))?.annotations == [note])
    #expect((await rig.service.followUpState(runID: runID))?.annotationNotice != nil)

    await generator.complete(with: "Edited result")
    let versions = try await waitForResultVersionCount(rig.service, runID: runID, count: 2)
    #expect(versions[1].inputText == visibleText)
    #expect(versions[1].annotations == [note])
}

@Test func followUpRejectsAmbiguousOperationAndDoesNotRestoreDeletedSourceText() async throws {
    let generator = ControlledFollowUpGenerator()
    let rig = try await ApplicationTestRig.make(followUpGenerator: generator)
    defer { rig.remove() }
    let submission = try await rig.service.submit("/email Original draft")
    let runID = try #require(submission.runID)
    _ = try await rig.service.waitForTerminal(runID: runID)

    await #expect(throws: OmniApplicationError.unsupportedFollowUpOperation) {
        try await rig.service.submitFollowUp(runID: runID, sourceVersion: 1, visibleText: "Replacement /shorter /formal")
    }
    await #expect(throws: OmniApplicationError.emptyFollowUpSource) {
        try await rig.service.submitFollowUp(runID: runID, sourceVersion: 1, visibleText: "/shorter")
    }
    try await rig.service.submitFollowUp(runID: runID, sourceVersion: 1, visibleText: "Entirely rewritten body /formal")
    try await waitForFollowUpRequests(generator)
    let request = try #require(await generator.capturedRequests().first)
    #expect(request.sourceVersion == 1)
    #expect(request.sourceText == "Entirely rewritten body")
    #expect(!request.prompt.contains("fake email draft"))
    try await rig.service.cancelFollowUp(runID: runID)
    #expect((try await rig.service.resultVersions(runID: runID)).count == 1)
}

@Test func concurrentFollowUpsCannotReplaceOwnershipBeforeTheFirstReceiptRead() async throws {
    let barrier = FollowUpAdmissionBarrier()
    let generator = ControlledFollowUpGenerator()
    let rig = try await ApplicationTestRig.make(followUpGenerator: generator, followUpAdmissionHook: barrier)
    defer { rig.remove() }
    let submission = try await rig.service.submit("/email Original")
    let runID = try #require(submission.runID)
    _ = try await rig.service.waitForTerminal(runID: runID)
    let first = Task { try await rig.service.submitFollowUp(runID: runID, sourceVersion: 1, visibleText: "First edited body /shorter") }
    await barrier.waitUntilEntered()
    #expect(await rig.service.followUpState(runID: runID) == nil)
    await #expect(throws: OmniApplicationError.followUpAlreadyActive) {
        try await rig.service.submitFollowUp(runID: runID, sourceVersion: 1, visibleText: "Competing body /formal")
    }
    await barrier.release()
    try await first.value
    try await waitForFollowUpRequests(generator)
    #expect(await generator.capturedRequests().count == 1)
    await generator.complete(with: "First result")
    let versions = try await waitForResultVersionCount(rig.service, runID: runID, count: 2)
    #expect(versions.last?.resultText == "First result")
}

@Test func cancellationAndShutdownReclaimReservedFollowUpBeforeDurableAdmission() async throws {
    let cancellationBarrier = FollowUpAdmissionBarrier()
    let generator = ControlledFollowUpGenerator()
    let cancelRig = try await ApplicationTestRig.make(
        followUpGenerator: generator,
        followUpAdmissionHook: cancellationBarrier
    )
    defer { cancelRig.remove() }
    let submission = try await cancelRig.service.submit("/email Original")
    let runID = try #require(submission.runID)
    _ = try await cancelRig.service.waitForTerminal(runID: runID)
    let admission = Task { try await cancelRig.service.submitFollowUp(runID: runID, sourceVersion: 1, visibleText: "Edited /shorter") }
    await cancellationBarrier.waitUntilEntered()
    try await cancelRig.service.cancelFollowUp(runID: runID)
    await cancellationBarrier.release()
    try await admission.value
    for _ in 0..<100 {
        if (await cancelRig.service.followUpState(runID: runID))?.kind == .cancelled { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect((await cancelRig.service.followUpState(runID: runID))?.kind == .cancelled)
    #expect(await generator.capturedRequests().isEmpty)

    try await cancelRig.service.submitFollowUp(runID: runID, sourceVersion: 1, visibleText: "Retry body /formal")
    try await waitForFollowUpRequests(generator)
    try await cancelRig.service.cancelFollowUp(runID: runID)

    let shutdownBarrier = FollowUpAdmissionBarrier()
    let shutdownRig = try await ApplicationTestRig.make(
        followUpGenerator: ControlledFollowUpGenerator(),
        followUpAdmissionHook: shutdownBarrier
    )
    defer { shutdownRig.remove() }
    let shutdownSubmission = try await shutdownRig.service.submit("/email Original")
    let shutdownRunID = try #require(shutdownSubmission.runID)
    _ = try await shutdownRig.service.waitForTerminal(runID: shutdownRunID)
    let pendingAdmission = Task { try await shutdownRig.service.submitFollowUp(runID: shutdownRunID, sourceVersion: 1, visibleText: "Edited /shorter") }
    await shutdownBarrier.waitUntilEntered()
    _ = await shutdownRig.service.shutdown(timeout: .milliseconds(10))
    await shutdownBarrier.release()
    try await pendingAdmission.value
    for _ in 0..<100 {
        if (await shutdownRig.service.followUpState(runID: shutdownRunID))?.kind == .cancelled { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect((await shutdownRig.service.followUpState(runID: shutdownRunID))?.kind == .cancelled)
}

@Test func cancelledOrFailedFollowUpKeepsLatestCompletedVersionAndRejectsConcurrentWork() async throws {
    let generator = ControlledFollowUpGenerator()
    let rig = try await ApplicationTestRig.make(followUpGenerator: generator)
    defer { rig.remove() }
    let submission = try await rig.service.submit("/email Hello team")
    let runID = try #require(submission.runID)
    _ = try await rig.service.waitForTerminal(runID: runID)

    try await rig.service.submitFollowUp(runID: runID, sourceVersion: 1, visibleText: "/formal Please refine")
    try await waitForFollowUpRequests(generator)
    await #expect(throws: OmniApplicationError.followUpAlreadyActive) {
        try await rig.service.submitFollowUp(runID: runID, sourceVersion: 1, visibleText: "/shorter Retry")
    }
    try await rig.service.cancelFollowUp(runID: runID)
    #expect((try await rig.service.resultVersions(runID: runID)).count == 1)
    #expect((await rig.service.followUpState(runID: runID))?.kind == .cancelled)

    try await rig.service.submitFollowUp(runID: runID, sourceVersion: 1, visibleText: "/shorter Make brief")
    try await waitForFollowUpRequests(generator, count: 2)
    await generator.fail()
    for _ in 0..<200 {
        if (await rig.service.followUpState(runID: runID))?.kind == .failed { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect((await rig.service.followUpState(runID: runID))?.kind == .failed)
    #expect((try await rig.service.resultVersions(runID: runID)).count == 1)
    #expect((await rig.store.receipt(for: runID))?.status == .succeeded)
}

private actor CompletedEffectGate {
    private var effectCompleted = false
    private var effectWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func noteEffectCompleted() {
        effectCompleted = true
        let waiters = effectWaiters
        effectWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilEffectCompleted() async {
        guard !effectCompleted else { return }
        await withCheckedContinuation { effectWaiters.append($0) }
    }

    func waitForRelease() async {
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private struct GatedCompletedEffectModule: CommandModule {
    let descriptor: ModuleDescriptor
    let owner: FixtureOwnerStore
    let gate: CompletedEffectGate

    func validate(input: ModuleInput) throws {}

    func makePlan(input: ModuleInput) throws -> CommandPlan {
        CommandPlan(moduleID: descriptor.moduleID, input: input, capabilitySet: descriptor.capabilities)
    }

    func start(plan: CommandPlan, capabilities: CapabilityBroker, runID: String) async throws -> any RunExecutionHandle {
        for capability in descriptor.capabilities { _ = try capabilities.handle(for: capability) }
        return GatedCompletedEffectHandle(runID: runID, owner: owner, gate: gate)
    }

    func reconcile(runID: String, plan: CommandPlan) async -> ReconciliationDisposition {
        .interrupted(effectCertainty: .uncertain)
    }
}

private actor GatedCompletedEffectHandle: RunExecutionHandle {
    nonisolated let runID: String
    private let owner: FixtureOwnerStore
    private let gate: CompletedEffectGate
    private var task: Task<ModuleExecutionOutcome, Never>?
    private var cachedOutcome: ModuleExecutionOutcome?

    init(runID: String, owner: FixtureOwnerStore, gate: CompletedEffectGate) {
        self.runID = runID
        self.owner = owner
        self.gate = gate
    }

    func value() async -> ModuleExecutionOutcome {
        if let cachedOutcome { return cachedOutcome }
        if let task { return await task.value }
        let task = Task { await perform() }
        self.task = task
        let outcome = await task.value
        cachedOutcome = outcome
        self.task = nil
        return outcome
    }

    func requestCancellation() async -> OmniCore.CancellationAcknowledgement {
        OmniCore.CancellationAcknowledgement(
            requestObserved: false,
            taskOrProcessStopped: true,
            ownerAcknowledged: true,
            effectCertainty: .certain
        )
    }

    private func perform() async -> ModuleExecutionOutcome {
        do {
            _ = try await owner.execute(behavior: .todo, payload: "already written", runID: runID)
            await gate.noteEffectCompleted()
            await gate.waitForRelease()
            return .succeeded(ModuleResult(summary: "Added to fake Ledger", allowedActions: [.dismiss]))
        } catch {
            return .failed(summary: "fixture failed: \(error)")
        }
    }
}

/// Holds `cancel` at a deliberate actor suspension point. It lets a queued
/// execution advance while cancellation owns a run-scoped generator request.
private actor CancellationGateProposalGenerator: ProposalGenerating {
    private var cancellationSeen = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func generate(intent: ParsedIntent, runID: String) async throws -> ProposalGeneration {
        throw CancellationError()
    }

    func cancel(runID: String) async {
        cancellationSeen = true
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func hasSeenCancellation() -> Bool { cancellationSeen }

    func releaseCancellation() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor CancellationRecordProposalGenerator: ProposalGenerating {
    private var records: [String: ModelExecutionRecord] = [:]

    func generate(intent: ParsedIntent, runID: String) async throws -> ProposalGeneration {
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }

    func cancel(runID: String) async {
        records[runID] = ModelExecutionRecord(
            runtimePolicyVersion: "test-cancellation-policy",
            commandID: "tier2.proposal",
            runID: runID,
            offline: false,
            settingsConfigurationID: "test-settings",
            settingsConfigurationVersion: 1,
            attempts: [
                .init(
                    providerID: "fixture:proposal",
                    providerClass: .localCapable,
                    outcome: .cancelled,
                    detail: "generator cancelled"
                )
            ]
        )
    }

    func modelExecutionRecord(runID: String) async -> ModelExecutionRecord? { records[runID] }
}

private func waitUntilRunning(_ store: OmniRunStore, runID: RunID) async throws {
    for _ in 0..<200 {
        if await store.receipt(for: runID)?.status == .running { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw OmniApplicationError.terminalWaitTimedOut
}

@Test func publicFixtureCatalogRejectsCallerSelectedRootsOutsidePhaseThreeOrSystemTemporary() throws {
    let corpus = FrozenContractCorpus()
    let rootURL = URL(fileURLWithPath: "/", isDirectory: true)
    let broadRoot = try OmniDevelopmentRoot(validating: rootURL, allowedRoot: rootURL)
    #expect(throws: OmniRunError.forbiddenDevelopmentRoot("/")) {
        _ = try FixtureModuleCatalog(
            manifest: corpus.manifest(),
            declarations: corpus.moduleDeclarations().declarations,
            developmentRoot: broadRoot
        )
    }
}

@Test func tierOnePersistsBeforeFakeMutationAndProjectsDurableResult() async throws {
    let rig = try await ApplicationTestRig.make()
    defer { rig.remove() }
    let submission = try await rig.service.submit("/todo buy milk")
    let id = try #require(submission.runID)
    let first = try #require(await rig.store.allEvents().first)
    #expect(first.kind == .submitted)
    #expect(first.runID == id)
    let result = try await rig.service.waitForTerminal(runID: id)
    #expect(result.state == .succeeded)
    #expect(result.moduleID == "capture.todo")
    #expect(try await rig.owner.contents(relativePath: "ledger/capture.txt") == "buy milk\n")
    let kinds = await rig.store.allEvents().filter { $0.runID == id }.map(\.kind)
    #expect(kinds.first == .submitted)
    #expect(kinds.firstIndex(of: .effectAttempted)! < kinds.firstIndex(of: .effectSucceeded)!)
    #expect(try await rig.store.indexedRecentRuns().first?.id == id)
}

@Test func validationFailureCreatesNoRunAndExecutionFailureIsDurable() async throws {
    let rig = try await ApplicationTestRig.make()
    defer { rig.remove() }
    await #expect(throws: FixtureModuleError.validationRequested) {
        _ = try await rig.service.submit("/todo [fixture:validation-failure] bad")
    }
    #expect(await rig.store.allEvents().isEmpty)

    let failed = try await rig.service.submit("/todo [fixture:execution-failure] bad")
    let id = try #require(failed.runID)
    let receipt = try await rig.service.waitForTerminal(runID: id)
    #expect(receipt.state == .failed)
    #expect((await rig.store.allEvents()).contains { $0.runID == id && $0.kind == .effectFailed })
}

@Test func cancellationAndTimeoutRequireRunBoundAcknowledgement() async throws {
    let cancelRig = try await ApplicationTestRig.make()
    defer { cancelRig.remove() }
    let cancelSubmission = try await cancelRig.service.submit("/todo [fixture:slow] cancel me")
    let cancelID = try #require(cancelSubmission.runID)
    try await waitUntilRunning(cancelRig.store, runID: cancelID)
    try await cancelRig.service.cancel(runID: cancelID)
    #expect((try #require(await cancelRig.store.receipt(for: cancelID))).status == .cancelled)
    let cancellationKinds = await cancelRig.store.allEvents().filter { $0.runID == cancelID }.map(\.kind)
    #expect(Array(cancellationKinds.suffix(3)) == [.cancellationRequested, .cancellationAcknowledged, .cancelled])

    let timeoutRig = try await ApplicationTestRig.make(timeout: .milliseconds(30))
    defer { timeoutRig.remove() }
    let timeoutSubmission = try await timeoutRig.service.submit("/todo [fixture:slow] time out")
    let timeoutID = try #require(timeoutSubmission.runID)
    _ = try await timeoutRig.service.waitForTerminal(runID: timeoutID)
    let timeoutEvents = await timeoutRig.store.allEvents().filter { $0.runID == timeoutID }
    #expect(timeoutEvents.contains { $0.kind == .cancellationRequested && $0.payload.message == "timeout" })
}

@Test func interruptionBecomesEffectUncertainAndMutationRetryWithoutProofIsRejected() async throws {
    let rig = try await ApplicationTestRig.make()
    defer { rig.remove() }
    let submission = try await rig.service.submit("/todo [fixture:interruption] uncertain")
    let id = try #require(submission.runID)
    #expect((try await rig.service.waitForTerminal(runID: id)).state == .interrupted)
    #expect((await rig.store.allEvents()).contains { $0.runID == id && $0.kind == .effectUncertain })
    #expect(try await !rig.store.automaticRetryIsAllowed(id))
    await #expect(throws: OmniApplicationError.retryNotAllowed) {
        _ = try await rig.service.retry(runID: id)
    }
    #expect(!(try #require(await rig.service.resultViewModel(runID: id))).actions.contains(.retry))
}

@Test func tierTwoRequiresExactHashAndNeverExecutesBeforeConfirmation() async throws {
    let rig = try await ApplicationTestRig.make()
    defer { rig.remove() }
    let submission = try await rig.service.submit("/save buy milk")
    let id = try #require(submission.runID)
    let hash = try #require(submission.planHash)
    #expect(submission.kind == .tier2ProposalReady)
    #expect((try #require(await rig.store.receipt(for: id))).status == .proposalReady)
    #expect(!(await rig.store.allEvents()).contains { $0.runID == id && $0.kind == .executionStarted })
    await #expect(throws: OmniCoreError.confirmationMismatch) {
        try await rig.service.confirm(runID: id, exactPlanHash: "edited")
    }
    try await rig.service.confirm(runID: id, exactPlanHash: hash)
    #expect((try await rig.service.waitForTerminal(runID: id)).state == .succeeded)
    #expect(try await rig.owner.contents(relativePath: "ledger/capture.txt") == "buy milk\n")
}

@Test func legacyProposalPersistsChosenInputForHistoryAndMapsNotesBackOnRetry() async throws {
    let rig = try await ApplicationTestRig.make(proposalSource: ChosenQuickLegacyProposalSource())
    defer { rig.remove() }

    let original = "/save explain concept"
    let chosen = "/qq explain concept"
    let note = OmniTextAnnotation(range: (original as NSString).range(of: "explain"), guidance: "Use simple terms")
    let submission = try await rig.service.submit(original, annotations: [note])
    let runID = try #require(submission.runID)
    #expect((await rig.store.receipt(for: runID))?.runtimeContext?.input?.rawText == original)
    try await rig.service.confirm(runID: runID, exactPlanHash: try #require(submission.planHash))
    _ = try await rig.service.waitForTerminal(runID: runID)

    let receipt = try #require(await rig.store.receipt(for: runID))
    let chosenContext = try #require(receipt.runtimeContext)
    #expect(receipt.commandText == original)
    #expect(chosenContext.input?.rawText == chosen)
    #expect(chosenContext.annotations.count == 1)
    #expect(chosenContext.annotations[0].range == (chosen as NSString).range(of: "explain"))
    let versions = try await rig.service.resultVersions(runID: runID)
    #expect(versions.first?.inputText == chosen)
    #expect(versions.first?.annotations == chosenContext.annotations)

    let failedOriginal = "/save [fixture:execution-failure] explain concept"
    let failedNote = OmniTextAnnotation(range: (failedOriginal as NSString).range(of: "explain"), guidance: "Keep it clear")
    let failedSubmission = try await rig.service.submit(failedOriginal, annotations: [failedNote])
    let failedRunID = try #require(failedSubmission.runID)
    try await rig.service.confirm(runID: failedRunID, exactPlanHash: try #require(failedSubmission.planHash))
    #expect((try await rig.service.waitForTerminal(runID: failedRunID)).state == .failed)
    let retry = try await rig.service.retry(runID: failedRunID)
    let retryID = try #require(retry.runID)
    #expect(retry.kind == .tier2ProposalReady)
    #expect(retry.annotationNotice == nil)
    let retryReceipt = try #require(await rig.store.receipt(for: retryID))
    #expect(retryReceipt.commandText == failedOriginal)
    #expect(retryReceipt.runtimeContext?.input?.rawText == failedOriginal)
    #expect(retryReceipt.runtimeContext?.annotations == [failedNote])
}

@Test func reconciliationPlansFromPersistedChosenLegacyInputAndNotes() async throws {
    let rig = try await ApplicationTestRig.make()
    defer { rig.remove() }
    let chosen = "/qq explain concept"
    let note = OmniTextAnnotation(range: (chosen as NSString).range(of: "explain"), guidance: "Use simple terms")
    let input = ModuleInput(canonicalText: chosen, rawText: chosen, payloadText: "explain concept")
    let runID = try await rig.store.submit(
        commandText: "/save explain concept",
        moduleID: "answer.quick",
        runtimeContext: RuntimeRunContext(input: input, annotations: [note])
    )
    try await rig.store.enqueue(runID)
    try await rig.store.beginExecution(runID)

    let recorder = ReconciliationPlanRecorder()
    let registry = try ModuleRegistry(rig.service.registry.moduleIDs.sorted().compactMap { moduleID in
        guard moduleID == "answer.quick" else { return rig.service.registry.factory(for: moduleID) }
        guard let descriptor = rig.service.registry.factory(for: moduleID)?.build().descriptor else { return nil }
        return AnyCommandModuleFactory(moduleID: moduleID) {
            RecordingReconciliationModule(descriptor: descriptor, recorder: recorder)
        }
    })
    let restartedService = OmniApplicationService(
        parser: rig.service.parser,
        registry: registry,
        proposalSource: FakeTier2ProposalSource(),
        store: rig.store
    )
    _ = try await restartedService.reconcileAfterRestart()
    let plan = try #require(await recorder.plan())
    #expect(plan.input.rawText == chosen)
    #expect(plan.annotations == [note])
    #expect((await rig.store.receipt(for: runID))?.status == .interrupted)
}

@Test func fakeNotificationBridgeLooksUpDurableTerminalRunAndFailsClosed() async throws {
    let rig = try await ApplicationTestRig.make()
    defer { rig.remove() }
    let denied = FakeRunNotificationBridge(store: rig.store, authorization: .denied)
    let submission = try await rig.service.submit("/todo notify")
    let id = try #require(submission.runID)
    _ = try await rig.service.waitForTerminal(runID: id)
    await #expect(throws: FakeNotificationError.notAuthorized) {
        _ = try await denied.publish(runID: id)
    }
    let allowed = FakeRunNotificationBridge(store: rig.store, authorization: .authorized)
    #expect(try await allowed.publish(runID: id) == "fixture://notification/\(id.rawValue)")
    #expect(await allowed.delivered() == [id])
}

@Test func cancellationAfterCompletedEffectLetsDurableOutcomeWin() async throws {
    let gate = CompletedEffectGate()
    let rig = try await ApplicationTestRig.make(completedEffectGate: gate)
    defer { rig.remove() }
    let submission = try await rig.service.submit("/todo already written")
    let id = try #require(submission.runID)
    await gate.waitUntilEffectCompleted()
    #expect(await rig.store.receipt(for: id)?.status == .running)
    #expect(try await rig.owner.contents(relativePath: "ledger/capture.txt") == "already written\n")

    let cancellation = Task { try await rig.service.cancel(runID: id) }
    for _ in 0..<100 {
        if await rig.store.receipt(for: id)?.cancellationRequested == true { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await rig.store.receipt(for: id)?.cancellationRequested == true)
    await gate.release()
    try await cancellation.value
    let receipt = try #require(await rig.store.receipt(for: id))
    #expect(receipt.status == .succeeded)
    let kinds = await rig.store.allEvents().filter { $0.runID == id }.map(\.kind)
    #expect(kinds.contains(.cancellationRequested))
    #expect(kinds.contains(.effectSucceeded))
    #expect(!kinds.contains(.cancelled))
}

@Test func shutdownDrainsAcknowledgedWorkAndRejectsNewSubmission() async throws {
    let rig = try await ApplicationTestRig.make()
    defer { rig.remove() }
    let submission = try await rig.service.submit("/todo [fixture:slow] stop for shutdown")
    let id = try #require(submission.runID)
    try await waitUntilRunning(rig.store, runID: id)

    let unresolved = await rig.service.shutdown(timeout: .milliseconds(300))

    #expect(unresolved.isEmpty)
    #expect((try #require(await rig.store.receipt(for: id))).status == .cancelled)
    await #expect(throws: OmniApplicationError.shutdownInProgress) {
        _ = try await rig.service.submit("/todo must not start")
    }
}

@Test func shutdownTimeoutRecordsUncertaintyWhenCompletedEffectCannotBeAcknowledged() async throws {
    let gate = CompletedEffectGate()
    let rig = try await ApplicationTestRig.make(completedEffectGate: gate)
    defer { rig.remove() }
    let submission = try await rig.service.submit("/todo effect completed before shutdown")
    let id = try #require(submission.runID)
    await gate.waitUntilEffectCompleted()
    #expect(try await rig.owner.contents(relativePath: "ledger/capture.txt") == "already written\n")

    let unresolved = await rig.service.shutdown(timeout: .milliseconds(20))
    let receipt = try #require(await rig.store.receipt(for: id))

    #expect(unresolved == [id])
    #expect(receipt.status == .interrupted)
    #expect(receipt.effectCertainty == .uncertain)
    #expect((await rig.store.allEvents()).contains { $0.runID == id && $0.kind == .effectUncertain })
    await gate.release()
}

@Test func queuedCancellationThatRacesIntoExecutionStillClaimsATerminalOutcome() async throws {
    let generator = CancellationGateProposalGenerator()
    let rig = try await ApplicationTestRig.make(proposalGenerator: generator)
    defer { rig.remove() }
    let submission = try await rig.service.submit("/todo [fixture:slow] cancellation race")
    let runID = try #require(submission.runID)

    let cancellation = Task { try await rig.service.cancel(runID: runID) }
    for _ in 0..<200 {
        if await generator.hasSeenCancellation() { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await generator.hasSeenCancellation())
    var executionStarted = false
    for _ in 0..<200 {
        if await rig.store.allEvents().contains(where: { $0.runID == runID && $0.kind == .executionStarted }) {
            executionStarted = true
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(executionStarted)
    await generator.releaseCancellation()
    try await cancellation.value

    let receipt = try #require(await rig.store.receipt(for: runID))
    #expect(receipt.status == .cancelled)
    #expect(receipt.cancellationRequested)
    let kinds = await rig.store.allEvents().filter { $0.runID == runID }.map(\.kind)
    #expect(kinds.contains(.cancellationRequested))
    #expect(kinds.contains(.cancelled))
}

@Test func invalidatingActiveProposalPersistsItsCancellationRecordBeforeExpiry() async throws {
    let generator = CancellationRecordProposalGenerator()
    let rig = try await ApplicationTestRig.make(proposalGenerator: generator)
    defer { rig.remove() }
    let submission = try await rig.service.submit("/todo revise this proposed work /todo then stop")
    let runID = try #require(submission.runID)
    let before = try #require(await rig.store.receipt(for: runID))
    let input = try #require(before.runtimeContext?.input)

    try await rig.service.invalidateProposal(runID: runID)

    let expired = try #require(await rig.store.receipt(for: runID))
    #expect(expired.status == .expired)
    #expect(expired.runtimeContext?.input == input)
    #expect(expired.runtimeContext?.modelRecords.last?.runID == runID.rawValue)
    #expect(expired.runtimeContext?.modelRecords.last?.attempts.last?.outcome == .cancelled)
    let events = await rig.store.allEvents().filter { $0.runID == runID }.map(\.kind)
    #expect(events.last == .expired)
    #expect(events.contains(.runtimeContextUpdated))
}

@Test func modulesWithNoRetryPolicyExposeNoRetryAndRejectProgrammaticRetry() async throws {
    let rig = try await ApplicationTestRig.make()
    defer { rig.remove() }
    let submission = try await rig.service.submit("/open [fixture:execution-failure] nowhere")
    let id = try #require(submission.runID)
    _ = try await rig.service.waitForTerminal(runID: id)
    let viewModel = try #require(await rig.service.resultViewModel(runID: id))
    #expect(!viewModel.actions.contains(.retry))
    await #expect(throws: OmniApplicationError.retryNotAllowed) {
        _ = try await rig.service.retry(runID: id)
    }
}

@Test func failedInferencePolicyExposesRetryAndCreatesANewLinkedRun() async throws {
    let rig = try await ApplicationTestRig.make()
    defer { rig.remove() }
    let submission = try await rig.service.submit("/qq [fixture:execution-failure] explain")
    let id = try #require(submission.runID)
    _ = try await rig.service.waitForTerminal(runID: id)
    #expect((try #require(await rig.service.resultViewModel(runID: id))).actions.contains(.retry))
    let retry = try await rig.service.retry(runID: id)
    let retryID = try #require(retry.runID)
    #expect(retryID != id)
    #expect((try #require(await rig.store.receipt(for: retryID))).retryOf == id)
}

@Test func durableTierTwoProposalCanBeReconstructedWithoutInMemoryProposalState() async throws {
    let envelope = FileManager.default.temporaryDirectory.appendingPathComponent("omni-proposal-restart-\(UUID().uuidString)", isDirectory: true)
    let root = envelope.appendingPathComponent("state", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: envelope) }

    let corpus = FrozenContractCorpus()
    let manifest = try corpus.manifest()
    let declarations = try corpus.moduleDeclarations().declarations
    let validatedRoot = try OmniDevelopmentRoot(validating: root, allowedRoot: envelope)
    let catalog = try FixtureModuleCatalog(manifest: manifest, declarations: declarations, developmentRoot: validatedRoot)
    let parser = OmniParser(manifest: manifest, references: try ReferenceRegistry([]))

    var firstStore: OmniRunStore? = try OmniRunStore(developmentRoot: root, allowedRoot: envelope)
    var firstService: OmniApplicationService? = OmniApplicationService(
        parser: parser,
        registry: catalog.registry,
        proposalSource: FakeTier2ProposalSource(),
        store: firstStore!
    )
    let submission = try await firstService!.submit("/save restart proposal")
    let id = try #require(submission.runID)
    let hash = try #require(submission.planHash)
    let durable = try #require(await firstStore!.receipt(for: id))
    #expect(durable.proposalCapabilities == ["append-ledger"])
    #expect(durable.proposalInput == "/save restart proposal")
    #expect(durable.proposalInputDigest != nil)
    firstService = nil
    firstStore = nil

    let secondStore = try OmniRunStore(developmentRoot: root, allowedRoot: envelope)
    let secondService = OmniApplicationService(
        parser: parser,
        registry: catalog.registry,
        proposalSource: FakeTier2ProposalSource(),
        store: secondStore
    )
    try await secondService.confirm(runID: id, exactPlanHash: hash)
    #expect((try await secondService.waitForTerminal(runID: id)).state == .succeeded)
}
