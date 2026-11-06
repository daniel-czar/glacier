import OmniCore

/// Adapts the existing injected model-execution boundary to bounded in-run
/// rewrites. Composition decides whether its broker has fixture-safe providers;
/// this adapter never selects a provider or introduces canned output.
public struct ModelBrokerFollowUpGenerator: FollowUpGenerating {
    private let broker: any ModelGenerating

    public init(broker: any ModelGenerating) {
        self.broker = broker
    }

    public func generate(_ request: FollowUpGenerationRequest) async throws -> FollowUpGeneration {
        // The follow-up request ID is this generation's correlation ID. Only
        // the new invocation's explicit selection is carried; the parent run's
        // provider is evidence in its receipt, never an inherited instruction.
        let result = try await broker.execute(ModelGenerationRequest(
            runID: request.runID,
            commandID: request.modelCommandID,
            prompt: request.prompt,
            offline: request.offline,
            outputConstraint: .plainText(),
            dispatch: ModelDispatchContext(generationID: request.requestID, selection: request.modelSelection)
        ))
        return FollowUpGeneration(resultText: result.response.text, modelRecord: result.record)
    }

    public func cancel(runID: String) async {
        // Cancellation is task-scoped by OmniApplicationService. ModelGenerating
        // implementations observe that task cancellation at their own boundary.
    }
}
