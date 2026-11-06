import CSQLite
import Darwin
import Foundation
import OmniCore

/// Development-only durable run store. `events.jsonl` is authoritative; SQLite is a disposable read model.
public actor OmniRunStore {
    /// Marker-less logs are the Phase 4 format and remain readable as version 0.
    public nonisolated static let currentStorageVersion = 2

    public nonisolated let developmentRoot: OmniDevelopmentRoot
    private let eventLogURL: URL
    private let indexURL: URL
    private let artifactsURL: URL
    private let now: @Sendable () -> Date
    private let moduleVersion: String
    private let manifestVersion: String
    private let writerLock: ExclusiveStoreWriterLock
    private var events: [RunEvent] = []
    private var receipts: [RunID: RunReceipt] = [:]
    private var lastMilliseconds: UInt64 = 0
    private var lastRandomness = Array(repeating: UInt8(0), count: 10)
    private var index: SQLiteRunIndex
    /// In-process writes do not change SQLite's data_version on this connection.
    /// Pair a local revision with it so the resident can avoid decoding every
    /// receipt on an unchanged history tick while still seeing external index
    /// updates that the existing query would have observed.
    private var queryRevision: UInt64 = 0
    private var observedIndexDataVersion: Int64?

    public init(developmentRoot: URL, allowedRoot: URL, forbiddenRoots: [URL] = [], moduleVersion: String = "development", manifestVersion: String = "development", now: @escaping @Sendable () -> Date = Date.init) throws {
        let validated = try OmniDevelopmentRoot(validating: developmentRoot, allowedRoot: allowedRoot, forbiddenRoots: forbiddenRoots)
        let eventLogURL = try validated.containedURL(relativePath: "events.jsonl")
        let storageVersionURL = try validated.containedURL(relativePath: "storage-version.json")
        // This read is deliberately before the writer lock, tail repair, SQLite
        // recovery, and artifact directory creation. A future writer's data must
        // remain untouched by an older candidate.
        let storageVersion = try Self.readStorageVersion(at: storageVersionURL)
        self.developmentRoot = validated
        self.eventLogURL = eventLogURL
        self.indexURL = try validated.containedURL(relativePath: "runs.sqlite")
        self.artifactsURL = try validated.containedURL(relativePath: "artifacts")
        self.now = now
        self.moduleVersion = moduleVersion
        self.manifestVersion = manifestVersion
        self.writerLock = try ExclusiveStoreWriterLock(url: try validated.containedURL(relativePath: "writer.lock"))
        self.events = try Self.readEventsRepairingOnlyTruncatedTail(at: eventLogURL)
        self.receipts = Self.fold(events: events)
        let seed = Self.allocatorSeed(from: events)
        self.lastMilliseconds = seed?.milliseconds ?? 0
        self.lastRandomness = seed?.randomness ?? Array(repeating: UInt8(0), count: 10)
        // An older marker is migrated only after every historical event has
        // decoded successfully. The JSONL receipt bytes remain untouched.
        if storageVersion == nil || storageVersion! < Self.currentStorageVersion {
            try Self.writeStorageVersion(Self.currentStorageVersion, to: storageVersionURL)
        }
        try FileManager.default.createDirectory(at: artifactsURL, withIntermediateDirectories: true)
        do {
            self.index = try SQLiteRunIndex(url: indexURL)
        } catch {
            self.index = try SQLiteRunIndex(url: indexURL, replacingCorruptFile: true)
        }
        try index.replace(with: receipts.values)
    }

    @discardableResult
    public func submit(
        commandText: String,
        retryOf: RunID? = nil,
        moduleID: String? = nil,
        retryPolicyProfile: String? = nil,
        executionProfile: String? = nil,
        offline: Bool? = nil,
        allowedOperations: [String]? = nil,
        runtimeContext: RuntimeRunContext? = nil
    ) throws -> RunID {
        // Validate the entire request before the first durable append. In
        // particular, an invalid retry link must not leave a submitted orphan.
        if let retryOf {
            guard receipts[retryOf] != nil else { throw OmniRunError.unknownRun(retryOf) }
        }
        let runID = allocateRunID()
        try append(runID: runID, kind: .submitted, actor: .user, payload: .init(commandText: commandText, leaseID: defaultLeaseID(for: runID), moduleID: moduleID, retryPolicyProfile: retryPolicyProfile, executionProfile: executionProfile, offline: offline, allowedOperations: allowedOperations, runtimeContext: runtimeContext))
        if let retryOf {
            try append(runID: runID, kind: .retryLinked, actor: .user, payload: .init(retryOf: retryOf))
        }
        return runID
    }

    public func beginExecution(_ runID: RunID) throws { try transition(runID, kind: .executionStarted) }
    public func enqueue(_ runID: RunID) throws { try transition(runID, kind: .queued) }

    public func recordEffectAttempt(
        _ runID: RunID,
        effectID: String,
        adapterID: String,
        operationID: String,
        idempotencyKey: String? = nil,
        idempotencyProven: Bool = false,
        redactedTarget: String? = nil,
        targetDigest: String? = nil,
        retrySafetyReason: String? = nil
    ) throws {
        try require(runID, statuses: [.running], event: .effectAttempted)
        try append(
            runID: runID,
            kind: .effectAttempted,
            actor: .executor,
            payload: .init(
                effectID: effectID,
                adapterID: adapterID,
                operationID: operationID,
                idempotencyKey: idempotencyKey,
                idempotencyProven: idempotencyProven,
                redactedTarget: redactedTarget,
                targetDigest: targetDigest,
                retrySafetyReason: retrySafetyReason
            )
        )
    }

    public func recordEffectOutcome(
        _ runID: RunID,
        effectID: String,
        outcome: EffectOutcome,
        certainty: EffectCertainty,
        ownerID: String? = nil,
        ownerPath: String? = nil,
        ownerAcknowledgement: String? = nil,
        boundedOutput: String? = nil,
        retrySafetyReason: String? = nil,
        recoveryDisposition: String? = nil,
        actor: RunActor = .executor
    ) throws {
        let kind: RunEventKind = switch (outcome, certainty) {
        case (_, .uncertain), (.unknown, _): .effectUncertain
        case (.succeeded, .certain): .effectSucceeded
        case (.failed, .certain): .effectFailed
        }
        try require(runID, statuses: actor == .recovery ? [.running, .interrupted] : [.running], event: kind)
        let attempted = events.contains { event in
            event.runID == runID && event.kind == .effectAttempted && event.payload.effectID == effectID
        }
        guard attempted else { throw OmniRunError.missingEffectAttempt(effectID) }
        let priorOutcomes = events.filter { event in
            event.runID == runID && event.payload.effectID == effectID && [.effectSucceeded, .effectFailed, .effectUncertain].contains(event.kind)
        }
        let mayResolvePriorUncertainty = actor == .recovery
            && !priorOutcomes.isEmpty
            && priorOutcomes.allSatisfy { $0.kind == .effectUncertain && $0.actor != .recovery }
        guard priorOutcomes.isEmpty || mayResolvePriorUncertainty else {
            throw OmniRunError.duplicateEffectOutcome(effectID)
        }
        try append(
            runID: runID,
            kind: kind,
            actor: actor,
            payload: .init(
                effectID: effectID,
                effectOutcome: outcome,
                effectCertainty: certainty,
                ownerAcknowledgement: ownerAcknowledgement,
                recoveryDisposition: recoveryDisposition ?? (certainty == .certain ? "known" : "reconcile-required"),
                ownerID: ownerID,
                ownerPath: ownerPath,
                boundedOutput: boundedOutput,
                retrySafetyReason: retrySafetyReason
            )
        )
    }

    public func requestCancellation(_ runID: RunID, source: String = "user") throws {
        try transition(runID, kind: .cancellationRequested, payload: .init(message: source))
    }

    /// A clean cancellation requires all acknowledged proof fields; any gap is uncertain and interrupted.
    public func acknowledgeCancellation(_ runID: RunID, acknowledgement: CancellationAcknowledgement) throws {
        let receipt = try requireReceipt(runID)
        guard receipt.status == .running, receipt.cancellationRequested else {
            throw OmniRunError.illegalTransition(from: receipt.status, event: .cancellationAcknowledged)
        }
        let proof = "request_observed=\(acknowledgement.priorRequestObserved);stopped_reaped=\(acknowledgement.executionStoppedAndReaped);owner_acknowledged=\(acknowledgement.ownerAcknowledged)"
        if acknowledgement.provesCleanCancellation {
            try append(
                runID: runID,
                kind: .cancellationAcknowledged,
                actor: .executor,
                payload: .init(
                    message: proof,
                    effectCertainty: acknowledgement.effectCertainty,
                    ownerAcknowledgement: "acknowledged",
                    stopAcknowledgement: "stopped",
                    recoveryDisposition: "effect-certain"
                )
            )
            try append(runID: runID, kind: .cancelled, actor: .executor, payload: terminalPayload(runID, certainty: acknowledgement.effectCertainty))
        } else {
            try append(
                runID: runID,
                kind: .effectUncertain,
                actor: .executor,
                payload: .init(
                    message: proof,
                    effectID: "cancellation",
                    effectOutcome: .unknown,
                    effectCertainty: .uncertain,
                    ownerAcknowledgement: acknowledgement.ownerAcknowledged ? "acknowledged" : "unacknowledged",
                    stopAcknowledgement: acknowledgement.executionStoppedAndReaped ? "stopped" : "unproved",
                    recoveryDisposition: "reconcile-required"
                )
            )
            try append(runID: runID, kind: .interrupted, actor: .executor, payload: terminalPayload(runID, message: "cancellation acknowledgement incomplete", certainty: acknowledgement.effectCertainty))
        }
    }

    public func succeed(_ runID: RunID, summary: String? = nil, artifactReference: String? = nil, resultActions: [String] = [], runtimeContext: RuntimeRunContext? = nil) throws {
        var payload = terminalPayload(runID, summary: summary, artifactReference: artifactReference, resultActions: resultActions)
        payload.runtimeContext = runtimeContext
        try transition(runID, kind: .succeeded, payload: payload)
    }

    /// Completes only a deterministic owner operation already proved successful
    /// by recovery. Normal `succeed` deliberately still rejects terminal runs.
    /// With no supplied result, reconstructs the result from durable owner
    /// evidence after a crash between recording that proof and completing it.
    @discardableResult
    public func completeOwnerRecovery(_ runID: RunID, result: ModuleResult? = nil) throws -> Bool {
        let receipt = try requireReceipt(runID)
        guard let proof = provedOwnerRecovery(for: runID) else { return false }
        try require(runID, statuses: [.running, .interrupted], event: .succeeded)
        let path = proof.payload.ownerPath!
        if let result, result.artifactReference != path { return false }
        let isStash = receipt.moduleID == "cache.stash"
        let recovered = result ?? ModuleResult(
            summary: isStash ? "Reconciled stash" : "Reconciled owner capture",
            artifactReference: path,
            allowedActions: isStash ? [.copy, .dismiss] : [.open, .reveal, .dismiss]
        )
        var payload = terminalPayload(
            runID, certainty: .certain, summary: recovered.summary,
            artifactReference: path, resultActions: recovered.allowedActions.map(\.rawValue)
        )
        var context = receipt.runtimeContext ?? RuntimeRunContext()
        context.fullText = recovered.fullText
        payload.runtimeContext = context
        try append(runID: runID, kind: .succeeded, actor: .recovery, payload: payload)
        return true
    }

    private func provedOwnerRecovery(for runID: RunID) -> RunEvent? {
        guard let receipt = receipts[runID], [.running, .interrupted].contains(receipt.status),
              receipt.runtimeContext?.proposal == nil else { return nil }
        let operation: OwnerOperation
        switch receipt.moduleID {
        case "capture.favorite": operation = .captureLink
        case "capture.base": operation = .captureBaseNote
        case "cache.stash": operation = .replaceCurrentStash
        default: return nil
        }
        let runEvents = events.filter { $0.runID == runID }
        let attempts = runEvents.filter { $0.kind == .effectAttempted }
        guard attempts.count == 1, let attempt = attempts.first,
              attempt.payload.operationID == operation.rawValue,
              attempt.payload.idempotencyProven == true,
              let effectID = attempt.payload.effectID,
              let outcome = runEvents.last(where: {
                  $0.payload.effectID == effectID && [.effectSucceeded, .effectFailed, .effectUncertain].contains($0.kind)
              }), outcome.kind == .effectSucceeded, outcome.actor == .recovery,
              outcome.payload.effectCertainty == .certain,
              outcome.payload.ownerID?.isEmpty == false,
              outcome.payload.ownerPath?.isEmpty == false,
              outcome.payload.ownerAcknowledgement?.isEmpty == false
        else { return nil }
        return outcome
    }
    public func beginProposal(_ runID: RunID) throws { try transition(runID, kind: .proposalStarted) }
    public func markProposalReady(_ runID: RunID, moduleID: String? = nil, planHash: String? = nil, capabilities: [String] = [], input: String? = nil, inputDigest: String? = nil, retryPolicyProfile: String? = nil, runtimeContext: RuntimeRunContext? = nil) throws {
        try transition(
            runID,
            kind: .proposalReady,
            payload: .init(
                moduleID: moduleID,
                planHash: planHash,
                proposalCapabilities: capabilities,
                proposalInput: input,
                proposalInputDigest: inputDigest,
                retryPolicyProfile: retryPolicyProfile,
                runtimeContext: runtimeContext
            )
        )
    }
    public func confirmProposal(_ runID: RunID, exactPlanHash: String? = nil, runtimeContext: RuntimeRunContext? = nil) throws {
        try transition(runID, kind: .confirmed, payload: .init(planHash: exactPlanHash, runtimeContext: runtimeContext))
    }
    public func updateRuntimeContext(_ runID: RunID, context: RuntimeRunContext) throws {
        _ = try requireReceipt(runID)
        try append(runID: runID, kind: .runtimeContextUpdated, actor: .runtime, payload: .init(runtimeContext: context))
    }

    /// Atomically claims the one permitted in-run follow-up. The selected
    /// version is checked from the current durable context rather than a
    /// caller snapshot, so concurrent admissions cannot start two generators.
    public func beginFollowUp(
        _ runID: RunID,
        sourceVersion: Int,
        visibleText: String,
        requestID: String,
        annotations: [OmniTextAnnotation] = [],
        annotationNotice: String? = nil
    ) throws {
        let receipt = try requireReceipt(runID)
        guard receipt.status == .succeeded else {
            throw OmniRunError.followUpRequiresSucceededRun(receipt.status)
        }
        guard receipt.runtimeContext?.followUpState?.kind != .pending else {
            throw OmniRunError.followUpAlreadyPending
        }
        let versions = followUpResultVersions(for: receipt)
        guard versions.contains(where: { $0.number == sourceVersion }) else {
            throw OmniRunError.invalidFollowUpSourceVersion(sourceVersion)
        }
        var context = receipt.runtimeContext ?? RuntimeRunContext()
        context.version = RuntimeRunContext.currentVersion
        context.resultVersions = versions
        if let annotationNotice { context.annotationNotice = annotationNotice }
        context.followUpState = OmniFollowUpState(
            kind: .pending,
            requestID: requestID,
            sourceVersion: sourceVersion,
            visibleText: visibleText,
            annotations: annotations,
            annotationNotice: annotationNotice
        )
        try append(runID: runID, kind: .runtimeContextUpdated, actor: .runtime, payload: .init(runtimeContext: context))
    }

    /// Appends a version only when the same durable pending request still owns
    /// the run. A stale completion is a no-op rather than an overwrite.
    @discardableResult
    public func completeFollowUp(
        _ runID: RunID,
        requestID: String,
        resultText: String,
        operation: OmniFollowUpOperation,
        modelRecord: ModelExecutionRecord? = nil
    ) throws -> Bool {
        guard !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OmniRunError.emptyFollowUpResult
        }
        let receipt = try requireReceipt(runID)
        guard receipt.status == .succeeded,
              let pending = receipt.runtimeContext?.followUpState,
              pending.kind == .pending,
              pending.requestID == requestID
        else { return false }
        var context = receipt.runtimeContext ?? RuntimeRunContext()
        context.version = RuntimeRunContext.currentVersion
        let versions = followUpResultVersions(for: receipt)
        context.resultVersions = versions + [OmniResultVersion(
            number: (versions.map(\.number).max() ?? 0) + 1,
            inputText: pending.visibleText,
            resultText: resultText,
            operation: operation,
            sourceVersion: pending.sourceVersion,
            annotations: pending.annotations
        )]
        context.fullText = resultText
        context.followUpState = nil
        if let modelRecord { context.modelRecords.append(modelRecord) }
        try append(runID: runID, kind: .runtimeContextUpdated, actor: .runtime, payload: .init(runtimeContext: context))
        return true
    }

    /// Records only the active request's error. Completion from a cancelled or
    /// replaced request cannot overwrite this state.
    @discardableResult
    public func failFollowUp(_ runID: RunID, requestID: String, message: String) throws -> Bool {
        let receipt = try requireReceipt(runID)
        guard let pending = receipt.runtimeContext?.followUpState,
              pending.kind == .pending,
              pending.requestID == requestID
        else { return false }
        var context = receipt.runtimeContext ?? RuntimeRunContext()
        context.version = RuntimeRunContext.currentVersion
        context.followUpState = OmniFollowUpState(
            kind: .failed,
            requestID: requestID,
            sourceVersion: pending.sourceVersion,
            visibleText: pending.visibleText,
            message: message,
            annotations: pending.annotations,
            annotationNotice: pending.annotationNotice
        )
        try append(runID: runID, kind: .runtimeContextUpdated, actor: .runtime, payload: .init(runtimeContext: context))
        return true
    }

    /// Cancels whichever request is durable at invocation time and returns its
    /// identity so the service can cancel only the matching in-memory task.
    public func cancelFollowUp(_ runID: RunID, message: String = "Follow-up cancelled") throws -> String? {
        let receipt = try requireReceipt(runID)
        guard let pending = receipt.runtimeContext?.followUpState, pending.kind == .pending else { return nil }
        _ = try cancelFollowUp(runID, requestID: pending.requestID, message: message)
        return pending.requestID
    }

    /// Cancels only the durable request identified by `requestID`. This is the
    /// compare-and-set form used when a service reservation races admission.
    @discardableResult
    public func cancelFollowUp(_ runID: RunID, requestID: String, message: String = "Follow-up cancelled") throws -> Bool {
        let receipt = try requireReceipt(runID)
        guard let pending = receipt.runtimeContext?.followUpState,
              pending.kind == .pending,
              pending.requestID == requestID
        else { return false }
        var context = receipt.runtimeContext ?? RuntimeRunContext()
        context.version = RuntimeRunContext.currentVersion
        context.followUpState = OmniFollowUpState(
            kind: .cancelled,
            requestID: requestID,
            sourceVersion: pending.sourceVersion,
            visibleText: pending.visibleText,
            message: message,
            annotations: pending.annotations,
            annotationNotice: pending.annotationNotice
        )
        try append(runID: runID, kind: .runtimeContextUpdated, actor: .runtime, payload: .init(runtimeContext: context))
        return true
    }
    public func recordResultAction(_ runID: RunID, action: String, acknowledgement: String) throws {
        let receipt = try requireReceipt(runID)
        guard receipt.status == .succeeded, receipt.resultActions.contains(action) else {
            throw OmniRunError.illegalTransition(from: receipt.status, event: .resultActionRecorded)
        }
        try append(runID: runID, kind: .resultActionRecorded, actor: .user, payload: .init(operationID: action, ownerAcknowledgement: acknowledgement))
    }
    public func cancelBeforeExecution(_ runID: RunID) throws {
        try require(runID, statuses: [.submitted, .queued, .proposing, .proposalReady, .confirmed], event: .cancelled)
        try append(runID: runID, kind: .cancelled, actor: .user, payload: terminalPayload(runID, message: "Cancelled before execution", certainty: .certain))
    }
    public func dismiss(_ runID: RunID) throws { try transition(runID, kind: .dismissed, payload: terminalPayload(runID)) }
    public func expire(_ runID: RunID) throws { try transition(runID, kind: .expired, payload: terminalPayload(runID)) }
    public func fail(_ runID: RunID, message: String? = nil) throws {
        try require(runID, statuses: [.submitted, .queued, .proposing, .proposalReady, .confirmed, .running], event: .failed)
        try append(runID: runID, kind: .failed, actor: .runtime, payload: terminalPayload(runID, message: message))
    }

    public func markInterrupted(_ runID: RunID, effectCertainty: EffectCertainty? = nil, message: String = "execution handle lost", recordGenericUncertainty: Bool = true) throws {
        let receipt = try requireReceipt(runID)
        guard !receipt.status.isTerminal else { throw OmniRunError.illegalTransition(from: receipt.status, event: .interrupted) }
        if effectCertainty == .uncertain && recordGenericUncertainty {
            try append(runID: runID, kind: .effectUncertain, actor: .recovery, payload: .init(message: message, effectCertainty: .uncertain))
        }
        try append(runID: runID, kind: .interrupted, actor: .recovery, payload: terminalPayload(runID, message: message, certainty: effectCertainty))
    }

    public func attachArtifact(_ runID: RunID, relativePath: String) throws {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else {
            throw OmniRunError.invalidArtifactPath
        }
        _ = try requireReceipt(runID)
        let relative = "artifacts/\(runID.rawValue)/\(relativePath)"
        _ = try developmentRoot.containedURL(relativePath: relative)
        try append(runID: runID, kind: .artifactAttached, actor: .runtime, payload: .init(artifact: relative))
    }

    public func acquireLivenessLease(_ runID: RunID, leaseID: String = UUID().uuidString) throws -> String {
        let receipt = try requireReceipt(runID)
        guard !leaseID.isEmpty, !receipt.status.isTerminal else {
            throw OmniRunError.illegalTransition(from: receipt.status, event: .leaseAcquired)
        }
        try append(runID: runID, kind: .leaseAcquired, actor: .runtime, payload: .init(leaseID: leaseID))
        return leaseID
    }

    public func releaseLivenessLease(_ runID: RunID, leaseID: String) throws {
        _ = try requireReceipt(runID)
        try append(runID: runID, kind: .leaseReleased, actor: .runtime, payload: .init(leaseID: leaseID))
    }

    /// Reconciles processes that cannot survive this development host restart.
    public func reconcileIncompleteWork() throws -> [RunID] {
        let incomplete = receipts.values.filter { !$0.status.isTerminal }.map(\.id)
        for runID in incomplete {
            try reconcileIncompleteRun(runID)
        }
        return incomplete
    }

    public func reconcileIncompleteRun(_ runID: RunID, message: String = "host restart") throws {
        let receipt = try requireReceipt(runID)
        guard !receipt.status.isTerminal else { return }
        let runEvents = events.filter { $0.runID == runID }
        for attempt in unmatchedEffectAttempts(for: runID) {
            guard let effectID = attempt.payload.effectID else { continue }
            try append(
                runID: runID,
                kind: .effectUncertain,
                actor: .recovery,
                payload: .init(
                    message: "unmatched effect attempt at host restart",
                    effectID: effectID,
                    effectOutcome: .unknown,
                    effectCertainty: .uncertain,
                    recoveryDisposition: "reconcile-required"
                )
            )
        }
        if receipt.cancellationRequested && !runEvents.contains(where: { $0.kind == .effectUncertain }) {
            try append(runID: runID, kind: .effectUncertain, actor: .recovery, payload: .init(message: message, effectCertainty: .uncertain))
        }
        try append(runID: runID, kind: .interrupted, actor: .recovery, payload: terminalPayload(runID, message: message, certainty: receipt.cancellationRequested ? .uncertain : nil))
    }

    public func unmatchedEffectAttempts(for runID: RunID) -> [RunEvent] {
        let runEvents = events.filter { $0.runID == runID }
        return runEvents.filter { attempt in
            guard attempt.kind == .effectAttempted, let effectID = attempt.payload.effectID else { return false }
            return !runEvents.contains { event in
                event.payload.effectID == effectID && [.effectSucceeded, .effectFailed, .effectUncertain].contains(event.kind)
            }
        }
    }

    public func effectAttemptNeedingReconciliation(for runID: RunID) -> RunEvent? {
        let runEvents = events.filter { $0.runID == runID }
        return runEvents.first { attempt in
            guard attempt.kind == .effectAttempted, let effectID = attempt.payload.effectID else { return false }
            let outcomes = runEvents.filter {
                $0.payload.effectID == effectID && [.effectSucceeded, .effectFailed, .effectUncertain].contains($0.kind)
            }
            return outcomes.isEmpty || outcomes.allSatisfy { $0.kind == .effectUncertain && $0.actor != .recovery }
        }
    }

    public func runsNeedingOwnerReconciliation() -> [RunReceipt] {
        sorted(receipts.values.filter { receipt in
            !receipt.status.isTerminal
                || (receipt.status == .interrupted && (effectAttemptNeedingReconciliationSync(for: receipt.id) != nil || provedOwnerRecovery(for: receipt.id) != nil))
        })
    }

    private func effectAttemptNeedingReconciliationSync(for runID: RunID) -> RunEvent? {
        let runEvents = events.filter { $0.runID == runID }
        return runEvents.first { attempt in
            guard attempt.kind == .effectAttempted, let effectID = attempt.payload.effectID else { return false }
            let outcomes = runEvents.filter {
                $0.payload.effectID == effectID && [.effectSucceeded, .effectFailed, .effectUncertain].contains($0.kind)
            }
            return outcomes.isEmpty || outcomes.allSatisfy { $0.kind == .effectUncertain && $0.actor != .recovery }
        }
    }

    /// Writes the tombstone first, then removes only the run's injected-root artifact directory.
    public func applyRetention(to runID: RunID) throws {
        let receipt = try requireReceipt(runID)
        guard receipt.status.isTerminal else { throw OmniRunError.illegalTransition(from: receipt.status, event: .retentionTombstoned) }
        try append(runID: runID, kind: .retentionTombstoned, actor: .retention, payload: .init())
        let directory = artifactsURL.appendingPathComponent(runID.rawValue, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    public func receipt(for runID: RunID) -> RunReceipt? { receipts[runID] }
    public func allEvents() -> [RunEvent] { events }
    public func activeRuns() -> [RunReceipt] { sorted(receipts.values.filter { !$0.status.isTerminal }) }
    public func recentRuns(limit: Int = 20) -> [RunReceipt] { Array(sorted(receipts.values).prefix(max(0, limit))) }
    public func indexedActiveRuns() throws -> [RunReceipt] { try index.query(activeOnly: true, limit: nil) }
    public func indexedRecentRuns(limit: Int = 20) throws -> [RunReceipt] { try index.query(activeOnly: false, limit: max(0, limit)) }
    public func indexedRecentRunsIfChanged(since revision: UInt64?, limit: Int = Int.max) throws -> (revision: UInt64, receipts: [RunReceipt])? {
        // A failed cheap probe must not suppress history. The full query below
        // either succeeds as before or reports its own error for the next tick.
        let dataVersion = try? index.dataVersion()
        if let dataVersion {
            if let observedIndexDataVersion, observedIndexDataVersion != dataVersion { queryRevision &+= 1 }
            observedIndexDataVersion = dataVersion
        }
        guard dataVersion == nil || revision != queryRevision else { return nil }
        do {
            return (queryRevision, try index.query(activeOnly: false, limit: max(0, limit)))
        } catch {
            // A failed read never satisfies the caller's previous token. A
            // transient lock can clear without another data_version change.
            queryRevision &+= 1
            throw error
        }
    }
    public func idleExitIsSuppressed() -> Bool { receipts.values.contains { $0.suppressesIdleExit } }

    public func automaticRetryIsAllowed(_ runID: RunID) throws -> Bool {
        _ = try requireReceipt(runID)
        let runEvents = events.filter { $0.runID == runID }
        guard !runEvents.contains(where: { $0.kind == .effectUncertain }) else { return false }
        guard unmatchedEffectAttempts(for: runID).isEmpty else { return false }
        let attempts = runEvents.filter { $0.kind == .effectAttempted }
        return !attempts.isEmpty && attempts.allSatisfy { $0.payload.idempotencyProven == true }
    }

    /// Deletes/recreates only SQLite. The event log is reread and remains source truth.
    public func rebuildQueryIndex() throws {
        try index.replace(with: receipts.values)
        queryRevision &+= 1
    }

    private func transition(_ runID: RunID, kind: RunEventKind, payload: RunEventPayload = .init()) throws {
        let allowed: Set<RunStatus>
        switch kind {
        case .queued: allowed = [.submitted, .confirmed]
        case .executionStarted: allowed = [.queued, .confirmed]
        case .proposalStarted: allowed = [.submitted]
        case .proposalReady: allowed = [.proposing]
        case .confirmed: allowed = [.proposalReady]
        case .dismissed: allowed = [.submitted, .queued, .proposing, .proposalReady, .confirmed]
        case .expired: allowed = [.submitted, .queued, .proposing, .proposalReady, .confirmed]
        case .cancellationRequested: allowed = [.submitted, .queued, .running, .proposing, .proposalReady, .confirmed]
        case .succeeded: allowed = [.running]
        case .cancelled, .effectUncertain, .effectSucceeded, .effectFailed, .failed, .interrupted, .submitted, .effectAttempted, .cancellationAcknowledged, .retryLinked, .artifactAttached, .retentionTombstoned, .leaseAcquired, .leaseReleased, .runtimeContextUpdated, .resultActionRecorded:
            allowed = []
        }
        try require(runID, statuses: allowed, event: kind)
        try append(runID: runID, kind: kind, actor: .runtime, payload: payload)
    }

    private func require(_ runID: RunID, statuses: Set<RunStatus>, event: RunEventKind) throws {
        let receipt = try requireReceipt(runID)
        guard statuses.contains(receipt.status) else { throw OmniRunError.illegalTransition(from: receipt.status, event: event) }
    }

    private func requireReceipt(_ runID: RunID) throws -> RunReceipt {
        guard let receipt = receipts[runID] else { throw OmniRunError.unknownRun(runID) }
        return receipt
    }

    private func followUpResultVersions(for receipt: RunReceipt) -> [OmniResultVersion] {
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

    private func append(runID: RunID, kind: RunEventKind, actor: RunActor, payload: RunEventPayload) throws {
        let sequence = (receipts[runID]?.eventCount ?? 0) + 1
        let priorState = receipts[runID]?.status
        let event = RunEvent(eventID: UUID().uuidString.lowercased(), runID: runID, sequence: sequence, recordedAt: now(), kind: kind, actor: actor, moduleVersion: moduleVersion, manifestVersion: manifestVersion, priorState: priorState, newState: Self.state(after: kind, prior: priorState), payload: payload)
        let data = try Self.encoder.encode(event) + Data([0x0A])
        if !FileManager.default.fileExists(atPath: eventLogURL.path) { FileManager.default.createFile(atPath: eventLogURL.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: eventLogURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        events.append(event)
        receipts = Self.fold(events: events)
        // The event is durable even if the disposable index needs repair.
        // Leave the caller's old token stale so a failed refresh keeps retrying.
        queryRevision &+= 1
        do {
            try index.replace(with: receipts.values)
        } catch {
            // A corrupt/deleted read model must never invalidate an already durable event.
            index = try SQLiteRunIndex(url: indexURL, replacingCorruptFile: true)
            try index.replace(with: receipts.values)
        }
    }

    private func allocateRunID() -> RunID {
        let current = UInt64(max(0, now().timeIntervalSince1970 * 1_000))
        if current > lastMilliseconds {
            lastMilliseconds = current
            var generator = SystemRandomNumberGenerator()
            lastRandomness = (0..<10).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        } else {
            Self.increment(&lastRandomness)
        }
        return RunID(unchecked: "oi_" + Self.encodeULID(milliseconds: lastMilliseconds, randomness: lastRandomness))
    }

    private static func allocatorSeed(from events: [RunEvent]) -> (milliseconds: UInt64, randomness: [UInt8])? {
        guard let last = events.map(\.runID.rawValue).max(), last.count == 29 else { return nil }
        let encoded = String(last.dropFirst(3))
        guard let bytes = Self.decodeULID(encoded), bytes.count == 16 else { return nil }
        return (bytes.prefix(6).reduce(0) { ($0 << 8) | UInt64($1) }, Array(bytes.suffix(10)))
    }

    private func sorted(_ values: some Collection<RunReceipt>) -> [RunReceipt] {
        values.sorted { lhs, rhs in lhs.updatedAt == rhs.updatedAt ? lhs.id > rhs.id : lhs.updatedAt > rhs.updatedAt }
    }

    static func fold(events: [RunEvent]) -> [RunID: RunReceipt] {
        var result: [RunID: RunReceipt] = [:]
        for event in events {
            if event.kind == .submitted, result[event.runID] == nil {
                result[event.runID] = RunReceipt(id: event.runID, status: .submitted, commandText: event.payload.commandText ?? "", submittedAt: event.recordedAt, updatedAt: event.recordedAt)
            }
            guard var receipt = result[event.runID] else { continue }
            receipt.updatedAt = event.recordedAt
            receipt.eventCount += 1
            receipt.moduleID = event.payload.moduleID ?? receipt.moduleID
            receipt.planHash = event.payload.planHash ?? receipt.planHash
            receipt.summary = event.payload.summary ?? event.payload.message ?? receipt.summary
            receipt.artifactReference = event.payload.artifactReference ?? receipt.artifactReference
            receipt.resultActions = event.payload.resultActions ?? receipt.resultActions
            receipt.proposalCapabilities = event.payload.proposalCapabilities ?? receipt.proposalCapabilities
            receipt.proposalInput = event.payload.proposalInput ?? receipt.proposalInput
            receipt.proposalInputDigest = event.payload.proposalInputDigest ?? receipt.proposalInputDigest
            receipt.retryPolicyProfile = event.payload.retryPolicyProfile ?? receipt.retryPolicyProfile
            receipt.executionProfile = event.payload.executionProfile ?? receipt.executionProfile
            receipt.offline = event.payload.offline ?? receipt.offline
            receipt.allowedOperations = event.payload.allowedOperations ?? receipt.allowedOperations
            receipt.runtimeContext = event.payload.runtimeContext ?? receipt.runtimeContext
            switch event.kind {
            case .queued: receipt.status = .queued
            case .executionStarted: receipt.status = .running
            case .proposalStarted: receipt.status = .proposing
            case .proposalReady: receipt.status = .proposalReady
            case .confirmed: receipt.status = .confirmed
            case .dismissed: receipt.status = .dismissed
            case .expired: receipt.status = .expired
            case .cancellationRequested: receipt.cancellationRequested = true
            case .cancelled: receipt.status = .cancelled
            case .succeeded: receipt.status = .succeeded
            case .failed: receipt.status = .failed
            case .interrupted: receipt.status = .interrupted
            case .effectUncertain:
                receipt.effectCertainty = .uncertain
                updateEffect(on: &receipt, event: event, status: "uncertain")
            case .retentionTombstoned, .runtimeContextUpdated, .resultActionRecorded: break
            case .retryLinked: receipt.retryOf = event.payload.retryOf
            case .artifactAttached: if let artifact = event.payload.artifact { receipt.artifacts.append(artifact) }
            case .leaseAcquired: if let lease = event.payload.leaseID { receipt.activeLeases.insert(lease) }
            case .leaseReleased: if let lease = event.payload.leaseID { receipt.activeLeases.remove(lease) }
            case .effectSucceeded:
                receipt.effectCertainty = event.payload.effectCertainty ?? receipt.effectCertainty
                updateEffect(on: &receipt, event: event, status: "succeeded")
            case .effectFailed:
                receipt.effectCertainty = event.payload.effectCertainty ?? receipt.effectCertainty
                updateEffect(on: &receipt, event: event, status: "failed")
            case .cancellationAcknowledged:
                receipt.effectCertainty = event.payload.effectCertainty ?? receipt.effectCertainty
            case .submitted:
                if let lease = event.payload.leaseID { receipt.activeLeases.insert(lease) }
            case .effectAttempted:
                updateEffect(on: &receipt, event: event, status: "in-flight")
            }
            if receipt.status.isTerminal { receipt.activeLeases.removeAll() }
            result[event.runID] = receipt
        }
        return result
    }

    private static func updateEffect(on receipt: inout RunReceipt, event: RunEvent, status: String) {
        guard let effectID = event.payload.effectID else { return }
        var effects = receipt.effects ?? []
        let index = effects.firstIndex { $0.effectID == effectID }
        var effect = index.map { effects[$0] } ?? RunEffectReceipt(effectID: effectID, status: status)
        effect.status = status
        effect.adapterID = event.payload.adapterID ?? effect.adapterID
        effect.operationID = event.payload.operationID ?? effect.operationID
        effect.redactedTarget = event.payload.redactedTarget ?? effect.redactedTarget
        effect.targetDigest = event.payload.targetDigest ?? effect.targetDigest
        effect.idempotencyKey = event.payload.idempotencyKey ?? effect.idempotencyKey
        effect.idempotencyProven = event.payload.idempotencyProven ?? effect.idempotencyProven
        effect.ownerID = event.payload.ownerID ?? effect.ownerID
        effect.ownerPath = event.payload.ownerPath ?? effect.ownerPath
        effect.ownerAcknowledgement = event.payload.ownerAcknowledgement ?? effect.ownerAcknowledgement
        effect.boundedOutput = event.payload.boundedOutput ?? effect.boundedOutput
        effect.retrySafetyReason = event.payload.retrySafetyReason ?? effect.retrySafetyReason
        effect.reconciliationDisposition = event.payload.recoveryDisposition ?? effect.reconciliationDisposition
        if let index { effects[index] = effect } else { effects.append(effect) }
        receipt.effects = effects
    }

    private static func state(after kind: RunEventKind, prior: RunStatus?) -> RunStatus? {
        switch kind {
        case .submitted: .submitted
        case .queued: .queued
        case .executionStarted: .running
        case .proposalStarted: .proposing
        case .proposalReady: .proposalReady
        case .confirmed: .confirmed
        case .dismissed: .dismissed
        case .expired: .expired
        case .cancelled: .cancelled
        case .succeeded: .succeeded
        case .failed: .failed
        case .interrupted: .interrupted
        default: prior
        }
    }

    private func defaultLeaseID(for runID: RunID) -> String { "run:\(runID.rawValue):default" }

    private func terminalPayload(
        _ runID: RunID,
        message: String? = nil,
        certainty: EffectCertainty? = nil,
        summary: String? = nil,
        artifactReference: String? = nil,
        resultActions: [String] = []
    ) -> RunEventPayload {
        RunEventPayload(
            message: message,
            effectCertainty: certainty,
            leaseID: defaultLeaseID(for: runID),
            summary: summary,
            artifactReference: artifactReference,
            resultActions: resultActions
        )
    }

    /// Decodes every durable record before removing an incomplete final write.
    /// A malformed interior record therefore fails closed without altering the
    /// log, while a valid final record missing only its newline is preserved.
    static func readEventsRepairingOnlyTruncatedTail(at url: URL) throws -> [RunEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }
        if data.last == 0x0A { return try decodeCompleteEvents(data) }

        guard let newline = data.lastIndex(of: 0x0A) else {
            if let event = try? decoder.decode(RunEvent.self, from: data) {
                try appendNewline(to: url)
                return [event]
            }
            if isSyntacticallyValidJSON(data) {
                throw OmniRunError.corruptEventLog("final JSON event does not match the durable schema")
            }
            // There is no complete durable record to preserve. This is the
            // only safe zero-length truncated-tail repair.
            try truncate(url, at: 0)
            return []
        }

        let completePrefix = Data(data.prefix(through: newline))
        let events = try decodeCompleteEvents(completePrefix)
        let trailing = Data(data.dropFirst(newline + 1))
        if let event = try? decoder.decode(RunEvent.self, from: trailing) {
            try appendNewline(to: url)
            return events + [event]
        }
        if isSyntacticallyValidJSON(trailing) {
            throw OmniRunError.corruptEventLog("final JSON event does not match the durable schema")
        }
        try truncate(url, at: UInt64(newline + 1))
        return events
    }

    private static func isSyntacticallyValidJSON(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    private static func decodeCompleteEvents(_ data: Data) throws -> [RunEvent] {
        guard data.isEmpty || data.last == 0x0A else {
            throw OmniRunError.corruptEventLog("complete event data is missing a newline")
        }
        let body = data.dropLast()
        guard !body.isEmpty else { return [] }
        return try body.split(separator: 0x0A, omittingEmptySubsequences: false).map { line in
            guard !line.isEmpty else { throw OmniRunError.corruptEventLog("empty event record") }
            do { return try decoder.decode(RunEvent.self, from: Data(line)) }
            catch { throw OmniRunError.corruptEventLog(error.localizedDescription) }
        }
    }

    private static func appendNewline(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x0A]))
        try handle.synchronize()
    }

    private static func truncate(_ url: URL, at offset: UInt64) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: offset)
        try handle.synchronize()
    }

    private struct StorageVersionMarker: Codable {
        let storageVersion: Int

        enum CodingKeys: String, CodingKey {
            case storageVersion = "storage_version"
        }
    }

    /// `nil` deliberately means the Phase 4 marker-less event format.
    private static func readStorageVersion(at url: URL) throws -> Int? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let marker: StorageVersionMarker
        do {
            marker = try JSONDecoder().decode(StorageVersionMarker.self, from: Data(contentsOf: url))
        } catch {
            throw OmniRunError.invalidStorageVersionMetadata(error.localizedDescription)
        }
        guard marker.storageVersion > 0 else {
            throw OmniRunError.invalidStorageVersionMetadata("storage_version must be positive")
        }
        guard marker.storageVersion <= currentStorageVersion else {
            throw OmniRunError.unsupportedStorageVersion(marker.storageVersion)
        }
        return marker.storageVersion
    }

    private static func writeStorageVersion(_ version: Int, to url: URL) throws {
        let data = try JSONEncoder().encode(StorageVersionMarker(storageVersion: version))
        try data.write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = { let value = JSONEncoder(); value.dateEncodingStrategy = .millisecondsSince1970; value.outputFormatting = [.sortedKeys]; return value }()
    private static let decoder: JSONDecoder = { let value = JSONDecoder(); value.dateDecodingStrategy = .millisecondsSince1970; return value }()
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    private static func increment(_ bytes: inout [UInt8]) {
        for index in bytes.indices.reversed() {
            if bytes[index] < .max { bytes[index] += 1; return }
            bytes[index] = 0
        }
    }

    private static func encodeULID(milliseconds: UInt64, randomness: [UInt8]) -> String {
        var bytes = Array(repeating: UInt8(0), count: 16)
        for index in 0..<6 { bytes[index] = UInt8((milliseconds >> UInt64((5 - index) * 8)) & 0xFF) }
        bytes.replaceSubrange(6..<16, with: randomness)
        var output = ""
        var buffer = 0
        var bits = 2
        for byte in bytes {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 { bits -= 5; output.append(alphabet[(buffer >> bits) & 31]) }
        }
        return output
    }

    private static func decodeULID(_ value: String) -> [UInt8]? {
        guard value.count == 26 else { return nil }
        let lookup = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, $0.offset) })
        var bytes: [UInt8] = []
        var buffer = 0
        var bits = 0
        for character in value {
            guard let digit = lookup[character] else { return nil }
            buffer = (buffer << 5) | digit
            bits += 5
            if bits >= 8 { bits -= 8; bytes.append(UInt8((buffer >> bits) & 0xFF)) }
        }
        return bytes.count == 16 ? bytes : nil
    }
}

private final class ExclusiveStoreWriterLock: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let path: String

    init(url: URL) throws {
        path = url.path
        fileDescriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else { throw OmniRunError.storeAlreadyOpen(url.path) }
        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(fileDescriptor)
            throw OmniRunError.storeAlreadyOpen(url.path)
        }
    }

    deinit {
        _ = flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class SQLiteRunIndex {
    private let url: URL
    private var database: OpaquePointer?

    init(url: URL, replacingCorruptFile: Bool = false) throws {
        self.url = url
        if replacingCorruptFile {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        try open()
    }

    deinit { sqlite3_close(database) }

    func replace(with receipts: some Collection<RunReceipt>) throws {
        try execute("BEGIN IMMEDIATE; DELETE FROM runs;")
        do {
            for receipt in receipts {
                let json = try String(data: JSONEncoder().encode(receipt), encoding: .utf8) ?? "{}"
                let sql = "INSERT INTO runs (id, status, updated_at, receipt_json) VALUES (?, ?, ?, ?);"
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error }
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_text(statement, 1, receipt.id.rawValue, -1, sqliteTransient)
                sqlite3_bind_text(statement, 2, receipt.status.rawValue, -1, sqliteTransient)
                sqlite3_bind_double(statement, 3, receipt.updatedAt.timeIntervalSince1970)
                sqlite3_bind_text(statement, 4, json, -1, sqliteTransient)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw error }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func query(activeOnly: Bool, limit: Int?) throws -> [RunReceipt] {
        var sql = "SELECT receipt_json FROM runs"
        if activeOnly {
            let terminal = [RunStatus.succeeded, .failed, .cancelled, .interrupted, .dismissed, .expired]
                .map { "'\($0.rawValue)'" }
                .joined(separator: ",")
            sql += " WHERE status NOT IN (\(terminal))"
        }
        sql += " ORDER BY updated_at DESC, id DESC"
        if let limit { sql += " LIMIT \(limit)" }
        sql += ";"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error }
        defer { sqlite3_finalize(statement) }
        var values: [RunReceipt] = []
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { throw OmniRunError.sqlite("missing receipt_json") }
            do {
                values.append(try JSONDecoder().decode(RunReceipt.self, from: Data(String(cString: text).utf8)))
            } catch {
                throw OmniRunError.sqlite("invalid receipt_json: \(error.localizedDescription)")
            }
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else { throw error }
        return values
    }

    func dataVersion() throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA data_version;", -1, &statement, nil) == SQLITE_OK else { throw error }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error }
        return sqlite3_column_int64(statement, 0)
    }

    private func open() throws {
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw error }
        // DELETE journaling keeps this disposable index independently replaceable even
        // while another development-store instance still has an older inode open.
        try execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, status TEXT NOT NULL, updated_at REAL NOT NULL, receipt_json TEXT NOT NULL);")
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let text = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw OmniRunError.sqlite(text)
        }
    }

    private var error: OmniRunError { .sqlite(database.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "database unavailable") }
}
