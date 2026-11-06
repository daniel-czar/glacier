import Foundation
import OmniCore
import OmniRun

extension OmniApplicationService {
    func authority(for intent: ParsedIntent) -> ProposalAuthoritySnapshot {
        versionedValidator.makeAuthoritySnapshot(
            allowedCapabilities: Set(parser.manifest.commands.flatMap(\.capabilities)),
            allowedOwnerOperations: capabilityEnvironment?.installedPolicy ?? Set(OwnerOperation.allCases),
            offline: intent.modes.contains("/offline")
        )
    }

    func submitVersionedProposal(
        intent: ParsedIntent,
        retryOf: RunID?,
        modelSelection: ModelInvocationSelection? = nil,
        provenance: OmniRunProvenance? = nil,
        annotations: [OmniTextAnnotation] = [],
        annotationNotice: String? = nil,
        originRunID: RunID? = nil
    ) async throws -> ApplicationSubmission {
        // The link to a stance run is stored context only; the proposal
        // model's inputs are unchanged.
        let runID = try await store.submit(
            commandText: intent.canonicalText,
            retryOf: retryOf,
            executionProfile: (capabilityEnvironment?.profile ?? .pureFake).rawValue,
            offline: intent.modes.contains("/offline"),
            runtimeContext: RuntimeRunContext(input: moduleInput(from: intent).with(modelSelection: modelSelection), provenance: provenance, annotations: annotations, annotationNotice: annotationNotice, originRunID: originRunID?.rawValue)
        )
        try await store.beginProposal(runID)
        proposalTasks[runID] = Task { [weak self] in
            await self?.generateProposal(intent: intent, runID: runID, modelSelection: modelSelection)
        }
        return ApplicationSubmission(kind: .tier2Proposing, intent: intent, runID: runID, annotationNotice: annotationNotice)
    }

    private func generateProposal(intent: ParsedIntent, runID: RunID, modelSelection: ModelInvocationSelection?) async {
        defer { proposalTasks.removeValue(forKey: runID) }
        do {
            guard let proposalGenerator else { throw OmniApplicationError.missingProposal }
            let generated = try await proposalGenerator.generate(intent: intent, runID: runID.rawValue, modelSelection: modelSelection)
            guard !Task.isCancelled else { return }
            guard let receipt = await store.receipt(for: runID), receipt.status == .proposing else { return }
            var context = receipt.runtimeContext ?? RuntimeRunContext(input: moduleInput(from: intent))
            if let record = generated.modelRecord { context.modelRecords = [record] }
            // Persist attempts even if structural validation fails.
            try await store.updateRuntimeContext(runID, context: context)
            let envelope = try versionedValidator.decodeModelProposal(generated.json, for: intent, authority: authority(for: intent), now: Date())
            context.proposal = envelope
            try await store.markProposalReady(runID, planHash: envelope.alternatives.first?.planHash, runtimeContext: context)
        } catch {
            try? await persistProposalModelExecutionRecord(runID: runID)
            if !Task.isCancelled,
               let receipt = await store.receipt(for: runID), !receipt.status.isTerminal, !receipt.cancellationRequested {
                try? await store.fail(runID, message: "Unable to propose safely: \(error)")
            }
        }
    }

    func confirmVersionedProposal(runID: RunID, exactPlanHash: String) async throws {
        guard let receipt = await store.receipt(for: runID), receipt.status == .proposalReady,
              var context = receipt.runtimeContext, let envelope = context.proposal,
              context.approvedPlanHash == nil
        else { throw OmniCoreError.confirmationMismatch }
        let intent = parser.parse(envelope.rawText)
        let selected = try versionedValidator.confirm(envelope: envelope, exactPlanHash: exactPlanHash, authority: authority(for: intent), now: Date())
        context.approvedPlanHash = selected.planHash
        // One serialized transition is the sole approval consumption point.
        try await store.confirmProposal(runID, exactPlanHash: selected.planHash, runtimeContext: context)
        try await store.enqueue(runID)
        sequenceTasks[runID] = Task { [weak self] in
            await self?.executeSequence(runID: runID, alternative: selected)
        }
    }

    public func invalidateProposal(runID: RunID) async throws {
        guard let receipt = await store.receipt(for: runID) else { throw OmniApplicationError.missingRun }
        if receipt.status == .proposalReady || receipt.status == .proposing {
            // Cancel the supervisor first so a generator that observes its
            // cancellation cannot race this expiry into a failure or a ready
            // proposal. The generator returns its run-bound record below.
            proposalTasks.removeValue(forKey: runID)?.cancel()
            await proposalGenerator?.cancel(runID: runID.rawValue)
            try await persistProposalModelExecutionRecord(runID: runID)
            if let latest = await store.receipt(for: runID),
               latest.status == .proposalReady || latest.status == .proposing {
                try await store.expire(runID)
            }
        }
    }

    /// Records provider cancellation/failure metadata against the latest
    /// durable context so proposal, approval, and child-sequence evidence is
    /// never replaced by a stale snapshot from before an actor suspension.
    func persistProposalModelExecutionRecord(runID: RunID) async throws {
        guard let record = await proposalGenerator?.modelExecutionRecord(runID: runID.rawValue),
              let receipt = await store.receipt(for: runID), !receipt.status.isTerminal
        else { return }
        var context = receipt.runtimeContext ?? RuntimeRunContext()
        context.modelRecords = [record]
        try await store.updateRuntimeContext(runID, context: context)
    }

    public func waitForSettlement(runID: RunID, timeout: Duration = .seconds(180)) async throws -> OmniCore.RunReceipt {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let receipt = await store.receipt(for: runID),
               receipt.status.isTerminal || receipt.status == .proposalReady,
               let projection = Self.project(receipt) { return projection }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw OmniApplicationError.terminalWaitTimedOut
    }

    private func executeSequence(runID: RunID, alternative: ValidatedProposalAlternative) async {
        defer {
            sequenceTasks.removeValue(forKey: runID)
            sequenceChildren.removeValue(forKey: runID)
        }
        do {
            guard !shuttingDown else { return }
            try await store.beginExecution(runID)
            guard let original = await store.receipt(for: runID),
                  let originalContext = original.runtimeContext
            else { return }
            let sourceText = originalContext.input?.rawText ?? original.commandText
            let transfers = alternative.steps.map { step in
                OmniAnnotationProjection.remap(
                    originalContext.annotations,
                    fromRawText: sourceText,
                    toRawText: step.input.rawText
                )
            }
            let transferredIDs = Set(transfers.flatMap { $0.annotations.map(\.id) })
            let omittedCount = originalContext.annotations.filter { !transferredIDs.contains($0.id) }.count
            let annotationNotice = omittedCount > 0
                ? "\(omittedCount) note\(omittedCount == 1 ? "" : "s") could not be carried into the chosen proposal."
                : nil
            if let annotationNotice {
                var context = originalContext
                context.annotationNotice = annotationNotice
                try await store.updateRuntimeContext(runID, context: context)
            }
            for (index, step) in alternative.steps.enumerated() {
                guard !Task.isCancelled, !shuttingDown, let parent = await store.receipt(for: runID), !parent.status.isTerminal, !parent.cancellationRequested,
                      var context = parent.runtimeContext, context.approvedPlanHash == alternative.planHash
                else { return }
                guard let module = registry.factory(for: step.moduleID)?.build() else { throw OmniCoreError.unknownModule(step.moduleID) }
                let transferred = transfers[index]
                let childAnnotationNotice = transferred.unmappedCount > 0
                    ? "\(transferred.unmappedCount) note\(transferred.unmappedCount == 1 ? "" : "s") from the original request could not be carried into this step."
                    : nil
                let plan = try module.makePlan(input: step.input).with(annotations: transferred.annotations)
                guard plan.capabilitySet == Set(step.capabilities), plan.ownerOperation == step.ownerOperation,
                      plan.offline == step.offline else { throw OmniCoreError.invalidProposal }
                // A separate durable ID per step prevents two invocations of an
                // idempotent owner from accidentally becoming the same mutation.
                let child = try await store.submit(
                    commandText: step.input.canonicalText,
                    moduleID: step.moduleID,
                    retryPolicyProfile: module.descriptor.policies.retry.profile,
                    executionProfile: (capabilityEnvironment?.profile ?? .pureFake).rawValue,
                    offline: step.offline,
                    allowedOperations: capabilityEnvironment?.installedPolicy.map(\.rawValue).sorted(),
                    runtimeContext: RuntimeRunContext(
                        input: step.input,
                        approvedPlanHash: alternative.planHash,
                        parentRunID: runID.rawValue,
                        stepIndex: index,
                        annotations: transferred.annotations,
                        annotationNotice: childAnnotationNotice
                    )
                )
                context.childRunIDs.append(child.rawValue)
                try await store.updateRuntimeContext(runID, context: context)
                sequenceChildren[runID] = child
                plans[child] = plan
                modules[child] = module
                try await store.enqueue(child)
                scheduleExecution(child)
                let result = try await waitForTerminal(runID: child, timeout: .seconds(180))
                guard let refreshed = await store.receipt(for: runID), !refreshed.status.isTerminal, var latest = refreshed.runtimeContext else { return }
                if result.state != .succeeded {
                    let detail = "Stopped at step \(index + 1) of \(alternative.steps.count). \(latest.completedSteps.count) completed; no replay. \(result.summary)"
                    if result.state == .interrupted {
                        try await store.markInterrupted(runID, effectCertainty: .uncertain, message: detail, recordGenericUncertainty: false)
                    } else {
                        try await store.fail(runID, message: detail)
                    }
                    return
                }
                latest.completedSteps.append(index)
                let text = result.fullText ?? result.summary
                latest.fullText = (latest.fullText.map { $0 + "\n\n" } ?? "") + "Step \(index + 1) · \(step.input.canonicalText)\n\(text)"
                try await store.updateRuntimeContext(runID, context: latest)
            }
            if let receipt = await store.receipt(for: runID), !receipt.status.isTerminal {
                try await store.succeed(runID, summary: "Completed \(alternative.steps.count) confirmed steps", resultActions: [ResultAction.expand.rawValue, ResultAction.dismiss.rawValue])
            }
        } catch {
            if let receipt = await store.receipt(for: runID), !receipt.status.isTerminal {
                if let child = sequenceChildren[runID] { try? await cancel(runID: child) }
                try? await store.markInterrupted(runID, message: "Sequence stopped; completed steps retained: \(error)", recordGenericUncertainty: false)
            }
        }
    }

    func cancelSequence(runID: RunID) async throws {
        try await store.requestCancellation(runID)
        if let child = sequenceChildren[runID], let receipt = await store.receipt(for: child), !receipt.status.isTerminal {
            try await cancel(runID: child)
        }
        // A terminal child receipt alone does not prove the sequence supervisor
        // has stopped. Reap its task before claiming clean parent cancellation;
        // shutdown's outer deadline will turn a non-returning supervisor into
        // an explicitly uncertain receipt instead.
        let sequenceTask = sequenceTasks.removeValue(forKey: runID)
        sequenceTask?.cancel()
        if let sequenceTask { await sequenceTask.value }
        guard let receipt = await store.receipt(for: runID), !receipt.status.isTerminal else { return }
        let child = sequenceChildren[runID]
        let childReceipt = if let child { await store.receipt(for: child) } else { nil as OmniRun.RunReceipt? }
        if receipt.status == .queued || receipt.status == .confirmed {
            try await store.cancelBeforeExecution(runID)
        } else {
            try await store.acknowledgeCancellation(runID, acknowledgement: OmniRun.CancellationAcknowledgement(
                priorRequestObserved: true,
                executionStoppedAndReaped: sequenceTask != nil && (childReceipt?.status.isTerminal ?? true),
                ownerAcknowledged: childReceipt?.status != .interrupted && childReceipt?.effectCertainty != .uncertain,
                effectCertainty: childReceipt?.effectCertainty == .uncertain ? .uncertain : .certain
            ))
        }
    }

    func recoverSequenceEvidence(runID: RunID) async throws {
        guard let parent = await store.receipt(for: runID), var context = parent.runtimeContext else { return }
        let children = await store.recentRuns(limit: Int.max).filter { $0.runtimeContext?.parentRunID == runID.rawValue }.sorted {
            ($0.runtimeContext?.stepIndex ?? 0) < ($1.runtimeContext?.stepIndex ?? 0)
        }
        context.childRunIDs = children.map(\.id.rawValue)
        context.completedSteps = children.filter { $0.status == .succeeded }.compactMap { $0.runtimeContext?.stepIndex }
        context.fullText = children.map { child in
            let index = (child.runtimeContext?.stepIndex ?? 0) + 1
            return "Step \(index) · \(child.status.rawValue) · \(child.id.rawValue)\n\(child.commandText)\n\(child.runtimeContext?.fullText ?? child.summary ?? "Outcome unavailable")"
        }.joined(separator: "\n\n")
        try await store.updateRuntimeContext(runID, context: context)
        if !parent.status.isTerminal {
            let uncertain = children.contains { $0.effectCertainty == .uncertain || !$0.status.isTerminal }
            try await store.markInterrupted(runID, effectCertainty: uncertain ? .uncertain : .certain,
                message: "Interrupted sequence · \(context.completedSteps.count) completed step(s). Review stored outcomes before editing; no steps replayed.", recordGenericUncertainty: false)
        }
    }
}
