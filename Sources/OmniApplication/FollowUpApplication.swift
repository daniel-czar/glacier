import Foundation
import OmniCore
import OmniRun

enum FollowUpOwnership {
    case admitting(requestID: String)
    case running(requestID: String, task: Task<Void, Never>)

    var requestID: String {
        switch self {
        case .admitting(let requestID), .running(let requestID, _): requestID
        }
    }
}

extension OmniApplicationService {
    public func resultVersions(runID: RunID) async throws -> [OmniResultVersion] {
        guard let receipt = await store.receipt(for: runID) else { throw OmniApplicationError.missingRun }
        return resultVersions(for: receipt)
    }

    public func followUpState(runID: RunID) async -> OmniFollowUpState? {
        await store.receipt(for: runID)?.runtimeContext?.followUpState
    }

    /// Starts one bounded rewrite against one explicitly selected completed
    /// version. It does not submit a new user run or alter the parent receipt's
    /// terminal state.
    public func submitFollowUp(
        runID: RunID,
        sourceVersion: Int,
        visibleText: String,
        modelSelection: ModelInvocationSelection? = nil,
        annotations: [OmniTextAnnotation] = []
    ) async throws {
        guard !shuttingDown else { throw OmniApplicationError.shutdownInProgress }
        guard let generator = followUpGenerator else { throw OmniApplicationError.followUpUnavailable }
        guard followUpTasks[runID] == nil,
              !followUpCancellations.contains(runID)
        else { throw OmniApplicationError.followUpAlreadyActive }
        let parsedInput: OmniFollowUpInput
        do {
            parsedInput = try OmniFollowUpOperation.parse(visibleText: visibleText)
        } catch OmniFollowUpInputError.emptyEditedSource {
            throw OmniApplicationError.emptyFollowUpSource
        } catch {
            throw OmniApplicationError.unsupportedFollowUpOperation
        }
        let suppliedAnnotationCount = annotations.count
        let annotations = OmniAnnotationRanges.validated(annotations, in: visibleText)
        let annotationNotice = annotations.count < suppliedAnnotationCount
            ? "Some notes could not be attached to this follow-up."
            : nil
        let requestID = UUID().uuidString.lowercased()
        // This reservation precedes every actor suspension, including the
        // receipt read. Cancellation and competing submissions see it at once.
        followUpTasks[runID] = .admitting(requestID: requestID)
        defer {
            if case .admitting(let owner)? = followUpTasks[runID], owner == requestID {
                clearFollowUpOwnership(runID: runID, requestID: requestID)
            }
        }
        await followUpAdmissionHook?.didReserve(runID: runID, requestID: requestID)
        guard let receipt = await store.receipt(for: runID) else { throw OmniApplicationError.missingRun }
        guard let modelCommandID = receipt.moduleID else { throw OmniApplicationError.followUpUnavailable }
        // A `/stance` run's result is its positions; a follow-up would store
        // prose over them. The workspace hides Continue; this holds for every
        // caller, the candidate socket included.
        guard modelCommandID != OmniDecisionStep.stanceModuleID else { throw OmniApplicationError.followUpUnavailable }
        // A `/find` result is a picker of rows (D2), never prose to rewrite.
        guard receipt.runtimeContext?.find == nil else { throw OmniApplicationError.followUpUnavailable }
        // The parent run's provider choice is never inherited: only this
        // invocation's explicit selection travels with the request.
        let request = FollowUpGenerationRequest(
            runID: runID.rawValue,
            modelCommandID: modelCommandID,
            sourceVersion: sourceVersion,
            sourceText: parsedInput.editedSourceText,
            visibleText: visibleText,
            operation: parsedInput.operation,
            length: parsedInput.length,
            offline: receipt.offline ?? false,
            requestID: requestID,
            modelSelection: modelSelection,
            annotations: annotations
        )
        do {
            try await store.beginFollowUp(
                runID,
                sourceVersion: sourceVersion,
                visibleText: visibleText,
                requestID: requestID,
                annotations: annotations,
                annotationNotice: annotationNotice
            )
        } catch let error as OmniRunError {
            clearFollowUpOwnership(runID: runID, requestID: requestID)
            switch error {
            case .followUpRequiresSucceededRun: throw OmniApplicationError.followUpRequiresCompletedRun
            case .followUpAlreadyPending: throw OmniApplicationError.followUpAlreadyActive
            case .invalidFollowUpSourceVersion: throw OmniApplicationError.invalidFollowUpSourceVersion
            default: throw error
            }
        } catch {
            clearFollowUpOwnership(runID: runID, requestID: requestID)
            throw error
        }

        guard !shuttingDown,
              !followUpCancellations.contains(runID),
              !cancelledFollowUpRequestIDs.contains(requestID),
              followUpTasks[runID]?.requestID == requestID
        else {
            _ = try? await store.cancelFollowUp(runID, requestID: requestID)
            cancelledFollowUpRequestIDs.remove(requestID)
            clearFollowUpOwnership(runID: runID, requestID: requestID)
            return
        }

        let task = Task { [weak self, generator] in
            do {
                let generation = try await generator.generate(request)
                await self?.completeFollowUp(
                    runID: runID,
                    requestID: requestID,
                    request: request,
                    generation: generation
                )
            } catch is CancellationError {
                await self?.recordFollowUpFailure(
                    runID: runID,
                    requestID: requestID,
                    message: "Follow-up cancelled"
                )
            } catch {
                await self?.recordFollowUpFailure(
                    runID: runID,
                    requestID: requestID,
                    message: "Follow-up failed: \(error)"
                )
            }
        }
        followUpTasks[runID] = .running(requestID: requestID, task: task)
    }

    public func cancelFollowUp(runID: RunID) async throws {
        followUpCancellations.insert(runID)
        defer { followUpCancellations.remove(runID) }
        let reserved = followUpTasks[runID]
        let reservedRequestID = reserved?.requestID
        if let reservedRequestID { cancelledFollowUpRequestIDs.insert(reservedRequestID) }
        let requestID: String?
        do {
            if let reservedRequestID {
                requestID = (try await store.cancelFollowUp(runID, requestID: reservedRequestID)) ? reservedRequestID : nil
            } else {
                requestID = try await store.cancelFollowUp(runID)
            }
        } catch let error as OmniRunError where error == .unknownRun(runID) {
            throw OmniApplicationError.missingRun
        } catch {
            throw error
        }
        guard let requestID else {
            if case .admitting? = reserved {
                // The reservation remains cancelled until its late durable
                // admission observes the request ID and reclaims itself.
                return
            }
            if let reservedRequestID { cancelledFollowUpRequestIDs.remove(reservedRequestID) }
            return
        }
        if let active = followUpTasks[runID], active.requestID == requestID {
            followUpTasks.removeValue(forKey: runID)
            if case .running(_, let task) = active { task.cancel() }
        }
        await followUpGenerator?.cancel(runID: runID.rawValue)
        if case .admitting? = reserved {
            // The admission continuation clears this marker after it writes
            // the matching durable cancellation.
        } else {
            cancelledFollowUpRequestIDs.remove(requestID)
        }
    }

    private func resultVersions(for receipt: OmniRun.RunReceipt) -> [OmniResultVersion] {
        if let versions = receipt.runtimeContext?.resultVersions, !versions.isEmpty {
            return versions.sorted { $0.number < $1.number }
        }
        guard receipt.status == .succeeded else { return [] }
        return [OmniResultVersion(
            number: 1,
            inputText: receipt.runtimeContext?.input?.rawText ?? receipt.commandText,
            resultText: receipt.runtimeContext?.fullText ?? receipt.summary ?? "",
            operation: .initial,
            createdAt: receipt.updatedAt,
            annotations: receipt.runtimeContext?.annotations ?? []
        )]
    }

    private func completeFollowUp(
        runID: RunID,
        requestID: String,
        request: FollowUpGenerationRequest,
        generation: FollowUpGeneration
    ) async {
        do {
            let appended = try await store.completeFollowUp(
                runID,
                requestID: requestID,
                resultText: generation.resultText,
                operation: request.operation,
                modelRecord: generation.modelRecord
            )
            _ = appended
            clearFollowUpOwnership(runID: runID, requestID: requestID)
        } catch {
            await recordFollowUpFailure(runID: runID, requestID: requestID, message: "Follow-up result could not be saved: \(error)")
        }
    }

    private func recordFollowUpFailure(runID: RunID, requestID: String, message: String) async {
        _ = try? await store.failFollowUp(runID, requestID: requestID, message: message)
        clearFollowUpOwnership(runID: runID, requestID: requestID)
    }

    func reconcilePersistedFollowUpsAfterRestart() async throws {
        for receipt in await store.recentRuns(limit: Int.max) {
            guard receipt.status.isTerminal,
                  let pending = receipt.runtimeContext?.followUpState,
                  pending.kind == .pending
            else { continue }
            _ = try await store.failFollowUp(
                receipt.id,
                requestID: pending.requestID,
                message: "Follow-up interrupted by host restart"
            )
        }
    }

    private func clearFollowUpOwnership(runID: RunID, requestID: String) {
        if followUpTasks[runID]?.requestID == requestID {
            followUpTasks.removeValue(forKey: runID)
        }
        cancelledFollowUpRequestIDs.remove(requestID)
    }
}
