import Foundation
import OmniCore
import OmniRun

public enum ApplicationSubmissionKind: String, Sendable, Equatable {
    case disabled
    case referenceChoice
    case tier1Queued
    case tier2ProposalReady
    case tier2Proposing
}

public struct ApplicationSubmission: Sendable, Equatable {
    public let kind: ApplicationSubmissionKind
    public let intent: ParsedIntent
    public let runID: RunID?
    public let planHash: String?
    /// Non-fatal guidance loss that the route line should show to the user.
    public let annotationNotice: String?

    public init(kind: ApplicationSubmissionKind, intent: ParsedIntent, runID: RunID? = nil, planHash: String? = nil, annotationNotice: String? = nil) {
        self.kind = kind
        self.intent = intent
        self.runID = runID
        self.planHash = planHash
        self.annotationNotice = annotationNotice
    }
}

public enum OmniApplicationError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingRun
    case missingProposal
    case missingPlan
    case terminalWaitTimedOut
    case invalidRunID(String)
    case retryNotAllowed
    case shutdownInProgress
    case followUpUnavailable
    case followUpRequiresCompletedRun
    case invalidFollowUpSourceVersion
    case followUpAlreadyActive
    case unsupportedFollowUpOperation
    case emptyFollowUpSource
    case emptyCapture

    public var description: String {
        switch self {
        case .missingRun: "run does not exist"
        case .missingProposal: "run has no pending proposal"
        case .missingPlan: "run has no executable plan"
        case .terminalWaitTimedOut: "timed out waiting for a terminal receipt"
        case .invalidRunID(let value): "invalid run ID: \(value)"
        case .retryNotAllowed: "module retry policy does not permit a manual retry"
        case .shutdownInProgress: "application is shutting down and cannot accept new work"
        case .followUpUnavailable: "follow-up generation is not configured"
        case .followUpRequiresCompletedRun: "follow-up requires a completed run"
        case .invalidFollowUpSourceVersion: "selected result version does not exist"
        case .followUpAlreadyActive: "a follow-up is already active for this run"
        case .unsupportedFollowUpOperation: "visible text does not name a supported follow-up operation"
        case .emptyFollowUpSource: "follow-up needs edited source text"
        case .emptyCapture: "capture is empty"
        }
    }
}

/// Test and host orchestration seam used to coordinate the narrow window
/// between reserving a follow-up and durably admitting it.
public protocol FollowUpAdmissionHook: Sendable {
    func didReserve(runID: RunID, requestID: String) async
}

/// Application orchestration is the only layer allowed to join parsing, routing,
/// durability, execution handles, and result projection. Domain behavior remains
/// behind injected modules; this type contains no command-token branches.
public actor OmniApplicationService {
    public nonisolated let parser: OmniParser
    public nonisolated let registry: ModuleRegistry
    public nonisolated let store: OmniRunStore

    private let router: Tier1Router
    private let classifier = SubmissionClassifier()
    private let proposalSource: any Tier2ProposalSource
    let proposalGenerator: (any ProposalGenerating)?
    let followUpGenerator: (any FollowUpGenerating)?
    let followUpAdmissionHook: (any FollowUpAdmissionHook)?
    let versionedValidator: ProposalPlanValidator
    private let proposalValidator: Tier2PlanValidator
    private let executionTimeout: Duration
    let capabilityEnvironment: CapabilityEnvironment?
    var plans: [RunID: CommandPlan] = [:]
    var modules: [RunID: any CommandModule] = [:]
    private var proposals: [RunID: Tier2Proposal] = [:]
    private var handles: [RunID: any RunExecutionHandle] = [:]
    /// Phase 2 fake modules predate owner-operation handles. Keep their synthetic
    /// receipt boundary confined to the pure-fake profile; real adapters persist
    /// attempts and outcomes at the actual owner call boundary.
    private var fixtureEffectIDs: [RunID: String] = [:]
    private var executionTasks: [RunID: Task<Void, Never>] = [:]
    private var timeoutTasks: [RunID: Task<Void, Never>] = [:]
    var sequenceTasks: [RunID: Task<Void, Never>] = [:]
    var sequenceChildren: [RunID: RunID] = [:]
    var proposalTasks: [RunID: Task<Void, Never>] = [:]
    var followUpTasks: [RunID: FollowUpOwnership] = [:]
    var followUpCancellations: Set<RunID> = []
    var cancelledFollowUpRequestIDs: Set<String> = []
    var shuttingDown = false

    public init(
        parser: OmniParser,
        registry: ModuleRegistry,
        proposalSource: any Tier2ProposalSource,
        store: OmniRunStore,
        capabilityEnvironment: CapabilityEnvironment? = nil,
        proposalGenerator: (any ProposalGenerating)? = nil,
        followUpGenerator: (any FollowUpGenerating)? = nil,
        followUpAdmissionHook: (any FollowUpAdmissionHook)? = nil,
        executionTimeout: Duration = .seconds(30)
    ) {
        self.parser = parser
        self.registry = registry
        self.proposalSource = proposalSource
        self.store = store
        self.capabilityEnvironment = capabilityEnvironment
        self.proposalGenerator = proposalGenerator
        self.followUpGenerator = followUpGenerator
        self.followUpAdmissionHook = followUpAdmissionHook
        versionedValidator = ProposalPlanValidator(parser: parser, registry: registry)
        self.executionTimeout = executionTimeout
        router = Tier1Router(manifest: parser.manifest, registry: registry)
        proposalValidator = Tier2PlanValidator(registry: registry)
    }

    /// `modelSelection` is this invocation's explicit provider/profile choice.
    /// It is recorded with the run's input and expires with the generation; a
    /// retry or follow-up never inherits it.
    @discardableResult
    public func submit(
        _ visibleText: String,
        retryOf: RunID? = nil,
        modelSelection: ModelInvocationSelection? = nil,
        provenance: OmniRunProvenance? = nil,
        annotations: [OmniTextAnnotation] = [],
        annotationNotice: String? = nil,
        originRunID: RunID? = nil
    ) async throws -> ApplicationSubmission {
        guard !shuttingDown else { throw OmniApplicationError.shutdownInProgress }
        let intent = parser.parse(visibleText)
        let suppliedAnnotationCount = annotations.count
        let annotations = OmniAnnotationRanges.validated(annotations, in: visibleText)
        let annotationNotice: String? = if annotations.count < suppliedAnnotationCount {
            [annotationNotice, "Some notes could not be attached to this request."].compactMap { $0 }.joined(separator: " ")
        } else {
            annotationNotice
        }
        switch classifier.classify(intent) {
        case .disabled:
            return ApplicationSubmission(kind: .disabled, intent: intent)
        case .referenceChoice:
            return ApplicationSubmission(kind: .referenceChoice, intent: intent)
        case .tier1(let dispatchToken):
            let input = moduleInput(from: intent).with(modelSelection: modelSelection)
            return try await submitTier1(
                intent: intent, dispatchToken: dispatchToken, input: input,
                retryOf: retryOf, provenance: provenance, annotations: annotations,
                annotationNotice: annotationNotice, originRunID: originRunID
            )
        case .tier2:
            // An id is an address, never a request (D1): whatever surface
            // submits it (the pad, a note on it, the socket, a retry), an
            // id-shaped text never becomes a Tier 2 proposal, hit or miss.
            if OmniIDAddress(visibleText) != nil {
                return ApplicationSubmission(kind: .disabled, intent: intent)
            }
            if proposalGenerator != nil {
                return try await submitVersionedProposal(intent: intent, retryOf: retryOf, modelSelection: modelSelection, provenance: provenance, annotations: annotations, annotationNotice: annotationNotice, originRunID: originRunID)
            }
            // The proposal call may be slow, but the durable submitted event exists first.
            let runID = try await store.submit(
                commandText: intent.canonicalText,
                retryOf: retryOf,
                runtimeContext: RuntimeRunContext(
                    input: moduleInput(from: intent).with(modelSelection: modelSelection),
                    provenance: provenance,
                    annotations: annotations,
                    annotationNotice: annotationNotice,
                    originRunID: originRunID?.rawValue
                )
            )
            try await store.beginProposal(runID)
            do {
                let proposal = try await proposalSource.propose(for: intent)
                try proposalValidator.validate(proposal)
                guard let proposedModule = registry.factory(for: proposal.moduleID)?.build() else {
                    throw OmniCoreError.unknownModule(proposal.moduleID)
                }
                proposals[runID] = proposal
                try await store.markProposalReady(
                    runID,
                    moduleID: proposal.moduleID,
                    planHash: proposal.planHash,
                    capabilities: proposal.capabilities.map(\.rawValue),
                    input: proposal.input,
                    inputDigest: proposal.inputDigest,
                    retryPolicyProfile: proposedModule.descriptor.policies.retry.profile
                )
                return ApplicationSubmission(kind: .tier2ProposalReady, intent: intent, runID: runID, planHash: proposal.planHash, annotationNotice: annotationNotice)
            } catch {
                try? await store.fail(runID, message: "proposal failed: \(error)")
                throw error
            }
        }
    }

    /// Runs the deterministic `/g` route with a captured selection as literal
    /// search text. Parsing the selection would interpret slash-shaped words as
    /// Omni commands or modes, so only the fixed dispatch token is parsed.
    @discardableResult
    public func submitGoogleSearch(_ query: String, provenance: OmniRunProvenance? = nil) async throws -> ApplicationSubmission {
        guard !shuttingDown else { throw OmniApplicationError.shutdownInProgress }
        let intent = parser.parse("/g")
        let commandText = "/g " + query
        let input = ModuleInput(canonicalText: commandText, rawText: commandText, payloadText: query)
        return try await submitTier1(intent: intent, dispatchToken: "/g", input: input, provenance: provenance)
    }

    /// Admits an explicit capture through a fixed deterministic owner route.
    /// Only the fixed token is parsed, so slash commands inside the material
    /// remain literal note or link content.
    @discardableResult
    public func submitCapture(_ visibleText: String, provenance: OmniRunProvenance? = nil) async throws -> ApplicationSubmission {
        guard !shuttingDown else { throw OmniApplicationError.shutdownInProgress }
        guard let request = OmniCaptureRequest.classify(visibleText) else { throw OmniApplicationError.emptyCapture }
        let token = request.destination.dispatchToken
        let intent = parser.parse(token)
        let commandText = token + " " + request.payload
        let input = ModuleInput(canonicalText: commandText, rawText: commandText, payloadText: request.payload)
        return try await submitTier1(intent: intent, dispatchToken: token, input: input, provenance: provenance)
    }

    private func submitTier1(
        intent: ParsedIntent,
        dispatchToken: String,
        input: ModuleInput,
        retryOf: RunID? = nil,
        provenance: OmniRunProvenance? = nil,
        annotations: [OmniTextAnnotation] = [],
        annotationNotice: String? = nil,
        originRunID: RunID? = nil
    ) async throws -> ApplicationSubmission {
        let module = try router.module(for: dispatchToken)
        try module.validate(input: input)
        let plan = try module.makePlan(input: input).with(annotations: annotations).with(materialSource: provenance?.appName)
        let profile = capabilityEnvironment?.profile ?? .pureFake
        let allowedOperations = (capabilityEnvironment?.installedPolicy ?? []).filter {
            !plan.offline || !$0.mayUseNetwork
        }
        let runID = try await store.submit(
            commandText: input.canonicalText,
            retryOf: retryOf,
            moduleID: module.descriptor.moduleID,
            retryPolicyProfile: module.descriptor.policies.retry.profile,
            executionProfile: profile.rawValue,
            offline: plan.offline,
            allowedOperations: allowedOperations.map(\.rawValue).sorted(),
            runtimeContext: RuntimeRunContext(input: input, provenance: provenance, annotations: annotations, annotationNotice: annotationNotice, originRunID: originRunID?.rawValue)
        )
        plans[runID] = plan
        modules[runID] = module
        try await store.enqueue(runID)
        scheduleExecution(runID)
        return ApplicationSubmission(kind: .tier1Queued, intent: intent, runID: runID, annotationNotice: annotationNotice)
    }

    public func confirm(runID: RunID, exactPlanHash: String) async throws {
        guard !shuttingDown else { throw OmniApplicationError.shutdownInProgress }
        guard let receipt = await store.receipt(for: runID) else { throw OmniApplicationError.missingRun }
        if receipt.runtimeContext?.proposal != nil {
            try await confirmVersionedProposal(runID: runID, exactPlanHash: exactPlanHash)
            return
        }
        let proposal: Tier2Proposal
        if let pending = proposals[runID] {
            proposal = pending
        } else {
            let capabilities = receipt.proposalCapabilities.compactMap(Capability.init(rawValue:))
            guard let proposalInput = receipt.proposalInput else { throw OmniApplicationError.missingProposal }
            let reconstructed = Tier2Proposal(moduleID: receipt.moduleID ?? "", capabilities: capabilities, input: proposalInput)
            guard receipt.planHash == reconstructed.planHash,
                  receipt.proposalInputDigest == reconstructed.inputDigest,
                  capabilities.count == receipt.proposalCapabilities.count
            else { throw OmniApplicationError.missingProposal }
            proposal = reconstructed
            proposals[runID] = reconstructed
        }
        try proposalValidator.confirm(proposal, exactPlanHash: exactPlanHash)
        guard let factory = registry.factory(for: proposal.moduleID) else { throw OmniCoreError.unknownModule(proposal.moduleID) }
        let module = factory.build()
        let proposedIntent = parser.parse(proposal.input)
        let input = moduleInput(from: proposedIntent)
        try module.validate(input: input)
        let transferred = OmniAnnotationProjection.remap(
            receipt.runtimeContext?.annotations ?? [],
            fromRawText: receipt.runtimeContext?.input?.rawText ?? receipt.commandText,
            toRawText: input.rawText
        )
        let plan = try module.makePlan(input: input).with(annotations: transferred.annotations)
        guard plan.moduleID == proposal.moduleID, plan.capabilitySet == Set(proposal.capabilities) else {
            throw OmniCoreError.invalidProposal
        }
        modules[runID] = module
        plans[runID] = plan
        // The proposal's chosen input is the request actually executed. Save
        // its text and remapped note coordinates before the run can start, so
        // history and restart reconciliation use the same plan as execution.
        var context = receipt.runtimeContext ?? RuntimeRunContext()
        context.input = input
        context.annotations = transferred.annotations
        if transferred.unmappedCount > 0 {
            context.annotationNotice = "\(transferred.unmappedCount) note\(transferred.unmappedCount == 1 ? "" : "s") could not be carried into the chosen proposal."
        }
        try await store.confirmProposal(runID, runtimeContext: context)
        try await store.enqueue(runID)
        scheduleExecution(runID)
    }

    public func cancel(runID: RunID) async throws {
        guard let receipt = await store.receipt(for: runID) else { throw OmniApplicationError.missingRun }
        guard !receipt.status.isTerminal else { return }
        if sequenceTasks[runID] != nil {
            try await cancelSequence(runID: runID)
            return
        }

        // Write the cancellation intent before awaiting a provider or task. A
        // queued execution may otherwise start while this actor is suspended.
        if !receipt.status.isTerminal, !receipt.cancellationRequested {
            do {
                try await store.requestCancellation(runID)
            } catch {
                if (await store.receipt(for: runID))?.status.isTerminal != true { throw error }
            }
        }

        // Proposal generators are run-scoped. Ask the configured generator to
        // stop this ID before taking the terminal transition, even for a
        // Tier 1 run: a shared generator may have a run-bound inference task
        // pending while the execution scheduler advances.
        if proposalGenerator != nil {
            await proposalGenerator?.cancel(runID: runID.rawValue)
            try await persistProposalModelExecutionRecord(runID: runID)
        }
        if proposalTasks[runID] != nil {
            proposalTasks.removeValue(forKey: runID)?.cancel()
        }

        // `cancelBeforeExecution` is the atomic terminal claim for an idle
        // run. If startExecution wins the store race, re-read and cancel its
        // handle instead; never leave a requested cancellation on a running
        // receipt without an owner of the terminal transition.
        while let current = await store.receipt(for: runID) {
            if current.status.isTerminal { return }
            if [.submitted, .queued, .proposing, .proposalReady, .confirmed].contains(current.status) {
                do {
                    try await store.cancelBeforeExecution(runID)
                    return
                } catch {
                    if let latest = await store.receipt(for: runID), latest.status == .running { continue }
                    if (await store.receipt(for: runID))?.status.isTerminal == true { return }
                    throw error
                }
            }
            if current.status == .running {
                try await requestCancellation(runID: runID, source: "user")
                return
            }
        }
        throw OmniApplicationError.missingRun
    }

    public func timeout(runID: RunID) async throws {
        try await requestCancellation(runID: runID, source: "timeout")
    }

    @discardableResult
    public func retry(runID: RunID) async throws -> ApplicationSubmission {
        guard let receipt = await store.receipt(for: runID) else { throw OmniApplicationError.missingRun }
        guard receipt.status.isTerminal else { throw OmniApplicationError.retryNotAllowed }
        guard receipt.runtimeContext?.proposal == nil else { throw OmniApplicationError.retryNotAllowed }
        switch receipt.retryPolicyProfile {
        case "inference": break
        case "mutation":
            guard try await store.automaticRetryIsAllowed(runID) else {
                throw OmniApplicationError.retryNotAllowed
            }
        default:
            throw OmniApplicationError.retryNotAllowed
        }
        // All mutation retries are new runs. No automatic retry is attempted here.
        let savedAnnotations = receipt.runtimeContext?.annotations ?? []
        // A draft picked from a stance keeps its link through retries (D6);
        // its request notes go only when that stance run is no longer on record.
        let origin = receipt.runtimeContext?.originRunID.flatMap(RunID.init(rawValue:))
        let originFound: Bool = if let origin { await store.receipt(for: origin) != nil } else { false }
        let droppedRequestNotes = !originFound && savedAnnotations.contains(where: \.isRequestScoped)
        if receipt.proposalInput != nil {
            // A legacy proposal's stored input is the chosen execution input.
            // A retry still returns to the original Tier 2 request, which
            // requires a new choice. Remap notes back only when unambiguous.
            let transferred = OmniAnnotationProjection.remap(
                savedAnnotations,
                fromRawText: receipt.runtimeContext?.input?.rawText ?? receipt.commandText,
                toRawText: receipt.commandText
            )
            return try await submit(
                receipt.commandText,
                retryOf: runID,
                provenance: receipt.runtimeContext?.provenance,
                annotations: transferred.annotations,
                annotationNotice: transferred.unmappedCount > 0
                    ? "\(transferred.unmappedCount) note\(transferred.unmappedCount == 1 ? "" : "s") could not be carried into this retry."
                    : nil,
                originRunID: origin
            )
        }
        if !savedAnnotations.isEmpty,
           let rawText = receipt.runtimeContext?.input?.rawText,
           parser.parse(rawText).canonicalText == receipt.commandText,
           OmniAnnotationRanges.validated(savedAnnotations, in: rawText).count == savedAnnotations.count {
            return try await submit(
                rawText,
                retryOf: runID,
                provenance: receipt.runtimeContext?.provenance,
                annotations: droppedRequestNotes ? savedAnnotations.filter { !$0.isRequestScoped } : savedAnnotations,
                annotationNotice: droppedRequestNotes ? "The chosen position could not be carried into this retry." : nil,
                originRunID: origin
            )
        }
        // Span notes cannot follow the canonical text. A request note (the
        // chosen position) needs no span: it stays while its stance run is
        // still on record, and is dropped only when that run is gone.
        let requestNotes = originFound ? savedAnnotations.filter(\.isRequestScoped) : []
        let dropped = savedAnnotations.count - requestNotes.count
        return try await submit(
            receipt.commandText,
            retryOf: runID,
            provenance: receipt.runtimeContext?.provenance,
            annotations: requestNotes,
            annotationNotice: dropped == 0 ? nil : "Notes could not be carried into this retry.",
            originRunID: origin
        )
    }

    public func reconcileAfterRestart() async throws -> [RunID] {
        try await reconcilePersistedFollowUpsAfterRestart()
        let incomplete = await store.runsNeedingOwnerReconciliation().map(\.id)
        for runID in incomplete {
            // Recovery may have persisted proof immediately before the prior
            // process stopped, without yet writing the terminal run result.
            if try await store.completeOwnerRecovery(runID) { continue }
            if let current = await store.receipt(for: runID), let context = current.runtimeContext, context.proposal != nil {
                if current.status == .proposalReady { continue }
                continue
            }
            guard let receipt = await store.receipt(for: runID),
                  let moduleID = receipt.moduleID,
                  let module = registry.factory(for: moduleID)?.build()
            else {
                try await store.reconcileIncompleteRun(runID)
                continue
            }
            let intent = parser.parse(receipt.commandText)
            let input = receipt.runtimeContext?.input ?? moduleInput(from: intent)
            do {
                let plan = try module.makePlan(input: input).with(annotations: receipt.runtimeContext?.annotations ?? [])
                switch await module.reconcile(runID: runID.rawValue, plan: plan) {
                case .completed(let result):
                    if try await store.completeOwnerRecovery(runID, result: result) { continue }
                    if receipt.status.isTerminal == false {
                        try await store.succeed(
                            runID,
                            summary: result.summary,
                            artifactReference: result.artifactReference,
                            resultActions: result.allowedActions.map(\.rawValue)
                        )
                    }
                case .interrupted(let certainty):
                    try await store.markInterrupted(
                        runID,
                        effectCertainty: certainty == .certain ? .certain : .uncertain,
                        message: "owner reconciliation did not prove completion",
                        recordGenericUncertainty: false
                    )
                case .unavailable:
                    try await store.reconcileIncompleteRun(runID)
                }
            } catch {
                try await store.reconcileIncompleteRun(runID, message: "reconciliation plan unavailable: \(error)")
            }
        }
        for runID in incomplete {
            if let receipt = await store.receipt(for: runID), receipt.runtimeContext?.proposal != nil, receipt.status != .proposalReady {
                try await recoverSequenceEvidence(runID: runID)
            }
        }
        return incomplete
    }

    /// Stops accepting work, gives each active run a run-bound cancellation
    /// opportunity, then records unresolved work as uncertain. The returned
    /// IDs are the receipts that require owner reconciliation after shutdown.
    /// It never assumes an owner effect did not happen merely because the host
    /// could not obtain an acknowledgement within the supplied bound.
    public func shutdown(timeout: Duration = .seconds(5)) async -> [RunID] {
        shuttingDown = true
        for runID in Array(followUpTasks.keys) {
            try? await cancelFollowUp(runID: runID)
        }
        let requested = await store.activeRuns().map(\.id)
        for runID in requested {
            Task { [weak self] in
                try? await self?.cancel(runID: runID)
            }
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await store.activeRuns().isEmpty {
                return await unresolvedShutdownRunIDs(from: requested)
            }
            let remaining = clock.now.duration(to: deadline)
            try? await Task.sleep(for: min(remaining, .milliseconds(10)))
        }

        let stillActive = await store.activeRuns().map(\.id)
        for runID in stillActive {
            proposalTasks.removeValue(forKey: runID)?.cancel()
            sequenceTasks.removeValue(forKey: runID)?.cancel()
            timeoutTasks.removeValue(forKey: runID)?.cancel()
            executionTasks.removeValue(forKey: runID)?.cancel()
            if let receipt = await store.receipt(for: runID), !receipt.status.isTerminal {
                try? await store.markInterrupted(
                    runID,
                    effectCertainty: .uncertain,
                    message: "application shutdown timed out before owner acknowledgement"
                )
            }
        }
        return await unresolvedShutdownRunIDs(from: requested)
    }

    public func applyRetention(runID: RunID) async throws {
        try await store.applyRetention(to: runID)
    }

    public func receipt(runID: RunID) async -> OmniCore.RunReceipt? {
        guard let receipt = await store.receipt(for: runID) else { return nil }
        return Self.project(receipt)
    }

    public func resultViewModel(runID: RunID) async -> ResultViewModel? {
        guard let receipt = await store.receipt(for: runID),
              let projected = Self.project(receipt)
        else { return nil }
        return ResultViewModel(
            receipt: projected,
            actions: await actions(for: receipt),
            commandTitle: commandTitle(for: receipt),
            submittedAt: receipt.submittedAt,
            followUpKind: receipt.runtimeContext?.followUpState?.kind,
            followUpMessage: receipt.runtimeContext?.followUpState?.message,
            versionCount: receipt.runtimeContext?.resultVersions.count ?? 0,
            provenance: receipt.runtimeContext?.provenance,
            annotations: receipt.runtimeContext?.annotations ?? [],
            annotationNotice: receipt.runtimeContext?.annotationNotice,
            originRunID: receipt.runtimeContext?.originRunID,
            find: receipt.runtimeContext?.find
        )
    }

    public func reconstructRecentResults(limit: Int = Int.max) async throws -> [ResultViewModel] {
        let snapshot = try await reconstructRecentResultsIfChanged(since: nil, limit: limit)
        return snapshot?.results ?? []
    }

    /// The revision belongs to the exact receipt snapshot returned here. A
    /// mutation during projection leaves this token stale, so the next poll
    /// still sees and renders the newer state.
    public func reconstructRecentResultsIfChanged(since revision: UInt64?, limit: Int = Int.max) async throws -> (revision: UInt64, results: [ResultViewModel])? {
        guard let snapshot = try await store.indexedRecentRunsIfChanged(since: revision, limit: limit) else { return nil }
        var results: [ResultViewModel] = []
        for receipt in snapshot.receipts {
            guard receipt.runtimeContext?.parentRunID == nil else { continue }
            guard let projected = Self.project(receipt) else { continue }
            results.append(ResultViewModel(
            receipt: projected,
            actions: await actions(for: receipt),
            commandTitle: commandTitle(for: receipt),
            submittedAt: receipt.submittedAt,
            followUpKind: receipt.runtimeContext?.followUpState?.kind,
            followUpMessage: receipt.runtimeContext?.followUpState?.message,
            versionCount: receipt.runtimeContext?.resultVersions.count ?? 0,
            provenance: receipt.runtimeContext?.provenance,
            annotations: receipt.runtimeContext?.annotations ?? [],
            annotationNotice: receipt.runtimeContext?.annotationNotice,
            originRunID: receipt.runtimeContext?.originRunID,
            find: receipt.runtimeContext?.find
        ))
        }
        return (snapshot.revision, results)
    }

    private func commandTitle(for receipt: OmniRun.RunReceipt) -> String? {
        parser.manifest.commands.first { $0.moduleID == receipt.moduleID && ($0.role == .primary || $0.role == .settings) }?.token
    }

    public func waitForTerminal(runID: RunID, timeout: Duration = .seconds(10)) async throws -> OmniCore.RunReceipt {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let durable = await store.receipt(for: runID), durable.status.isTerminal,
               let projected = Self.project(durable) {
                return projected
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw OmniApplicationError.terminalWaitTimedOut
    }

    func scheduleExecution(_ runID: RunID) {
        executionTasks[runID] = Task { [weak self] in
            await self?.startExecution(runID)
        }
    }

    private func startExecution(_ runID: RunID) async {
        guard !shuttingDown else { return }
        guard let current = await store.receipt(for: runID), !current.status.isTerminal else { return }
        guard let plan = plans[runID], let module = modules[runID] else {
            try? await store.fail(runID, message: OmniApplicationError.missingPlan.description)
            return
        }
        do {
            try await store.beginExecution(runID)
            // Cancellation can become durable between the queued snapshot and
            // beginExecution. Claim its terminal state before starting an
            // owner or inference handle.
            if (await store.receipt(for: runID))?.cancellationRequested == true {
                try await store.acknowledgeCancellation(
                    runID,
                    acknowledgement: OmniRun.CancellationAcknowledgement(
                        priorRequestObserved: true,
                        executionStoppedAndReaped: true,
                        ownerAcknowledged: true,
                        effectCertainty: .certain
                    )
                )
                clearExecution(runID)
                return
            }
            if plan.ownerOperation == nil, !plan.capabilitySet.isEmpty, module.descriptor.execution != .modelBacked {
                let effectID = "module:\(plan.moduleID):\(runID.rawValue)"
                fixtureEffectIDs[runID] = effectID
                try await store.recordEffectAttempt(
                    runID,
                    effectID: effectID,
                    adapterID: "fixture.\(plan.moduleID)",
                    operationID: "execute",
                    idempotencyKey: nil,
                    idempotencyProven: false
                )
            }
            let broker = if let capabilityEnvironment {
                CapabilityBroker(declared: plan.capabilitySet, environment: capabilityEnvironment, offline: plan.offline)
            } else {
                CapabilityBroker(declared: plan.capabilitySet)
            }
            let handle = try await module.start(plan: plan, capabilities: broker, runID: runID.rawValue)
            guard handle.runID == runID.rawValue else { throw OmniApplicationError.invalidRunID(handle.runID) }
            handles[runID] = handle
            executionTasks[runID] = Task { [weak self] in
                let outcome = await handle.value()
                await self?.complete(runID: runID, outcome: outcome)
            }
            timeoutTasks[runID] = Task { [weak self, executionTimeout] in
                do {
                    try await Task.sleep(for: executionTimeout)
                    try await self?.timeout(runID: runID)
                } catch {
                    // Normal completion cancels the watchdog.
                }
            }
            // A cancellation may arrive while module.start is suspended. Now
            // that a handle exists, make this invocation own its durable
            // acknowledgement rather than relying on a queued-path snapshot.
            if (await store.receipt(for: runID))?.cancellationRequested == true {
                try await requestCancellation(runID: runID, source: "user")
            }
        } catch {
            if let effectID = fixtureEffectIDs[runID] {
                try? await store.recordEffectOutcome(runID, effectID: effectID, outcome: .failed, certainty: .certain)
            }
            try? await store.fail(runID, message: "execution start failed: \(error)")
            clearExecution(runID)
        }
    }

    private func complete(runID: RunID, outcome: ModuleExecutionOutcome) async {
        await finalize(runID: runID, outcome: outcome, permitMissedCancellationOutcome: false)
    }

    private func finalize(
        runID: RunID,
        outcome: ModuleExecutionOutcome,
        permitMissedCancellationOutcome: Bool
    ) async {
        guard let receipt = await store.receipt(for: runID), !receipt.status.isTerminal else {
            clearExecution(runID)
            return
        }
        // Once cancellation is durable, only the run-bound acknowledgement may
        // choose cancelled versus interrupted/effect-uncertain.
        guard permitMissedCancellationOutcome || !receipt.cancellationRequested else { return }
        var context = receipt.runtimeContext ?? RuntimeRunContext()
        if let record = await handles[runID]?.modelExecutionRecord() {
            context.modelRecords = [record]
            try? await store.updateRuntimeContext(runID, context: context)
        }
        switch outcome {
        case .succeeded(let result):
            context.fullText = result.fullText
            if let record = result.modelRecord { context.modelRecords = [record] }
            context.find = result.find
            // A `/find` picker is a list of rows, not a draft: no result
            // version, so no follow-up composer (D2), whatever tier ran.
            if context.resultVersions.isEmpty, result.find == nil, modules[runID]?.descriptor.execution == .modelBacked {
                context.resultVersions = [OmniResultVersion(
                    number: 1,
                    inputText: context.input?.rawText ?? receipt.commandText,
                    resultText: result.fullText ?? result.summary,
                    operation: .initial,
                    createdAt: Date(),
                    annotations: context.annotations
                )]
            }
            if let effectID = fixtureEffectIDs[runID] {
                try? await store.recordEffectOutcome(runID, effectID: effectID, outcome: .succeeded, certainty: .certain)
            }
            try? await store.succeed(
                runID,
                summary: result.summary,
                artifactReference: result.artifactReference,
                resultActions: result.allowedActions.map(\.rawValue),
                runtimeContext: context
            )
        case .failed(let summary):
            if let effectID = fixtureEffectIDs[runID] {
                try? await store.recordEffectOutcome(runID, effectID: effectID, outcome: .failed, certainty: .certain)
            }
            try? await store.fail(runID, message: summary)
        case .interrupted(let certainty):
            let isFixtureExecution = plans[runID]?.ownerOperation == nil
            if let effectID = fixtureEffectIDs[runID] {
                try? await store.recordEffectOutcome(
                    runID,
                    effectID: effectID,
                    outcome: .unknown,
                    certainty: certainty == .certain ? .certain : .uncertain
                )
            }
            try? await store.markInterrupted(
                runID,
                effectCertainty: certainty == .certain ? .certain : .uncertain,
                message: isFixtureExecution ? "fixture execution interrupted" : "owner execution interrupted",
                recordGenericUncertainty: isFixtureExecution
            )
        }
        clearExecution(runID)
    }

    private func requestCancellation(runID: RunID, source: String) async throws {
        var selectedHandle = handles[runID]
        if selectedHandle == nil {
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(1))
                if let handle = handles[runID] {
                    selectedHandle = handle
                    break
                }
            }
        }
        guard let handle = selectedHandle else {
            if (await store.receipt(for: runID))?.status.isTerminal == true {
                clearExecution(runID)
                return
            }
            throw OmniApplicationError.missingRun
        }
        let receipt = await store.receipt(for: runID)
        if receipt?.cancellationRequested != true {
            try await store.requestCancellation(runID, source: source)
        }
        let acknowledgement = await handle.requestCancellation()
        if let record = await handle.modelExecutionRecord(), let receipt = await store.receipt(for: runID) {
            var context = receipt.runtimeContext ?? RuntimeRunContext()
            context.modelRecords = [record]
            try await store.updateRuntimeContext(runID, context: context)
        }
        guard let current = await store.receipt(for: runID), !current.status.isTerminal else {
            clearExecution(runID)
            return
        }
        if !acknowledgement.requestObserved {
            let completedOutcome = await handle.value()
            await finalize(runID: runID, outcome: completedOutcome, permitMissedCancellationOutcome: true)
            return
        }
        do {
            try await store.acknowledgeCancellation(
                runID,
                acknowledgement: OmniRun.CancellationAcknowledgement(
                    priorRequestObserved: acknowledgement.requestObserved,
                    executionStoppedAndReaped: acknowledgement.taskOrProcessStopped,
                    ownerAcknowledged: acknowledgement.ownerAcknowledged,
                    effectCertainty: acknowledgement.effectCertainty == .certain ? .certain : .uncertain
                )
            )
        } catch {
            // The start path and explicit cancellation can race to the same
            // run-bound acknowledgement. A terminal receipt already owns the
            // outcome; only a still-active run makes this an error.
            if (await store.receipt(for: runID))?.status.isTerminal != true { throw error }
        }
        clearExecution(runID)
    }

    private func clearExecution(_ runID: RunID) {
        timeoutTasks.removeValue(forKey: runID)?.cancel()
        executionTasks.removeValue(forKey: runID)?.cancel()
        handles.removeValue(forKey: runID)
        fixtureEffectIDs.removeValue(forKey: runID)
        plans.removeValue(forKey: runID)
        modules.removeValue(forKey: runID)
    }

    private func unresolvedShutdownRunIDs(from requested: [RunID]) async -> [RunID] {
        var unresolved: [RunID] = []
        for runID in requested {
            if (await store.receipt(for: runID))?.effectCertainty == .uncertain {
                unresolved.append(runID)
            }
        }
        return unresolved
    }

    private func pinnedReferences(in intent: ParsedIntent) -> [PinnedReference] {
        intent.references.compactMap { resolution in
            guard case .binding(let binding) = resolution else { return nil }
            return binding
        }
    }

    func moduleInput(from intent: ParsedIntent) -> ModuleInput {
        ModuleInput(
            canonicalText: intent.canonicalText,
            rawText: intent.rawText,
            payloadText: SlashTokenSyntax.payloadText(from: intent.rawText),
            modes: Set(intent.modes),
            references: pinnedReferences(in: intent),
            modifiers: Set(intent.modifiers),
            markers: intent.markers,
            tokenValues: intent.tokenValues
        )
    }

    func actions(for receipt: OmniRun.RunReceipt) async -> [ResultAction] {
        if receipt.runtimeContext?.proposal != nil && receipt.status.isTerminal {
            return [.expand, .edit, .dismiss]
        }
        let persisted = receipt.resultActions.compactMap(ResultAction.init(rawValue:))
        if !persisted.isEmpty { return persisted }
        return switch receipt.status {
        case .proposalReady: [.confirm, .edit, .dismiss]
        case .running, .queued, .submitted, .confirmed: [.cancel, .dismiss]
        case .failed, .interrupted:
            if receipt.retryPolicyProfile == "inference" {
                [.retry, .dismiss]
            } else if receipt.retryPolicyProfile == "mutation",
                      (try? await store.automaticRetryIsAllowed(receipt.id)) == true {
                [.retry, .dismiss]
            } else {
                [.dismiss]
            }
        case .succeeded: [.dismiss]
        case .cancelled: [.dismiss]
        case .proposing: [.dismiss]
        case .dismissed, .expired: []
        }
    }

    static func project(_ receipt: OmniRun.RunReceipt) -> OmniCore.RunReceipt? {
        let state: RunPresentationState
        switch receipt.status {
        case .submitted, .queued: state = .queued
        case .running: state = .running
        case .succeeded: state = .succeeded
        case .failed: state = .failed
        case .cancelled: state = .cancelled
        case .interrupted: state = .interrupted
        case .proposing: state = .proposing
        case .proposalReady: state = .proposalReady
        case .confirmed: state = .confirmed
        case .dismissed, .expired: return nil
        }
        return OmniCore.RunReceipt(
            runID: receipt.id.rawValue,
            canonicalText: receipt.commandText,
            moduleID: receipt.moduleID,
            state: state,
            summary: receipt.summary ?? state.rawValue,
            artifactReference: receipt.artifactReference,
            executionProfile: receipt.executionProfile,
            offline: receipt.offline,
            effectDisposition: receipt.effects?.first.map {
                "\($0.operationID ?? "effect") · \($0.status) · \($0.reconciliationDisposition ?? "unreconciled") · \($0.retrySafetyReason ?? "retry safety unavailable")"
            },
            fullText: receipt.runtimeContext?.fullText,
            modelRecord: receipt.runtimeContext?.modelRecords.last,
            alternatives: receipt.runtimeContext?.proposal?.alternatives.map {
                ProposalAlternativeDisplay(id: $0.id, title: $0.title, steps: $0.steps.map { $0.input.canonicalText }, planHash: $0.planHash)
            }
        )
    }
}
