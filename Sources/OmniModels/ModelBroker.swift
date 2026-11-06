import Foundation
import OmniCore

public struct ModelProviderDescriptor: Sendable, Equatable {
    public let providerID: String
    public let providerClass: ModelProviderClass
    public let isRemote: Bool
    public let isAvailable: Bool
    /// Evidence is command-specific; a fast provider qualified for translation
    /// is not thereby qualified for email drafting.
    public let qualityValidatedCommandIDs: Set<String>

    public init(
        providerID: String,
        providerClass: ModelProviderClass,
        isRemote: Bool,
        isAvailable: Bool = true,
        qualityValidatedCommandIDs: Set<String> = []
    ) {
        self.providerID = providerID
        self.providerClass = providerClass
        self.isRemote = isRemote
        self.isAvailable = isAvailable
        self.qualityValidatedCommandIDs = qualityValidatedCommandIDs
    }
}

public struct ModelProviderResponse: Sendable, Equatable {
    public let text: String
    public let usage: ModelUsage?

    public init(text: String, usage: ModelUsage? = nil) {
        self.text = text
        self.usage = usage
    }
}

/// All concrete inference integrations, including fixture transports, pass
/// through this boundary. It has no capability or owner-operation handle.
public protocol ModelProvider: Sendable {
    var descriptor: ModelProviderDescriptor { get }
    func generate(_ request: ModelGenerationRequest) async throws -> ModelProviderResponse
}

public protocol ModelGenerating: Sendable {
    func execute(_ request: ModelGenerationRequest) async throws -> ModelBrokerResult
    func cancellationRecord(for request: ModelGenerationRequest) async -> ModelExecutionRecord
}

public extension ModelGenerating {
    func cancellationRecord(for request: ModelGenerationRequest) async -> ModelExecutionRecord {
        ModelExecutionRecord(
            runtimePolicyVersion: "unavailable",
            commandID: request.commandID,
            runID: request.runID,
            offline: request.offline,
            styleGuide: request.styleGuide,
            contextGuides: request.contextGuides,
            attempts: []
        )
    }
}

public struct ModelBrokerResult: Sendable, Equatable {
    public let response: ModelProviderResponse
    public let record: ModelExecutionRecord

    public init(response: ModelProviderResponse, record: ModelExecutionRecord) {
        self.response = response
        self.record = record
    }
}

public enum ModelBrokerError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingPolicy(commandID: String)
    case invalidSettings(String)
    case unavailable(ModelExecutionRecord)
    case failed(ModelExecutionRecord)
    case cancelled(ModelExecutionRecord)

    public var record: ModelExecutionRecord? {
        switch self {
        case .missingPolicy, .invalidSettings: nil
        case .unavailable(let record), .failed(let record), .cancelled(let record): record
        }
    }

    public var description: String {
        switch self {
        case .missingPolicy(let commandID): return "No runtime model policy configured for \(commandID)."
        case .invalidSettings(let reason): return "Invalid model settings: \(reason)"
        case .unavailable(let record):
            if let reason = Self.leadingReason(record) { return "Model unavailable: \(reason)" }
            return record.offline ? "No offline path configured." : "No configured model provider is available."
        case .failed(let record):
            if let reason = Self.leadingReason(record) { return "Model generation failed: \(reason)" }
            return "All configured model providers failed."
        case .cancelled: return "Model generation was cancelled."
        }
    }

    /// Policy 6.0.0 records carry a typed failure per attempt; surface the first
    /// dispatched failure, else the first exclusion, so the user sees the cause.
    private static func leadingReason(_ record: ModelExecutionRecord) -> String? {
        let attempts = record.attempts
        // Historical v4/v5 records keep their original wording.
        guard attempts.contains(where: { $0.identity != nil }) || attempts.contains(where: { $0.providerID.hasPrefix("settings-storage") || $0.providerID.hasPrefix("needs-configuration:") }) else { return nil }
        let primary = attempts.first { $0.outcome == .failed && $0.identity != nil } ?? attempts.first { $0.identity != nil } ?? attempts.first
        guard let primary else { return nil }
        guard let identity = primary.identity else { return "model settings need attention" }
        let label = ProviderRuntimeCatalog.profile(identity.profileID)?.displayName ?? ""
        let provider = ModelHumanFailure.providerName(displayName: label, driverID: identity.driverID)
        guard let kind = identity.failure else { return "\(provider): request failed" }
        return "\(provider): \(ModelHumanFailure.reason(kind: kind, driverID: identity.driverID, detail: primary.detail))"
    }
}

/// Applies only a supplied, versioned command ladder. It cannot be reached by
/// parser/routing code, select a command, or expand a module's capabilities.
public struct ModelBroker: Sendable {
    public let policy: ModelRuntimePolicy
    private let providers: [any ModelProvider]
    private let settings: ModelSettings

    public init(
        policy: ModelRuntimePolicy = .phase4V1,
        providers: [any ModelProvider],
        settings: ModelSettings? = nil
    ) {
        self.policy = policy
        self.providers = providers.sorted { $0.descriptor.providerID < $1.descriptor.providerID }
        self.settings = settings ?? ModelSettings(runtimePolicyVersion: policy.version)
    }

    /// Reading the current selection does not mutate it or trigger a provider.
    public func settingsSnapshot() -> ModelSettings { settings }

    /// Rejects stale policies, deterministic-command settings, undeclared
    /// provider classes, and unqualified promotions before a save.
    public func validateSettings(_ candidate: ModelSettings) throws {
        guard candidate.runtimePolicyVersion == policy.version else {
            throw ModelBrokerError.invalidSettings("runtime policy version does not match")
        }
        guard !candidate.configurationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              candidate.configurationVersion > 0
        else { throw ModelBrokerError.invalidSettings("configuration identity is required") }
        let commandIDs = candidate.commandSettings.map(\.commandID)
        guard Set(commandIDs).count == commandIDs.count else {
            throw ModelBrokerError.invalidSettings("duplicate command settings")
        }
        for command in candidate.commandSettings {
            guard let runtimeCommand = policy.command(named: command.commandID) else {
                throw ModelBrokerError.invalidSettings("\(command.commandID) has no model policy")
            }
            guard Set(command.enabledProviderIDs).count == command.enabledProviderIDs.count,
                  command.enabledProviderIDs.allSatisfy({ !$0.isEmpty })
            else { throw ModelBrokerError.invalidSettings("invalid enabled provider list for \(command.commandID)") }
            let eligible = Set(runtimeCommand.ladder(offline: false).map(\.providerClass))
            let selected = [command.mainProviderClass].compactMap { $0 } + command.fallbackProviderClasses
            guard selected.allSatisfy(eligible.contains), Set(selected).count == selected.count else {
                throw ModelBrokerError.invalidSettings("selection escapes the declared ladder for \(command.commandID)")
            }
            for providerClass in selected {
                guard let route = runtimeCommand.ladder(offline: false).first(where: { $0.providerClass == providerClass }) else {
                    throw ModelBrokerError.invalidSettings("selection escapes the declared ladder for \(command.commandID)")
                }
                guard !route.requiresQualityEvidence || providers.contains(where: {
                    $0.descriptor.providerClass == providerClass
                        && $0.descriptor.qualityValidatedCommandIDs.contains(command.commandID)
                }) else {
                    throw ModelBrokerError.invalidSettings("\(providerClass.rawValue) lacks command quality evidence")
                }
            }
        }
    }

    /// Returns a new immutable broker; persistence belongs to the explicit
    /// settings owner operation in composition, never to broker construction.
    public func applySettings(_ candidate: ModelSettings) throws -> ModelBroker {
        try validateSettings(candidate)
        return ModelBroker(policy: policy, providers: providers, settings: candidate)
    }

    public func execute(
        _ request: ModelGenerationRequest,
        settings override: ModelSettings? = nil
    ) async throws -> ModelBrokerResult {
        guard let commandPolicy = policy.command(named: request.commandID) else {
            throw ModelBrokerError.missingPolicy(commandID: request.commandID)
        }
        let settings = override ?? self.settings
        try validateSettings(settings)

        let commandSettings = settings.settings(for: request.commandID)
        let effectiveOffline = request.offline || (commandSettings?.offlineDefault ?? false)
        let effectiveRequest = ModelGenerationRequest(
            runID: request.runID,
            commandID: request.commandID,
            prompt: request.prompt,
            offline: effectiveOffline,
            styleGuide: request.styleGuide,
            contextGuides: request.contextGuides,
            input: request.input,
            outputConstraint: request.outputConstraint
        )
        let enabled = Set(commandSettings?.enabledProviderIDs ?? [])
        let routes = try effectiveRoutes(for: commandPolicy, offline: effectiveRequest.offline, settings: settings)
        var attempts: [ModelAttemptRecord] = []
        var sawProviderFailure = false

        for route in routes {
            if Task.isCancelled {
                throw ModelBrokerError.cancelled(record(for: effectiveRequest, settings: settings, attempts: attempts))
            }
            let matches = providers.filter { provider in
                provider.descriptor.providerClass == route.providerClass
                    && (enabled.isEmpty || enabled.contains(provider.descriptor.providerID))
            }
            guard !matches.isEmpty else {
                attempts.append(.init(
                    providerID: "unconfigured:\(route.providerClass.rawValue)",
                    providerClass: route.providerClass,
                    outcome: .unavailable,
                    detail: "no configured provider"
                ))
                continue
            }

            for provider in matches {
                let descriptor = provider.descriptor
                if effectiveRequest.offline && descriptor.isRemote {
                    attempts.append(.init(
                        providerID: descriptor.providerID,
                        providerClass: descriptor.providerClass,
                        outcome: .unavailable,
                        detail: "offline excludes remote providers"
                    ))
                    continue
                }
                if !descriptor.isAvailable {
                    attempts.append(.init(
                        providerID: descriptor.providerID,
                        providerClass: descriptor.providerClass,
                        outcome: .unavailable,
                        detail: "provider unavailable"
                    ))
                    continue
                }
                if route.requiresQualityEvidence && !descriptor.qualityValidatedCommandIDs.contains(request.commandID) {
                    attempts.append(.init(
                        providerID: descriptor.providerID,
                        providerClass: descriptor.providerClass,
                        outcome: .unavailable,
                        detail: "command quality evidence unavailable"
                    ))
                    continue
                }

                let started = Date()
                do {
                    let response = try await provider.generate(effectiveRequest)
                    try Task.checkCancellation()
                    guard Self.valid(response.text, for: effectiveRequest.outputConstraint) else {
                        sawProviderFailure = true
                        attempts.append(attempt(for: descriptor, outcome: .failed, started: started, detail: "invalid response shape"))
                        continue
                    }
                    attempts.append(attempt(for: descriptor, outcome: .succeeded, started: started, usage: response.usage))
                    return ModelBrokerResult(
                        response: response,
                        record: record(for: effectiveRequest, settings: settings, attempts: attempts)
                    )
                } catch is CancellationError {
                    attempts.append(attempt(for: descriptor, outcome: .cancelled, started: started, detail: "cancelled"))
                    throw ModelBrokerError.cancelled(record(for: effectiveRequest, settings: settings, attempts: attempts))
                } catch {
                    sawProviderFailure = true
                    attempts.append(attempt(for: descriptor, outcome: .failed, started: started, detail: "provider request failed"))
                }
            }
        }

        let executionRecord = record(for: effectiveRequest, settings: settings, attempts: attempts)
        throw sawProviderFailure ? ModelBrokerError.failed(executionRecord) : ModelBrokerError.unavailable(executionRecord)
    }

    private func effectiveRoutes(
        for command: ModelCommandRuntimePolicy,
        offline: Bool,
        settings: ModelSettings
    ) throws -> [ModelProviderRoute] {
        if offline { return command.ladder(offline: true) }
        guard let selection = settings.settings(for: command.commandID),
              selection.mainProviderClass != nil || !selection.fallbackProviderClasses.isEmpty
        else { return command.ladder(offline: false) }
        let baseline = command.ladder(offline: false)
        let classes = [selection.mainProviderClass].compactMap { $0 } + selection.fallbackProviderClasses
        let reordered = classes + baseline.map(\.providerClass).filter { !classes.contains($0) }
        return reordered.compactMap { selected in baseline.first { $0.providerClass == selected } }
    }

    private func record(
        for request: ModelGenerationRequest,
        settings: ModelSettings,
        attempts: [ModelAttemptRecord]
    ) -> ModelExecutionRecord {
        ModelExecutionRecord(
            runtimePolicyVersion: policy.version,
            commandID: request.commandID,
            runID: request.runID,
            offline: request.offline,
            styleGuide: request.styleGuide,
            contextGuides: request.contextGuides,
            settingsConfigurationID: settings.configurationID,
            settingsConfigurationVersion: settings.configurationVersion,
            attempts: attempts
        )
    }

    private func attempt(
        for descriptor: ModelProviderDescriptor,
        outcome: ModelAttemptOutcome,
        started: Date,
        usage: ModelUsage? = nil,
        detail: String? = nil
    ) -> ModelAttemptRecord {
        ModelAttemptRecord(
            providerID: descriptor.providerID,
            providerClass: descriptor.providerClass,
            outcome: outcome,
            latencyMilliseconds: max(0, Int(Date().timeIntervalSince(started) * 1_000)),
            usage: usage,
            detail: detail
        )
    }

    private static func valid(_ text: String, for constraint: ModelOutputConstraint) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              constraint.maximumCharacters > 0,
              text.count <= constraint.maximumCharacters
        else { return false }
        switch constraint.shape {
        case .plainText: return true
        case .numberedTranslations:
            let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
            guard (1...4).contains(lines.count) else { return false }
            return lines.enumerated().allSatisfy { index, line in
                line.hasPrefix("\(index + 1). ") && line.dropFirst(3).contains(where: { !$0.isWhitespace })
            }
        case .jsonObject:
            guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
                  value is [String: Any]
            else { return false }
            return true
        case .urlSlug:
            guard let slug = URLSlug.normalize(text) else { return false }
            return URLSlug.isValid(slug)
        case .stancePositions:
            return StanceResult.parse(text) != nil
        case .findQuery:
            return FindQueryReply.parse(text) != nil
        }
    }
}

extension ModelBroker: ModelGenerating {
    public func execute(_ request: ModelGenerationRequest) async throws -> ModelBrokerResult {
        try await execute(request, settings: nil)
    }

    public func cancellationRecord(for request: ModelGenerationRequest) async -> ModelExecutionRecord {
        let commandSettings = settings.settings(for: request.commandID)
        let offline = request.offline || (commandSettings?.offlineDefault ?? false)
        return ModelExecutionRecord(
            runtimePolicyVersion: policy.version,
            commandID: request.commandID,
            runID: request.runID,
            offline: offline,
            styleGuide: request.styleGuide,
            contextGuides: request.contextGuides,
            settingsConfigurationID: settings.configurationID,
            settingsConfigurationVersion: settings.configurationVersion,
            attempts: []
        )
    }
}

/// Long-lived development composition can retain this actor while the explicit
/// settings surface validates and applies a new immutable broker. Existing
/// requests keep their captured broker; later requests observe the new one.
public actor ModelBrokerSettingsStore: ModelGenerating {
    public nonisolated let policy: ModelRuntimePolicy
    private var broker: ModelBroker

    public init(broker: ModelBroker) {
        policy = broker.policy
        self.broker = broker
    }

    public func settingsSnapshot() -> ModelSettings { broker.settingsSnapshot() }
    public func validateSettings(_ candidate: ModelSettings) throws { try broker.validateSettings(candidate) }
    public func applySettings(_ candidate: ModelSettings) throws { broker = try broker.applySettings(candidate) }
    public func execute(_ request: ModelGenerationRequest) async throws -> ModelBrokerResult { try await broker.execute(request) }
    public func cancellationRecord(for request: ModelGenerationRequest) async -> ModelExecutionRecord {
        await broker.cancellationRecord(for: request)
    }
}

/// The proposal service gets only a bounded prompt and returns opaque JSON.
/// The proposal subsystem owns schema parsing, authority validation, and plan
/// construction; this type deliberately exposes neither tools nor execution.
public struct ConstrainedProposalInference: Sendable {
    private let broker: any ModelGenerating

    public init(broker: any ModelGenerating) {
        self.broker = broker
    }

    public func proposeRawJSON(runID: String, prompt: String, offline: Bool, dispatch: ModelDispatchContext? = nil) async throws -> ModelBrokerResult {
        try await broker.execute(ModelGenerationRequest(
            runID: runID,
            commandID: "tier2.proposal",
            prompt: prompt,
            offline: offline,
            outputConstraint: .init(shape: .jsonObject, maximumCharacters: 12_000),
            dispatch: dispatch
        ))
    }
}
