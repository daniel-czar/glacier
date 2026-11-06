import Foundation

/// The three construction profiles are deliberately explicit. Development
/// composition exposes only `pureFake` and `replica`; `installedLive` is a
/// dormant source-composition profile and has no CLI spelling.
public enum OmniExecutionProfile: String, Codable, Sendable, Equatable {
    case pureFake = "pure-fake"
    case replica = "real-adapter-replica"
    case installedLive = "installed-live"
    case standalone = "standalone"
}

/// Exact owner operations. These are intentionally narrower than filesystem,
/// process, workspace, or shell handles.
public enum OwnerOperation: String, Codable, CaseIterable, Sendable, Hashable {
    case openSearchURL = "open-search-url"
    case captureLink = "capture-link"
    case appendLedger = "append-ledger"
    case appendOfficeQueue = "append-office-queue"
    /// Pushes onto the five-deep stash stack (amendment 1.7.0). The name and
    /// raw value predate the stack; stored receipts and effects carry them.
    case replaceCurrentStash = "replace-current-stash"
    case captureBaseNote = "capture-base-note"
    case readRegisteredIndex = "read-registered-index"
    case openResolvedTarget = "open-resolved-target"
    case revealResolvedTarget = "reveal-resolved-target"
    case openOmniSettings = "open-omni-settings"
    case openModelSettings = "open-model-settings"
    case saveSettings = "save-settings"
    case translateLocal = "translate-local"

    public var capability: Capability? {
        switch self {
        case .openSearchURL: .openURL
        case .captureLink: .captureLink
        case .appendLedger: .appendLedger
        case .appendOfficeQueue: .appendOfficeQueue
        case .replaceCurrentStash: .writeCurrentStash
        case .captureBaseNote: .captureBaseNote
        case .readRegisteredIndex: .readIndex
        case .openResolvedTarget: .openTarget
        case .revealResolvedTarget: .revealTarget
        case .openOmniSettings, .openModelSettings, .saveSettings: .writeSettings
        case .translateLocal: nil
        }
    }

    public var isMutation: Bool {
        switch self {
        case .captureLink, .appendLedger, .appendOfficeQueue, .replaceCurrentStash,
             .captureBaseNote, .saveSettings:
            true
        case .openSearchURL, .readRegisteredIndex, .openResolvedTarget,
             .revealResolvedTarget, .openOmniSettings, .openModelSettings,
             .translateLocal:
            false
        }
    }

    public var mayUseNetwork: Bool { self == .openSearchURL }

    public var requiresReceiptBoundary: Bool {
        isMutation || [
            OwnerOperation.openSearchURL,
            .openResolvedTarget,
            .revealResolvedTarget,
            .openOmniSettings,
            .openModelSettings,
        ].contains(self)
    }
}

public struct OwnerTargetDescriptor: Codable, Sendable, Equatable {
    public let ownerID: String
    public let operation: OwnerOperation
    public let redactedTarget: String
    public let targetDigest: String

    public init(ownerID: String, operation: OwnerOperation, redactedTarget: String, targetDigest: String) {
        self.ownerID = ownerID
        self.operation = operation
        self.redactedTarget = redactedTarget
        self.targetDigest = targetDigest
    }
}

public struct OwnerOperationRequest: Sendable, Equatable {
    public let runID: String
    public let payload: String
    public let referenceID: String?
    public let offline: Bool
    public let explicitUserSave: Bool
    /// The material's source app, from the run's provenance. Only the stash
    /// keeps it (an entry's `source · when` line); it grants nothing.
    public let source: String?

    public init(
        runID: String,
        payload: String,
        referenceID: String? = nil,
        offline: Bool = false,
        explicitUserSave: Bool = false,
        source: String? = nil
    ) {
        self.runID = runID
        self.payload = payload
        self.referenceID = referenceID
        self.offline = offline
        self.explicitUserSave = explicitUserSave
        self.source = source
    }
}

public struct OwnerOperationHandle: Sendable {
    public let operation: OwnerOperation
    public let profile: OmniExecutionProfile
    public let target: OwnerTargetDescriptor
    private let invokeImplementation: @Sendable (OwnerOperationRequest) async -> ModuleExecutionOutcome
    private let reconcileImplementation: @Sendable (String, CommandPlan) async -> ReconciliationDisposition

    public init(
        operation: OwnerOperation,
        profile: OmniExecutionProfile,
        target: OwnerTargetDescriptor,
        invoke: @escaping @Sendable (OwnerOperationRequest) async -> ModuleExecutionOutcome,
        reconcile: @escaping @Sendable (String, CommandPlan) async -> ReconciliationDisposition = { _, _ in .unavailable }
    ) {
        self.operation = operation
        self.profile = profile
        self.target = target
        invokeImplementation = invoke
        reconcileImplementation = reconcile
    }

    public func invoke(_ request: OwnerOperationRequest) async -> ModuleExecutionOutcome {
        await invokeImplementation(request)
    }

    public func reconcile(runID: String, plan: CommandPlan) async -> ReconciliationDisposition {
        await reconcileImplementation(runID, plan)
    }
}

public struct CapabilityEnvironment: Sendable {
    public let profile: OmniExecutionProfile
    public let installedPolicy: Set<OwnerOperation>
    private let handlesByOperation: [OwnerOperation: OwnerOperationHandle]

    public init(profile: OmniExecutionProfile, installedPolicy: Set<OwnerOperation>, handles: [OwnerOperationHandle]) throws {
        var values: [OwnerOperation: OwnerOperationHandle] = [:]
        for handle in handles {
            guard handle.profile == profile, values[handle.operation] == nil else {
                throw OmniCoreError.ownerOperationProfileMismatch(handle.operation)
            }
            values[handle.operation] = handle
        }
        self.profile = profile
        self.installedPolicy = installedPolicy
        handlesByOperation = values
    }

    public func handle(for operation: OwnerOperation) -> OwnerOperationHandle? {
        handlesByOperation[operation]
    }
}

public struct ExecutionPolicySnapshot: Codable, Sendable, Equatable {
    public let profile: OmniExecutionProfile
    public let offline: Bool
    public let allowedOperations: [OwnerOperation]

    public init(profile: OmniExecutionProfile, offline: Bool, allowedOperations: Set<OwnerOperation>) {
        self.profile = profile
        self.offline = offline
        self.allowedOperations = allowedOperations.sorted { $0.rawValue < $1.rawValue }
    }
}
