import Foundation
import OmniCore

public struct RunID: RawRepresentable, Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
        guard rawValue.count == 29,
              rawValue.hasPrefix("oi_"),
              rawValue.dropFirst(3).allSatisfy({ alphabet.contains($0) })
        else { return nil }
        self.rawValue = rawValue
    }

    init(unchecked rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }
    public static func < (lhs: RunID, rhs: RunID) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum RunStatus: String, Codable, Sendable, CaseIterable {
    case submitted
    case queued
    case running
    case succeeded
    case failed
    case cancelled
    case interrupted
    case proposing
    case proposalReady = "proposal_ready"
    case confirmed
    case dismissed
    case expired

    public var isTerminal: Bool {
        switch self {
        case .cancelled, .succeeded, .failed, .interrupted, .dismissed, .expired: true
        case .submitted, .queued, .running, .proposing, .proposalReady, .confirmed: false
        }
    }
}

public enum EffectCertainty: String, Codable, Sendable {
    case certain
    case uncertain
}

public enum EffectOutcome: String, Codable, Sendable {
    case succeeded
    case failed
    case unknown
}

public struct RunEffectReceipt: Codable, Equatable, Sendable {
    public let effectID: String
    public var status: String
    public var adapterID: String?
    public var operationID: String?
    public var redactedTarget: String?
    public var targetDigest: String?
    public var idempotencyKey: String?
    public var idempotencyProven: Bool?
    public var ownerID: String?
    public var ownerPath: String?
    public var ownerAcknowledgement: String?
    public var boundedOutput: String?
    public var retrySafetyReason: String?
    public var reconciliationDisposition: String?

    public init(effectID: String, status: String) {
        self.effectID = effectID
        self.status = status
    }
}

public struct CancellationAcknowledgement: Codable, Equatable, Sendable {
    public let priorRequestObserved: Bool
    public let executionStoppedAndReaped: Bool
    public let ownerAcknowledged: Bool
    public let effectCertainty: EffectCertainty

    public init(priorRequestObserved: Bool, executionStoppedAndReaped: Bool, ownerAcknowledged: Bool, effectCertainty: EffectCertainty) {
        self.priorRequestObserved = priorRequestObserved
        self.executionStoppedAndReaped = executionStoppedAndReaped
        self.ownerAcknowledged = ownerAcknowledged
        self.effectCertainty = effectCertainty
    }

    public var provesCleanCancellation: Bool {
        priorRequestObserved && executionStoppedAndReaped && ownerAcknowledged && effectCertainty == .certain
    }
}

public enum RunEventKind: String, Codable, Sendable {
    case submitted
    case queued
    case executionStarted = "execution_started"
    case proposalStarted = "proposal_started"
    case proposalReady = "proposal_ready"
    case confirmed
    case dismissed
    case expired
    case effectAttempted = "effect_attempted"
    case effectSucceeded = "effect_succeeded"
    case effectFailed = "effect_failed"
    case cancellationRequested = "cancellation_requested"
    case cancellationAcknowledged = "cancellation_acknowledged"
    case cancelled
    case succeeded
    case failed
    case interrupted
    case effectUncertain = "effect_uncertain"
    case retryLinked = "retry_linked"
    case artifactAttached = "artifact_attached"
    case retentionTombstoned = "retention_tombstone"
    case leaseAcquired = "lease_acquired"
    case leaseReleased = "lease_released"
    case runtimeContextUpdated = "runtime_context_updated"
    case resultActionRecorded = "result_action_recorded"
}

public enum RunActor: String, Codable, Sendable {
    case user
    case runtime
    case executor
    case recovery
    case retention
}

public struct RunEventPayload: Codable, Equatable, Sendable {
    public var commandText: String?
    public var message: String?
    public var effectID: String?
    public var effectOutcome: EffectOutcome?
    public var effectCertainty: EffectCertainty?
    public var retryOf: RunID?
    public var artifact: String?
    public var leaseID: String?
    public var adapterID: String?
    public var operationID: String?
    public var idempotencyKey: String?
    public var idempotencyProven: Bool?
    public var ownerAcknowledgement: String?
    public var stopAcknowledgement: String?
    public var recoveryDisposition: String?
    public var moduleID: String?
    public var planHash: String?
    public var summary: String?
    public var artifactReference: String?
    public var resultActions: [String]?
    public var proposalCapabilities: [String]?
    public var proposalInput: String?
    public var proposalInputDigest: String?
    public var retryPolicyProfile: String?
    public var redactedTarget: String?
    public var targetDigest: String?
    public var ownerID: String?
    public var ownerPath: String?
    public var boundedOutput: String?
    public var retrySafetyReason: String?
    public var executionProfile: String?
    public var offline: Bool?
    public var allowedOperations: [String]?
    public var runtimeContext: RuntimeRunContext?

    public init(
        commandText: String? = nil,
        message: String? = nil,
        effectID: String? = nil,
        effectOutcome: EffectOutcome? = nil,
        effectCertainty: EffectCertainty? = nil,
        retryOf: RunID? = nil,
        artifact: String? = nil,
        leaseID: String? = nil,
        adapterID: String? = nil,
        operationID: String? = nil,
        idempotencyKey: String? = nil,
        idempotencyProven: Bool? = nil,
        ownerAcknowledgement: String? = nil,
        stopAcknowledgement: String? = nil,
        recoveryDisposition: String? = nil,
        moduleID: String? = nil,
        planHash: String? = nil,
        summary: String? = nil,
        artifactReference: String? = nil,
        resultActions: [String]? = nil,
        proposalCapabilities: [String]? = nil,
        proposalInput: String? = nil,
        proposalInputDigest: String? = nil,
        retryPolicyProfile: String? = nil,
        redactedTarget: String? = nil,
        targetDigest: String? = nil,
        ownerID: String? = nil,
        ownerPath: String? = nil,
        boundedOutput: String? = nil,
        retrySafetyReason: String? = nil,
        executionProfile: String? = nil,
        offline: Bool? = nil,
        allowedOperations: [String]? = nil,
        runtimeContext: RuntimeRunContext? = nil
    ) {
        self.commandText = commandText
        self.message = message
        self.effectID = effectID
        self.effectOutcome = effectOutcome
        self.effectCertainty = effectCertainty
        self.retryOf = retryOf
        self.artifact = artifact
        self.leaseID = leaseID
        self.adapterID = adapterID
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.idempotencyProven = idempotencyProven
        self.ownerAcknowledgement = ownerAcknowledgement
        self.stopAcknowledgement = stopAcknowledgement
        self.recoveryDisposition = recoveryDisposition
        self.moduleID = moduleID
        self.planHash = planHash
        self.summary = summary
        self.artifactReference = artifactReference
        self.resultActions = resultActions
        self.proposalCapabilities = proposalCapabilities
        self.proposalInput = proposalInput
        self.proposalInputDigest = proposalInputDigest
        self.retryPolicyProfile = retryPolicyProfile
        self.redactedTarget = redactedTarget
        self.targetDigest = targetDigest
        self.ownerID = ownerID
        self.ownerPath = ownerPath
        self.boundedOutput = boundedOutput
        self.retrySafetyReason = retrySafetyReason
        self.executionProfile = executionProfile
        self.offline = offline
        self.allowedOperations = allowedOperations
        self.runtimeContext = runtimeContext
    }
}

public struct RunEvent: Codable, Equatable, Sendable {
    public let eventID: String
    public let runID: RunID
    public let sequence: Int
    public let recordedAt: Date
    public let kind: RunEventKind
    public let actor: RunActor
    public let moduleVersion: String
    public let manifestVersion: String
    public let priorState: RunStatus?
    public let newState: RunStatus?
    public let payload: RunEventPayload

    public init(eventID: String, runID: RunID, sequence: Int, recordedAt: Date, kind: RunEventKind, actor: RunActor, moduleVersion: String, manifestVersion: String, priorState: RunStatus?, newState: RunStatus?, payload: RunEventPayload) {
        self.eventID = eventID
        self.runID = runID
        self.sequence = sequence
        self.recordedAt = recordedAt
        self.kind = kind
        self.actor = actor
        self.moduleVersion = moduleVersion
        self.manifestVersion = manifestVersion
        self.priorState = priorState
        self.newState = newState
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case runID = "run_id"
        case sequence
        case recordedAt = "timestamp"
        case kind = "event_kind"
        case actor
        case moduleVersion = "module_version"
        case manifestVersion = "manifest_version"
        case priorState = "prior_state"
        case newState = "new_state"
        case payload = "typed_detail"
    }
}

public struct RunReceipt: Codable, Equatable, Sendable, Identifiable {
    public let id: RunID
    public var status: RunStatus
    public var commandText: String
    public var submittedAt: Date
    public var updatedAt: Date
    public var retryOf: RunID?
    public var artifacts: [String]
    public var activeLeases: Set<String>
    public var cancellationRequested: Bool
    public var effectCertainty: EffectCertainty?
    public var eventCount: Int
    public var moduleID: String?
    public var planHash: String?
    public var summary: String?
    public var artifactReference: String?
    public var resultActions: [String]
    public var proposalCapabilities: [String]
    public var proposalInput: String?
    public var proposalInputDigest: String?
    public var retryPolicyProfile: String?
    public var executionProfile: String?
    public var offline: Bool?
    public var allowedOperations: [String]?
    public var effects: [RunEffectReceipt]?
    public var runtimeContext: RuntimeRunContext?

    public init(id: RunID, status: RunStatus, commandText: String, submittedAt: Date, updatedAt: Date, retryOf: RunID? = nil, artifacts: [String] = [], activeLeases: Set<String> = [], cancellationRequested: Bool = false, effectCertainty: EffectCertainty? = nil, eventCount: Int = 0, moduleID: String? = nil, planHash: String? = nil, summary: String? = nil, artifactReference: String? = nil, resultActions: [String] = [], proposalCapabilities: [String] = [], proposalInput: String? = nil, proposalInputDigest: String? = nil, retryPolicyProfile: String? = nil, executionProfile: String? = nil, offline: Bool? = nil, allowedOperations: [String]? = nil, effects: [RunEffectReceipt]? = nil) {
        self.id = id
        self.status = status
        self.commandText = commandText
        self.submittedAt = submittedAt
        self.updatedAt = updatedAt
        self.retryOf = retryOf
        self.artifacts = artifacts
        self.activeLeases = activeLeases
        self.cancellationRequested = cancellationRequested
        self.effectCertainty = effectCertainty
        self.eventCount = eventCount
        self.moduleID = moduleID
        self.planHash = planHash
        self.summary = summary
        self.artifactReference = artifactReference
        self.resultActions = resultActions
        self.proposalCapabilities = proposalCapabilities
        self.proposalInput = proposalInput
        self.proposalInputDigest = proposalInputDigest
        self.retryPolicyProfile = retryPolicyProfile
        self.executionProfile = executionProfile
        self.offline = offline
        self.allowedOperations = allowedOperations
        self.effects = effects
    }

    public var suppressesIdleExit: Bool { !status.isTerminal || !activeLeases.isEmpty }
}

public enum OmniRunError: Error, Equatable, Sendable, CustomStringConvertible {
    case developmentRootMustBeAbsolute
    case developmentRootMissing
    case developmentRootNotDirectory
    case developmentRootIsSymlink
    case forbiddenDevelopmentRoot(String)
    case pathEscapesDevelopmentRoot
    case unknownRun(RunID)
    case illegalTransition(from: RunStatus, event: RunEventKind)
    case invalidArtifactPath
    case missingEffectAttempt(String)
    case duplicateEffectOutcome(String)
    case sqlite(String)
    case corruptEventLog(String)
    case unsupportedStorageVersion(Int)
    case invalidStorageVersionMetadata(String)
    case storeAlreadyOpen(String)
    case followUpRequiresSucceededRun(RunStatus)
    case followUpAlreadyPending
    case invalidFollowUpSourceVersion(Int)
    case emptyFollowUpResult

    public var description: String {
        switch self {
        case .developmentRootMustBeAbsolute: "development root must be absolute"
        case .developmentRootMissing: "development root must exist"
        case .developmentRootNotDirectory: "development root must be a directory"
        case .developmentRootIsSymlink: "development root must not contain symlink resolution"
        case .forbiddenDevelopmentRoot(let path): "development root is forbidden: \(path)"
        case .pathEscapesDevelopmentRoot: "path escapes development root"
        case .unknownRun(let id): "unknown run: \(id)"
        case .illegalTransition(let status, let event): "illegal \(event.rawValue) from \(status.rawValue)"
        case .invalidArtifactPath: "artifact path must be a safe relative path"
        case .missingEffectAttempt(let effectID): "effect outcome has no matching attempt: \(effectID)"
        case .duplicateEffectOutcome(let effectID): "effect already has an outcome: \(effectID)"
        case .sqlite(let message): "sqlite error: \(message)"
        case .corruptEventLog(let message): "corrupt event log: \(message)"
        case .unsupportedStorageVersion(let version): "unsupported durable storage version: \(version)"
        case .invalidStorageVersionMetadata(let message): "invalid durable storage metadata: \(message)"
        case .storeAlreadyOpen(let path): "development run store is already open: \(path)"
        case .followUpRequiresSucceededRun(let status): "follow-up requires a succeeded run, found \(status.rawValue)"
        case .followUpAlreadyPending: "follow-up is already pending"
        case .invalidFollowUpSourceVersion(let number): "follow-up source version does not exist: \(number)"
        case .emptyFollowUpResult: "follow-up result must not be empty"
        }
    }
}
