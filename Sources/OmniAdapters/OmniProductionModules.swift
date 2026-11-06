import Foundation
import OmniCore

public struct ProductionTier2UnavailableSource: Tier2ProposalSource {
    public init() {}

    public func propose(for intent: ParsedIntent) async throws -> Tier2Proposal {
        throw ProductionModuleError.unavailableUntilPhase4("tier2-proposal")
    }
}

public enum ProductionModuleError: Error, Sendable, Equatable, CustomStringConvertible {
    case unavailableUntilPhase4(String)
    case invalidInput(String)
    case invalidPlan

    public var description: String {
        switch self {
        case .unavailableUntilPhase4(let moduleID): "\(moduleID) remains unavailable until Phase 4"
        case .invalidInput(let reason): reason
        case .invalidPlan: "production module received a mismatched plan"
        }
    }
}

/// The production catalog is keyed by the frozen module ID. Command tokens stay
/// in the manifest/router; neither the catalog nor execution switches on text.
public struct ProductionModuleCatalog: Sendable {
    public let registry: ModuleRegistry

    public init(
        manifest: CommandManifest,
        declarations: [ModuleDeclaration],
        environment: CapabilityEnvironment
    ) throws {
        let operations: [String: OwnerOperation] = [
            "translate": .translateLocal,
            "open.search": .openSearchURL,
            "capture.favorite": .captureLink,
            "capture.todo": .appendLedger,
            "cache.remind": .appendOfficeQueue,
            "cache.stash": .replaceCurrentStash,
            "capture.base": .captureBaseNote,
            "find.indexed": .readRegisteredIndex,
            "open.target": .openResolvedTarget,
            "reveal.target": .revealResolvedTarget,
            "settings.omni": .openOmniSettings,
            "settings.model": .openModelSettings,
        ]
        let declarationsByID = Dictionary(uniqueKeysWithValues: declarations.map { ($0.moduleID, $0) })
        let factories = try manifest.moduleIDs.sorted().map { moduleID -> AnyCommandModuleFactory in
            guard let declaration = declarationsByID[moduleID],
                  let command = manifest.command(for: declaration.tokens.canonical)
            else { throw OmniCoreError.unknownModule(moduleID) }
            let descriptor = ModuleDescriptor(
                moduleID: moduleID,
                moduleVersion: declaration.moduleVersion,
                execution: declaration.executionPath.kind,
                capabilities: Set(command.capabilities),
                policies: declaration.typedPolicies
            )
            let operation = operations[moduleID]
            return AnyCommandModuleFactory(moduleID: moduleID) {
                ProductionCommandModule(descriptor: descriptor, operation: operation, environment: environment)
            }
        }
        registry = try ModuleRegistry(factories)
        try ManifestParityValidator().validate(manifest: manifest, declarations: declarations, registry: registry)
    }
}

public struct ProductionCommandModule: CommandModule {
    public let descriptor: ModuleDescriptor
    public let operation: OwnerOperation?
    private let environment: CapabilityEnvironment

    public init(descriptor: ModuleDescriptor, operation: OwnerOperation?, environment: CapabilityEnvironment) {
        self.descriptor = descriptor
        self.operation = operation
        self.environment = environment
    }

    public func validate(input: ModuleInput) throws {
        guard let operation else { throw ProductionModuleError.unavailableUntilPhase4(descriptor.moduleID) }
        let payload = input.payloadText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch operation {
        case .captureLink:
            guard let url = URL(string: payload),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  url.host != nil
            else { throw ProductionModuleError.invalidInput("/fav requires one HTTP(S) URL") }
        case .appendLedger, .appendOfficeQueue:
            guard !payload.isEmpty, payload.rangeOfCharacter(from: .newlines) == nil else {
                throw ProductionModuleError.invalidInput("owner append input must be one non-empty line")
            }
        case .openResolvedTarget, .revealResolvedTarget:
            guard input.references.count == 1 || payload.contains(":") else {
                throw ProductionModuleError.invalidInput("open/reveal requires one stable namespaced owner ID")
            }
        case .openOmniSettings, .openModelSettings:
            guard payload.isEmpty else { throw ProductionModuleError.invalidInput("settings open accepts no payload") }
        case .replaceCurrentStash:
            // `/stash:N` names an entry to import (C96); the pad resolves it
            // and never sends it. Only a bare `/stash` with text pushes.
            guard input.tokenValues["/stash"] == nil else {
                throw ProductionModuleError.invalidInput("/stash:N imports an entry in the pad; it never pushes")
            }
            guard !payload.isEmpty else { throw ProductionModuleError.invalidInput("command payload is required") }
        default:
            guard !payload.isEmpty else { throw ProductionModuleError.invalidInput("command payload is required") }
        }
    }

    public func makePlan(input: ModuleInput) throws -> CommandPlan {
        try validate(input: input)
        guard let operation else { throw ProductionModuleError.unavailableUntilPhase4(descriptor.moduleID) }
        return CommandPlan(
            moduleID: descriptor.moduleID,
            input: input,
            capabilitySet: descriptor.capabilities,
            ownerOperation: operation,
            offline: input.modes.contains("/offline"),
            expectedEffectCount: operation.requiresReceiptBoundary ? 1 : 0
        )
    }

    public func start(plan: CommandPlan, capabilities: CapabilityBroker, runID: String) async throws -> any RunExecutionHandle {
        guard plan.moduleID == descriptor.moduleID,
              plan.capabilitySet == descriptor.capabilities,
              plan.ownerOperation == operation,
              let operation
        else { throw ProductionModuleError.invalidPlan }
        let handle = try capabilities.operationHandle(for: operation)
        let referenceID = plan.input.references.count == 1 ? plan.input.references[0].id : nil
        let payload: String
        switch operation {
        case .openSearchURL, .captureBaseNote:
            // Selected searches and captured fragments carry literal material;
            // trimming a note here would destroy leading indentation.
            payload = plan.input.payloadText
        case .replaceCurrentStash:
            // The stash keeps the material's lines (its top row shows three).
            payload = OmniStashText.payload(fromCommandText: plan.input.rawText)
        default:
            payload = plan.input.payloadText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let request = OwnerOperationRequest(
            runID: runID,
            payload: payload,
            referenceID: referenceID,
            offline: plan.offline,
            source: operation == .replaceCurrentStash ? plan.materialSource : nil
        )
        return OwnerOperationExecutionHandle(runID: runID, operation: handle, request: request)
    }

    public func reconcile(runID: String, plan: CommandPlan) async -> ReconciliationDisposition {
        guard let operation,
              plan.ownerOperation == operation,
              let handle = environment.handle(for: operation),
              environment.installedPolicy.contains(operation)
        else { return .unavailable }
        return await handle.reconcile(runID: runID, plan: plan)
    }
}

public actor OwnerOperationExecutionHandle: RunExecutionHandle {
    public nonisolated let runID: String
    private let operation: OwnerOperationHandle
    private let request: OwnerOperationRequest
    private var task: Task<ModuleExecutionOutcome, Never>?
    private var cached: ModuleExecutionOutcome?

    public init(runID: String, operation: OwnerOperationHandle, request: OwnerOperationRequest) {
        self.runID = runID
        self.operation = operation
        self.request = request
    }

    public func value() async -> ModuleExecutionOutcome {
        if let cached { return cached }
        if let task { return await task.value }
        let operation = self.operation
        let request = self.request
        let task = Task { await operation.invoke(request) }
        self.task = task
        let outcome = await task.value
        cached = outcome
        self.task = nil
        return outcome
    }

    public func requestCancellation() async -> CancellationAcknowledgement {
        if cached != nil {
            return CancellationAcknowledgement(
                requestObserved: false,
                taskOrProcessStopped: true,
                ownerAcknowledged: true,
                effectCertainty: .certain
            )
        }
        guard let task else {
            return CancellationAcknowledgement(
                requestObserved: true,
                taskOrProcessStopped: true,
                ownerAcknowledged: false,
                effectCertainty: .uncertain
            )
        }
        task.cancel()
        let outcome = await task.value
        cached = outcome
        self.task = nil
        if case .succeeded = outcome {
            return CancellationAcknowledgement(
                requestObserved: false,
                taskOrProcessStopped: true,
                ownerAcknowledged: true,
                effectCertainty: .certain
            )
        }
        return CancellationAcknowledgement(
            requestObserved: true,
            taskOrProcessStopped: true,
            ownerAcknowledged: false,
            effectCertainty: .uncertain
        )
    }
}
