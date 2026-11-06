import Foundation
import OmniCore

// MARK: - Bounds

/// Configurable implementation defaults. A request-count limit is a local
/// attempt bound, not a token or spend guarantee.
public struct ProviderRuntimeBounds: Sendable, Equatable {
    public var maximumAttemptsPerGeneration: Int
    public var httpAttemptTimeout: Duration
    public var cliAttemptTimeout: Duration
    public var maximumConcurrentHTTPAttemptsPerConnection: Int
    public var maximumConcurrentCLIAttemptsPerConnection: Int
    public var sessionReservationWait: Duration
    public var maximumTransientRetryAfter: Duration
    public var maximumResponseBytes: Int

    public init(
        maximumAttemptsPerGeneration: Int = 3,
        httpAttemptTimeout: Duration = .seconds(90),
        cliAttemptTimeout: Duration = .seconds(180),
        maximumConcurrentHTTPAttemptsPerConnection: Int = 4,
        maximumConcurrentCLIAttemptsPerConnection: Int = 1,
        sessionReservationWait: Duration = .seconds(45),
        maximumTransientRetryAfter: Duration = .seconds(6),
        maximumResponseBytes: Int = 1_000_000
    ) {
        self.maximumAttemptsPerGeneration = maximumAttemptsPerGeneration
        self.httpAttemptTimeout = httpAttemptTimeout
        self.cliAttemptTimeout = cliAttemptTimeout
        self.maximumConcurrentHTTPAttemptsPerConnection = maximumConcurrentHTTPAttemptsPerConnection
        self.maximumConcurrentCLIAttemptsPerConnection = maximumConcurrentCLIAttemptsPerConnection
        self.sessionReservationWait = sessionReservationWait
        self.maximumTransientRetryAfter = maximumTransientRetryAfter
        self.maximumResponseBytes = maximumResponseBytes
    }

    func timeout(for driverID: ModelDriverID) -> Duration {
        switch driverID {
        case .codexAppServer, .claudePrint: cliAttemptTimeout
        default: httpAttemptTimeout
        }
    }

    func concurrency(for driverID: ModelDriverID) -> Int {
        switch driverID {
        case .codexAppServer, .claudePrint: maximumConcurrentCLIAttemptsPerConnection
        default: maximumConcurrentHTTPAttemptsPerConnection
        }
    }
}

// MARK: - Inspectable resolution

public struct ModelRouteCandidate: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case eligible
        case excluded(ModelFailureKind, detail: String)
    }

    public let profileID: String
    public let profileRevision: Int
    public let connectionID: String
    public let driverID: ModelDriverID
    public let authRoute: ModelAuthRoute
    public let displayName: String
    public let modelSelector: String
    public let verdict: Verdict
    public let qualificationEvidence: String?

    public init(profileID: String, profileRevision: Int, connectionID: String, driverID: ModelDriverID, authRoute: ModelAuthRoute, displayName: String, modelSelector: String, verdict: Verdict, qualificationEvidence: String? = nil) {
        self.profileID = profileID
        self.profileRevision = profileRevision
        self.connectionID = connectionID
        self.driverID = driverID
        self.authRoute = authRoute
        self.displayName = displayName
        self.modelSelector = modelSelector
        self.verdict = verdict
        self.qualificationEvidence = qualificationEvidence
    }

    public var isEligible: Bool { verdict == .eligible }

    /// A presentation-safe cause. Driver details and saved identifiers stay in
    /// receipts, where they can be inspected without leaking into the pad.
    public var unavailabilityReason: String? {
        guard case .excluded(let kind, let detail) = verdict else { return nil }
        if connectionID.isEmpty { return "Selected model: unavailable" }
        return "\(ModelHumanFailure.providerName(displayName: displayName, driverID: driverID)): \(ModelHumanFailure.reason(kind: kind, driverID: driverID, detail: detail))"
    }
}

/// Keeps backend identifiers and diagnostic text out of user-facing failures.
public enum ModelHumanFailure {
    public static func providerName(displayName: String, driverID: ModelDriverID) -> String {
        switch driverID {
        case .codexAppServer: return "ChatGPT"
        case .claudePrint: return "Claude"
        case .cerebrasHTTP: return "Cerebras"
        case .openRouterHTTP: return "OpenRouter"
        case .openAIHTTP: return "OpenAI API"
        case .anthropicHTTP: return "Anthropic API"
        case .ollamaHTTP: return "Local"
        }
    }

    public static func reason(kind: ModelFailureKind, driverID: ModelDriverID, detail: String? = nil) -> String {
        switch kind {
        case .disabled: return "connection is off"
        case .unconfigured:
            return detail?.contains("not registered") == true ? "no driver is available" : "model connection is unavailable"
        case .needsConfiguration:
            if driverID == .ollamaHTTP && detail == "service not running" { return "service is not running" }
            if driverID == .ollamaHTTP && detail == "service error" { return "service returned an error" }
            if driverID == .ollamaHTTP && detail == "model list unavailable" { return "model list could not be checked" }
            if detail == "CLI not found" {
                return driverID == .codexAppServer ? "Codex CLI not found" : "Claude CLI not found"
            }
            if detail == "credential missing" { return "credential is missing" }
            return "connection needs setup"
        case .needsLogin: return "not logged in"
        case .authRequired:
            return (driverID == .codexAppServer || driverID == .claudePrint) ? "not logged in" : "credential is missing"
        case .authMismatch: return "logged in with the wrong account"
        case .rateLimited: return "temporarily rate limited"
        case .quotaExhausted: return "usage limit reached"
        case .timeout: return "request timed out"
        case .cancelled: return "request was cancelled"
        case .unsupportedCapability: return "cannot provide this command's required output"
        case .ineligibleCommand: return "not available for this command"
        case .unqualified: return "not qualified for automatic routing"
        case .contextOrOutputLimit: return "output limit reached"
        case .invalidResponse: return "returned an invalid response"
        case .modelMismatch: return driverID == .ollamaHTTP ? "model is not installed" : "returned a different model"
        case .isolationViolation: return "cannot run in the required safe environment"
        case .offlineExcludesRemote: return "unavailable while offline"
        case .requiresExplicitSelection: return "requires an explicit selection"
        case .apiRoutePermissionRequired: return "paid API route needs permission"
        case .attemptBudgetExhausted: return "attempt limit reached"
        case .concurrencyLimit: return "busy with another request"
        case .providerFailure: return "provider request failed"
        case .storageFailure: return "settings storage is unavailable"
        }
    }

    /// Only controlled probe classes cross into route state. A configured API
    /// probe checks its credential reference; a failed Local reachability probe
    /// has one known service-down cause. Raw driver details stay diagnostic.
    static func probeBlock(_ availability: ModelConnectionAvailability, driverID: ModelDriverID, detail: String?) -> (ModelFailureKind, String)? {
        switch availability {
        case .disabled: return (.disabled, "connection disabled")
        case .needsConfiguration:
            if driverID == .ollamaHTTP && detail == "local model service not running" {
                return (.needsConfiguration, "service not running")
            }
            if driverID == .ollamaHTTP && detail?.hasPrefix("local model service HTTP ") == true {
                return (.needsConfiguration, "service error")
            }
            if driverID == .ollamaHTTP && detail == "local model list unavailable" {
                return (.needsConfiguration, "model list unavailable")
            }
            if driverID == .ollamaHTTP && detail == "local model not installed" {
                return (.modelMismatch, "local model not installed")
            }
            if [.cerebrasHTTP, .openRouterHTTP, .openAIHTTP, .anthropicHTTP].contains(driverID) {
                return (.authRequired, "credential missing")
            }
            return (.needsConfiguration, "connection needs setup")
        case .needsLogin: return (.needsLogin, "not logged in")
        case .authMismatch: return (.authMismatch, "wrong account")
        case .quotaLimited: return (.quotaExhausted, "usage limit reached")
        case .unsupported: return (.isolationViolation, "required safe environment unavailable")
        case .unverified, .ready: return nil
        }
    }
}

/// The effective choice for one command, computable before submit without
/// invoking any model.
public struct ModelRouteResolution: Sendable, Equatable {
    public let commandID: String
    public let offline: Bool
    public let generationID: String
    public let selectionSource: ModelSelectionSource
    public let selectedProfileID: String?
    public let apiTransition: ModelAPITransitionPermission?
    public let candidates: [ModelRouteCandidate]
    public let migrationIssue: ModelSettingsMigrationIssue?

    public var dispatchable: [ModelRouteCandidate] { candidates.filter(\.isEligible) }
    public var effectiveProfileID: String? { dispatchable.first?.profileID }

    func replacing(candidates: [ModelRouteCandidate]) -> Self {
        Self(commandID: commandID, offline: offline, generationID: generationID,
             selectionSource: selectionSource, selectedProfileID: selectedProfileID,
             apiTransition: apiTransition, candidates: candidates, migrationIssue: migrationIssue)
    }
}

// MARK: - Session reservation

/// Reserves an attempt slot per connection before dispatch so retries and
/// fallbacks cannot evade concurrency bounds or leak active sessions.
public actor ProviderRuntimeSessionLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var active: [String: Int] = [:]
    private var waiters: [String: [Waiter]] = [:]

    public init() {}

    /// Returns `true` once a slot is held. A released slot is handed directly
    /// to the oldest waiter; the deadline or task cancellation resolves a
    /// parked waiter with `false` so no reservation can hang or leak.
    public func reserve(connectionID: String, limit: Int, deadline: ContinuousClock.Instant) async -> Bool {
        guard limit > 0 else { return false }
        if (active[connectionID] ?? 0) < limit {
            active[connectionID, default: 0] += 1
            return true
        }
        if Task.isCancelled || ContinuousClock().now >= deadline { return false }
        let id = UUID()
        let timeout = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            await self?.expire(connectionID: connectionID, id: id)
        }
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                waiters[connectionID, default: []].append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { [weak self] in await self?.expire(connectionID: connectionID, id: id) }
        }
        timeout.cancel()
        return granted
    }

    public func release(connectionID: String) {
        if var queue = waiters[connectionID], !queue.isEmpty {
            // Transfer the held slot without changing the active count.
            let next = queue.removeFirst()
            waiters[connectionID] = queue.isEmpty ? nil : queue
            next.continuation.resume(returning: true)
            return
        }
        let remaining = max(0, (active[connectionID] ?? 1) - 1)
        if remaining == 0 { active.removeValue(forKey: connectionID) } else { active[connectionID] = remaining }
    }

    public func activeCount(connectionID: String) -> Int { active[connectionID] ?? 0 }

    private func expire(connectionID: String, id: UUID) {
        guard var queue = waiters[connectionID], let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = queue.remove(at: index)
        waiters[connectionID] = queue.isEmpty ? nil : queue
        waiter.continuation.resume(returning: false)
    }
}

// MARK: - Broker

/// Deterministic policy 6.0.0 routing behind the existing `ModelGenerating`
/// boundary. It owns attempt selection and normalized outcomes, never prompt
/// semantics, tools or owner authority.
public struct ProviderRuntimeBroker: Sendable {
    public let registry: ModelProviderRegistry
    public let settings: ProviderRuntimeSettings
    public let bounds: ProviderRuntimeBounds
    public let limiter: ProviderRuntimeSessionLimiter
    private let now: @Sendable () -> Date

    public var policy: ModelProviderPolicy { registry.policy }

    public init(
        registry: ModelProviderRegistry,
        settings: ProviderRuntimeSettings? = nil,
        bounds: ProviderRuntimeBounds = .init(),
        limiter: ProviderRuntimeSessionLimiter = .init(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        let effective = settings ?? .freshDefaults()
        try registry.validate(effective)
        self.registry = registry
        self.settings = effective
        self.bounds = bounds
        self.limiter = limiter
        self.now = now
    }

    public func settingsSnapshot() -> ProviderRuntimeSettings { settings }

    public func validateSettings(_ candidate: ProviderRuntimeSettings) throws {
        do { try registry.validate(candidate) } catch let error as ModelProviderRegistryError {
            throw ModelBrokerError.invalidSettings(error.description)
        }
    }

    public func applySettings(_ candidate: ProviderRuntimeSettings) throws -> ProviderRuntimeBroker {
        try validateSettings(candidate)
        return try ProviderRuntimeBroker(registry: registry, settings: candidate, bounds: bounds, limiter: limiter, now: now)
    }

    // MARK: Resolution

    public func resolve(commandID: String, offline requestedOffline: Bool, dispatch: ModelDispatchContext?) throws -> ModelRouteResolution {
        guard let command = policy.command(named: commandID) else { throw ModelBrokerError.missingPolicy(commandID: commandID) }
        let commandSettings = settings.command(commandID)
        let offline = requestedOffline || (commandSettings?.offlineDefault ?? false)
        let generationID = dispatch?.generationID ?? UUID().uuidString.lowercased()
        let issue = settings.migrationIssue(for: commandID)

        let source: ModelSelectionSource
        let selectedProfileID: String?
        var apiTransition: ModelAPITransitionPermission?
        var orderedIDs: [String]
        if let selection = dispatch?.selection {
            source = .invocationOverride(generationID: generationID)
            let selectedID = ProviderRuntimeCatalog.canonicalProfileID(selection.profileID)
            selectedProfileID = selectedID
            orderedIDs = [selectedID]
            if selection.permitsAPIRoute,
               let profile = registry.baseProfile(selection.profileID),
               let connection = registry.baseConnection(profile.connectionID),
               connection.authRoute.isOptionalAPIAlternative {
                apiTransition = .init(connectionID: connection.id, scope: .invocation(generationID: generationID))
            }
        } else if let saved = commandSettings?.savedProfileID, issue == nil {
            source = .savedCommandOptIn(settingsRevision: settings.revision)
            let savedID = ProviderRuntimeCatalog.canonicalProfileID(saved)
            selectedProfileID = savedID
            orderedIDs = [savedID] + (commandSettings?.savedFallbackProfileIDs ?? []).map(ProviderRuntimeCatalog.canonicalProfileID)
            apiTransition = commandSettings?.savedAPITransition
        } else {
            source = .policyDefault
            selectedProfileID = nil
            orderedIDs = command.ladder(offline: offline)
        }
        if offline, case .invocationOverride = source {
            // An explicit selection does not lift the offline exclusion; the
            // candidate is evaluated and excluded honestly below.
        } else if offline, case .savedCommandOptIn = source {
            orderedIDs = orderedIDs + command.offlineProfileIDs.filter { !orderedIDs.contains($0) }
        }

        let applicableIssue: ModelSettingsMigrationIssue? = switch source {
        case .invocationOverride: nil // An explicit route supersedes an unresolved old choice.
        case .savedCommandOptIn, .policyDefault: issue
        }

        var candidates: [ModelRouteCandidate] = []
        for profileID in orderedIDs {
            candidates.append(evaluate(
                profileID: profileID,
                command: command,
                offline: offline,
                source: source,
                apiTransition: apiTransition,
                migrationIssue: applicableIssue
            ))
        }
        return ModelRouteResolution(
            commandID: commandID,
            offline: offline,
            generationID: generationID,
            selectionSource: source,
            selectedProfileID: selectedProfileID,
            apiTransition: apiTransition,
            candidates: candidates,
            migrationIssue: applicableIssue
        )
    }

    private func evaluate(
        profileID: String,
        command: ModelCommandPolicy,
        offline: Bool,
        source: ModelSelectionSource,
        apiTransition: ModelAPITransitionPermission?,
        migrationIssue: ModelSettingsMigrationIssue?
    ) -> ModelRouteCandidate {
        guard let profile = registry.effectiveProfile(profileID, settings: settings) else {
            return placeholder(profileID: profileID, verdict: .excluded(.unconfigured, detail: "unknown model profile"))
        }
        guard let connection = registry.effectiveConnection(profile.connectionID, settings: settings) else {
            return placeholder(profileID: profileID, verdict: .excluded(.unconfigured, detail: "unknown connection \(profile.connectionID)"))
        }
        let evidence = registry.qualification(commandID: command.commandID, profile: profile, outputShape: command.outputShape)
        let saved = settings.command(command.commandID)
        let savedPrimary = saved?.savedProfileID
        let explicitSavedIDs = Set(
            ([savedPrimary].compactMap { $0 } + (saved?.savedFallbackProfileIDs ?? []))
                .map(ProviderRuntimeCatalog.canonicalProfileID)
        )
        let manualCandidate: Bool = switch source {
        case .invocationOverride: true
        case .savedCommandOptIn: explicitSavedIDs.contains(profile.id)
        case .policyDefault: false
        }
        func candidate(_ verdict: ModelRouteCandidate.Verdict) -> ModelRouteCandidate {
            ModelRouteCandidate(
                profileID: profile.id,
                profileRevision: profile.revision,
                connectionID: connection.id,
                driverID: connection.driverID,
                authRoute: connection.authRoute,
                displayName: profile.displayName,
                modelSelector: profile.modelSelector,
                verdict: verdict,
                qualificationEvidence: evidence?.evidenceReference
            )
        }
        if let migrationIssue {
            return candidate(.excluded(.needsConfiguration, detail: migrationIssue.reason))
        }
        if offline, connection.isRemote {
            return candidate(.excluded(.offlineExcludesRemote, detail: "offline excludes remote models, including CLI-accessed ones"))
        }
        guard connection.enabled else {
            return candidate(.excluded(.disabled, detail: "connection disabled"))
        }
        if connection.authRoute.isSubscription, case .policyDefault = source {
            return candidate(.excluded(.requiresExplicitSelection, detail: "subscription profiles need an explicit selection or saved opt-in"))
        }
        if connection.authRoute.isOptionalAPIAlternative {
            if case .policyDefault = source {
                return candidate(.excluded(.requiresExplicitSelection, detail: "API alternatives are never an automatic route"))
            }
            guard let apiTransition, apiTransition.connectionID == connection.id else {
                return candidate(.excluded(.apiRoutePermissionRequired, detail: "explicit API route permission required for \(connection.id)"))
            }
        }
        guard command.requiredCapabilities.isSubset(of: profile.capabilities) else {
            return candidate(.excluded(.unsupportedCapability, detail: "profile lacks \(command.requiredCapabilities.subtracting(profile.capabilities).map(\.rawValue).sorted().joined(separator: ","))"))
        }
        if profile.options.reasoning != nil, !profile.capabilities.contains(.reasoningLevel) {
            return candidate(.excluded(.unsupportedCapability, detail: "reasoning level is not supported by this profile"))
        }
        if profile.options.maximumOutputTokens != nil, !profile.capabilities.contains(.outputTokenLimit) {
            return candidate(.excluded(.unsupportedCapability, detail: "output token limit is not supported by this profile"))
        }
        if profile.options.temperature != nil, !profile.capabilities.contains(.temperature) {
            return candidate(.excluded(.unsupportedCapability, detail: "temperature is not supported by this profile"))
        }
        guard manualCandidate || profile.eligibleCommandIDs.contains(command.commandID) else {
            return candidate(.excluded(.ineligibleCommand, detail: "profile is not declared for \(command.commandID)"))
        }
        guard let driver = registry.driver(for: connection) else {
            return candidate(.excluded(.unconfigured, detail: "driver \(connection.driverID.rawValue) not registered"))
        }
        guard command.requiredCapabilities.isSubset(of: driver.capabilities) else {
            return candidate(.excluded(.unsupportedCapability, detail: "driver lacks required capability"))
        }
        if let issue = driver.configurationIssue(for: connection) {
            return candidate(.excluded(issue, detail: Self.configurationDetail(connection: connection, issue: issue)))
        }
        guard manualCandidate || evidence != nil else {
            return candidate(.excluded(.unqualified, detail: "no quality evidence for \(command.commandID) on \(profile.qualificationBinding)"))
        }
        return candidate(.eligible)
    }

    static func configurationDetail(connection: ModelConnectionProfile, issue: ModelFailureKind) -> String {
        guard issue == .needsConfiguration else { return "connection needs setup" }
        if let executable = connection.cliProfile?.executable {
            return CLIExecutableResolver.resolve(executable) == nil ? "CLI not found" : "CLI connection needs setup"
        }
        if connection.credentialReference == nil, connection.authRoute != .localService { return "credential missing" }
        return "connection needs setup"
    }

    private func placeholder(profileID: String, verdict: ModelRouteCandidate.Verdict) -> ModelRouteCandidate {
        ModelRouteCandidate(
            profileID: profileID,
            profileRevision: 0,
            connectionID: "",
            driverID: .cerebrasHTTP,
            authRoute: .localService,
            displayName: profileID,
            modelSelector: "",
            verdict: verdict
        )
    }

    // MARK: Execution

    public func execute(_ request: ModelGenerationRequest) async throws -> ModelBrokerResult {
        try await execute(request, resolution: nil)
    }

    /// One transient stream on an explicitly selected provider profile. No
    /// fallback runs after a partial answer is shown. The
    /// returned record is in memory for parity with completed generations;
    /// this method has no run-store handle and never persists it.
    func stream(
        _ request: ModelGenerationRequest,
        resolution: ModelRouteResolution,
        onText: @escaping @Sendable (String) async -> Void
    ) async throws -> ModelBrokerResult {
        guard let selection = request.dispatch?.selection,
              let command = policy.command(named: request.commandID),
              request.outputConstraint.shape == command.outputShape
        else { throw ModelBrokerError.invalidSettings("streaming requires an explicit profile and the command output shape") }
        let effectiveRequest = request.with(
            offline: resolution.offline,
            dispatch: .some(ModelDispatchContext(generationID: resolution.generationID, selection: request.dispatch?.selection))
        )
        let route = ModelRouteReceipt(
            policyVersion: policy.version,
            settingsRevision: settings.revision,
            generationID: resolution.generationID,
            selectionSource: resolution.selectionSource,
            selectedProfileID: resolution.selectedProfileID,
            apiTransition: resolution.apiTransition,
            candidateProfileIDs: resolution.candidates.map(\.profileID)
        )
        guard resolution.candidates.count == 1, let candidate = resolution.candidates.first,
              candidate.profileID == ProviderRuntimeCatalog.canonicalProfileID(selection.profileID)
        else {
            throw ModelBrokerError.unavailable(record(for: effectiveRequest, attempts: [], route: route))
        }
        guard case .eligible = candidate.verdict else {
            let failure: ModelAttemptRecord
            if case .excluded(let kind, let detail) = candidate.verdict {
                failure = exclusionAttempt(candidate, kind: kind, detail: detail, generationID: resolution.generationID, index: 1)
            } else { throw ModelBrokerError.unavailable(record(for: effectiveRequest, attempts: [], route: route)) }
            throw ModelBrokerError.unavailable(record(for: effectiveRequest, attempts: [failure], route: route))
        }
        guard let profile = registry.effectiveProfile(candidate.profileID, settings: settings),
              let connection = registry.effectiveConnection(candidate.connectionID, settings: settings),
              let driver = registry.driver(for: connection) as? any ModelStreamingProviderDriver
        else {
            let unavailable = exclusionAttempt(candidate, kind: .unsupportedCapability, detail: "streaming driver unavailable", generationID: resolution.generationID, index: 1)
            throw ModelBrokerError.unavailable(record(for: effectiveRequest, attempts: [unavailable], route: route))
        }
        let attemptID = "\(resolution.generationID)#1"
        let deadline = ContinuousClock().now.advanced(by: bounds.timeout(for: connection.driverID))
        let reserved = await limiter.reserve(
            connectionID: connection.id,
            limit: bounds.concurrency(for: connection.driverID),
            deadline: ContinuousClock().now.advanced(by: bounds.sessionReservationWait)
        )
        guard reserved else {
            let kind: ModelFailureKind = Task.isCancelled ? .cancelled : .concurrencyLimit
            let unavailable = exclusionAttempt(candidate, kind: kind, detail: "connection slot unavailable", generationID: resolution.generationID, index: 1)
            let receipt = record(for: effectiveRequest, attempts: [unavailable], route: route)
            throw Task.isCancelled ? ModelBrokerError.cancelled(receipt) : ModelBrokerError.unavailable(receipt)
        }
        let started = Date()
        let driverRequest = ModelDriverRequest(
            generation: effectiveRequest,
            profile: profile,
            connection: connection,
            generationID: resolution.generationID,
            attemptID: attemptID,
            deadline: deadline,
            maximumResponseBytes: bounds.maximumResponseBytes
        )
        let outcome: Result<ModelDriverResponse, any Error>
        do {
            outcome = .success(try await withDeadline(deadline) { try await driver.stream(driverRequest, onText: onText) })
        } catch {
            outcome = .failure(error)
        }
        await limiter.release(connectionID: connection.id)
        let latency = max(0, Int(Date().timeIntervalSince(started) * 1_000))
        switch outcome {
        case .success(let response):
            if Task.isCancelled {
                let cancelled = attempt(candidate, profile: profile, connection: connection, attemptID: attemptID, outcome: .cancelled, latency: latency, response: nil, failure: .init(.cancelled))
                throw ModelBrokerError.cancelled(record(for: effectiveRequest, attempts: [cancelled], route: route))
            }
            guard response.observedAuthRoute == connection.authRoute else {
                let mismatch = attempt(candidate, profile: profile, connection: connection, attemptID: attemptID, outcome: .failed, latency: latency, response: nil, failure: .init(.authMismatch))
                throw ModelBrokerError.failed(record(for: effectiveRequest, attempts: [mismatch], route: route))
            }
            guard Self.valid(response.text, for: effectiveRequest.outputConstraint) else {
                let invalid = attempt(candidate, profile: profile, connection: connection, attemptID: attemptID, outcome: .failed, latency: latency, response: nil, failure: .init(.invalidResponse, detail: "invalid translation output shape"))
                throw ModelBrokerError.failed(record(for: effectiveRequest, attempts: [invalid], route: route))
            }
            let success = attempt(candidate, profile: profile, connection: connection, attemptID: attemptID, outcome: .succeeded, latency: latency, response: response, failure: nil)
            return ModelBrokerResult(response: ModelProviderResponse(text: response.text, usage: response.usage), record: record(for: effectiveRequest, attempts: [success], route: route))
        case .failure(let error):
            let failure = (error as? ModelDriverFailure) ?? (error is CancellationError ? ModelDriverFailure(.cancelled) : ModelDriverFailure(.providerFailure, detail: String(describing: type(of: error))))
            let cancelled = Task.isCancelled || failure.kind == .cancelled
            let failed = attempt(candidate, profile: profile, connection: connection, attemptID: attemptID, outcome: cancelled ? .cancelled : .failed, latency: latency, response: nil, failure: failure)
            let receipt = record(for: effectiveRequest, attempts: [failed], route: route)
            throw cancelled ? ModelBrokerError.cancelled(receipt) : ModelBrokerError.failed(receipt)
        }
    }

    func execute(_ request: ModelGenerationRequest, resolution checkedResolution: ModelRouteResolution?, maximumAttempts: Int? = nil) async throws -> ModelBrokerResult {
        let resolution: ModelRouteResolution
        if let checkedResolution {
            resolution = checkedResolution
        } else {
            resolution = try resolve(commandID: request.commandID, offline: request.offline, dispatch: request.dispatch)
        }
        let effectiveRequest = request.with(
            offline: resolution.offline,
            dispatch: .some(ModelDispatchContext(generationID: resolution.generationID, selection: request.dispatch?.selection))
        )
        let route = ModelRouteReceipt(
            policyVersion: policy.version,
            settingsRevision: settings.revision,
            generationID: resolution.generationID,
            selectionSource: resolution.selectionSource,
            selectedProfileID: resolution.selectedProfileID,
            apiTransition: resolution.apiTransition,
            candidateProfileIDs: resolution.candidates.map(\.profileID)
        )
        var attempts: [ModelAttemptRecord] = []
        var attemptIndex = 0
        let attemptLimit = min(bounds.maximumAttemptsPerGeneration, maximumAttempts ?? bounds.maximumAttemptsPerGeneration)

        if let issue = resolution.migrationIssue {
            attempts.append(.init(
                providerID: "needs-configuration:\(request.commandID)",
                providerClass: .fastHosted,
                outcome: .unavailable,
                detail: "settings migration requires an explicit route: \(issue.reason)"
            ))
        }
        for candidate in resolution.candidates {
            guard case .excluded(let kind, let detail) = candidate.verdict else { continue }
            attemptIndex += 1
            attempts.append(exclusionAttempt(candidate, kind: kind, detail: detail, generationID: resolution.generationID, index: attemptIndex))
        }

        var sawProviderFailure = false
        var dispatched = 0
        var stop = false
        for candidate in resolution.dispatchable where !stop {
            guard dispatched < attemptLimit else {
                attemptIndex += 1
                attempts.append(exclusionAttempt(candidate, kind: .attemptBudgetExhausted, detail: "attempt budget \(attemptLimit) reached", generationID: resolution.generationID, index: attemptIndex))
                break
            }
            if Task.isCancelled {
                throw ModelBrokerError.cancelled(record(for: effectiveRequest, attempts: attempts, route: route))
            }
            guard let profile = registry.effectiveProfile(candidate.profileID, settings: settings),
                  let connection = registry.effectiveConnection(candidate.connectionID, settings: settings),
                  let driver = registry.driver(for: connection)
            else { continue }

            var retriedTransient = false
            repeat {
                attemptIndex += 1
                dispatched += 1
                let attemptID = "\(resolution.generationID)#\(attemptIndex)"
                let timeout = bounds.timeout(for: connection.driverID)
                let deadline = ContinuousClock().now.advanced(by: timeout)
                let reserved = await limiter.reserve(
                    connectionID: connection.id,
                    limit: bounds.concurrency(for: connection.driverID),
                    deadline: ContinuousClock().now.advanced(by: bounds.sessionReservationWait)
                )
                guard reserved else {
                    if Task.isCancelled {
                        attempts.append(exclusionAttempt(candidate, kind: .cancelled, detail: "cancelled while waiting for a connection slot", generationID: resolution.generationID, index: attemptIndex))
                        throw ModelBrokerError.cancelled(record(for: effectiveRequest, attempts: attempts, route: route))
                    }
                    attempts.append(exclusionAttempt(candidate, kind: .concurrencyLimit, detail: "connection \(connection.id) is busy", generationID: resolution.generationID, index: attemptIndex))
                    sawProviderFailure = true
                    break
                }
                let started = Date()
                let driverRequest = ModelDriverRequest(
                    generation: effectiveRequest,
                    profile: profile,
                    connection: connection,
                    generationID: resolution.generationID,
                    attemptID: attemptID,
                    deadline: deadline,
                    maximumResponseBytes: bounds.maximumResponseBytes
                )
                let outcome: Result<ModelDriverResponse, any Error>
                do {
                    outcome = .success(try await withDeadline(deadline) { try await driver.generate(driverRequest) })
                } catch {
                    outcome = .failure(error)
                }
                await limiter.release(connectionID: connection.id)
                let latency = max(0, Int(Date().timeIntervalSince(started) * 1_000))

                switch outcome {
                case .success(let response):
                    if Task.isCancelled {
                        attempts.append(attempt(candidate, profile: profile, connection: connection, attemptID: attemptID, outcome: .cancelled, latency: latency, response: response, failure: .init(.cancelled, detail: "cancelled after completion; late result discarded")))
                        throw ModelBrokerError.cancelled(record(for: effectiveRequest, attempts: attempts, route: route))
                    }
                    if let isolation = response.isolation, !isolation.isFullyIsolated {
                        attempts.append(attempt(candidate, profile: profile, connection: connection, attemptID: attemptID, outcome: .failed, latency: latency, response: response, failure: .init(.isolationViolation, detail: "effective isolation not verified", isolation: isolation)))
                        stop = true
                        sawProviderFailure = true
                        break
                    }
                    if connection.authRoute != .localService, let observed = response.observedAuthRoute, observed != connection.authRoute {
                        attempts.append(attempt(candidate, profile: profile, connection: connection, attemptID: attemptID, outcome: .failed, latency: latency, response: response, failure: .init(.authMismatch, detail: "observed \(observed.rawValue) differs from expected \(connection.authRoute.rawValue); result discarded")))
                        stop = true
                        sawProviderFailure = true
                        break
                    }
                    guard Self.valid(response.text, for: effectiveRequest.outputConstraint) else {
                        attempts.append(attempt(candidate, profile: profile, connection: connection, attemptID: attemptID, outcome: .failed, latency: latency, response: response, failure: .init(.invalidResponse, detail: "invalid response shape")))
                        sawProviderFailure = true
                        break
                    }
                    attempts.append(attempt(candidate, profile: profile, connection: connection, attemptID: attemptID, outcome: .succeeded, latency: latency, response: response, failure: nil))
                    return ModelBrokerResult(
                        response: ModelProviderResponse(text: response.text, usage: response.usage),
                        record: record(for: effectiveRequest, attempts: attempts, route: route)
                    )
                case .failure(let error):
                    if error is CancellationError {
                        attempts.append(attempt(candidate, profile: profile, connection: connection, attemptID: attemptID, outcome: .cancelled, latency: latency, response: nil, failure: .init(.cancelled, detail: "cancelled")))
                        throw ModelBrokerError.cancelled(record(for: effectiveRequest, attempts: attempts, route: route))
                    }
                    let failure = (error as? ModelDriverFailure) ?? ModelDriverFailure(.providerFailure, detail: String(describing: type(of: error)))
                    if failure.kind == .cancelled {
                        attempts.append(attempt(candidate, profile: profile, connection: connection, attemptID: attemptID, outcome: .cancelled, latency: latency, response: nil, failure: failure))
                        throw ModelBrokerError.cancelled(record(for: effectiveRequest, attempts: attempts, route: route))
                    }
                    let outcomeKind: ModelAttemptOutcome = switch failure.kind {
                    case .disabled, .unconfigured, .needsConfiguration, .needsLogin, .unqualified, .ineligibleCommand, .unsupportedCapability, .offlineExcludesRemote, .requiresExplicitSelection, .apiRoutePermissionRequired: .unavailable
                    default: .failed
                    }
                    attempts.append(attempt(candidate, profile: profile, connection: connection, attemptID: attemptID, outcome: outcomeKind, latency: latency, response: nil, failure: failure))
                    if outcomeKind == .failed { sawProviderFailure = true }
                    if failure.kind.stopsFallback { stop = true; break }
                    if failure.kind == .rateLimited, !retriedTransient, dispatched < attemptLimit,
                       let retryAfter = failure.retryAfterSeconds, retryAfter >= 0,
                       Duration.seconds(retryAfter) <= bounds.maximumTransientRetryAfter {
                        retriedTransient = true
                        do { try await Task.sleep(for: .seconds(retryAfter)) } catch {
                            attempts.append(exclusionAttempt(candidate, kind: .cancelled, detail: "cancelled while waiting to retry", generationID: resolution.generationID, index: attemptIndex + 1))
                            throw ModelBrokerError.cancelled(record(for: effectiveRequest, attempts: attempts, route: route))
                        }
                        continue
                    }
                }
                break
            } while true
        }

        let executionRecord = record(for: effectiveRequest, attempts: attempts, route: route)
        throw sawProviderFailure ? ModelBrokerError.failed(executionRecord) : ModelBrokerError.unavailable(executionRecord)
    }

    public func cancellationRecord(for request: ModelGenerationRequest) -> ModelExecutionRecord {
        let offline = request.offline || (settings.command(request.commandID)?.offlineDefault ?? false)
        let generationID = request.dispatch?.generationID ?? UUID().uuidString.lowercased()
        let resolution = try? resolve(commandID: request.commandID, offline: request.offline, dispatch: request.dispatch)
        return ModelExecutionRecord(
            runtimePolicyVersion: policy.version,
            commandID: request.commandID,
            runID: request.runID,
            offline: offline,
            styleGuide: request.styleGuide,
            contextGuides: request.contextGuides,
            settingsConfigurationID: settings.configurationID,
            settingsConfigurationVersion: settings.revision,
            attempts: [],
            route: .init(
                policyVersion: policy.version,
                settingsRevision: settings.revision,
                generationID: generationID,
                selectionSource: resolution?.selectionSource ?? (request.dispatch?.selection == nil ? .policyDefault : .invocationOverride(generationID: generationID)),
                selectedProfileID: resolution?.selectedProfileID ?? request.dispatch?.selection?.profileID,
                apiTransition: resolution?.apiTransition
            )
        )
    }

    // MARK: Helpers

    private func withDeadline<T: Sendable>(_ deadline: ContinuousClock.Instant, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(until: deadline, clock: .continuous)
                throw ModelDriverFailure(.timeout, detail: "attempt deadline exceeded")
            }
            guard let first = try await group.next() else { throw ModelDriverFailure(.timeout) }
            group.cancelAll()
            return first
        }
    }

    private func exclusionAttempt(_ candidate: ModelRouteCandidate, kind: ModelFailureKind, detail: String, generationID: String, index: Int) -> ModelAttemptRecord {
        ModelAttemptRecord(
            providerID: candidate.connectionID.isEmpty ? "unconfigured:\(candidate.profileID)" : "\(candidate.connectionID)/\(candidate.profileID)",
            providerClass: Self.legacyClass(for: candidate.authRoute),
            outcome: .unavailable,
            detail: detail,
            identity: candidate.connectionID.isEmpty ? nil : ModelAttemptIdentity(
                attemptID: "\(generationID)#\(index)",
                profileID: candidate.profileID,
                profileRevision: candidate.profileRevision,
                connectionID: candidate.connectionID,
                driverID: candidate.driverID,
                expectedAuthRoute: candidate.authRoute,
                requestedModel: candidate.modelSelector,
                failure: kind,
                fixture: registry.isFixture
            )
        )
    }

    private func attempt(
        _ candidate: ModelRouteCandidate,
        profile: ModelProfile,
        connection: ModelConnectionProfile,
        attemptID: String,
        outcome: ModelAttemptOutcome,
        latency: Int,
        response: ModelDriverResponse?,
        failure: ModelDriverFailure?
    ) -> ModelAttemptRecord {
        ModelAttemptRecord(
            providerID: "\(connection.id)/\(profile.id)",
            providerClass: Self.legacyClass(for: connection.authRoute),
            outcome: outcome,
            latencyMilliseconds: latency,
            usage: response?.usage ?? failure?.usage,
            detail: failure?.description,
            identity: ModelAttemptIdentity(
                attemptID: attemptID,
                profileID: profile.id,
                profileRevision: profile.revision,
                connectionID: connection.id,
                driverID: connection.driverID,
                expectedAuthRoute: connection.authRoute,
                observedAuthRoute: response?.observedAuthRoute ?? failure?.observedAuthRoute,
                requestedModel: profile.modelSelector,
                resolvedModel: response?.resolvedModel ?? failure?.resolvedModel,
                options: profile.options,
                failure: failure?.kind,
                retryAfterSeconds: failure?.retryAfterSeconds,
                nativeReference: response?.nativeReference ?? failure?.nativeReference,
                reportedPlan: response?.reportedPlan,
                servedBy: response?.servedBy,
                estimatedCostUSD: response?.estimatedCostUSD,
                isolation: response?.isolation ?? failure?.isolation,
                fixture: registry.isFixture,
                qualificationEvidence: candidate.qualificationEvidence
            )
        )
    }

    private func record(for request: ModelGenerationRequest, attempts: [ModelAttemptRecord], route: ModelRouteReceipt) -> ModelExecutionRecord {
        ModelExecutionRecord(
            runtimePolicyVersion: policy.version,
            commandID: request.commandID,
            runID: request.runID,
            offline: request.offline,
            styleGuide: request.styleGuide,
            contextGuides: request.contextGuides,
            settingsConfigurationID: settings.configurationID,
            settingsConfigurationVersion: settings.revision,
            attempts: attempts,
            route: route
        )
    }

    /// Historical receipts and views still read a provider class. The mapping
    /// is presentational only; policy 6.0.0 routes by profile ID.
    static func legacyClass(for route: ModelAuthRoute) -> ModelProviderClass {
        switch route {
        case .cerebrasAPIKey, .openRouterAPIKey: .fastHosted
        case .chatGPTSubscription, .claudeSubscription, .openAIAPIKey, .anthropicAPIKey: .capableRemote
        case .localService: .localCapable
        }
    }

    static func valid(_ text: String, for constraint: ModelOutputConstraint) -> Bool {
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
            guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)), value is [String: Any] else { return false }
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

// MARK: - Readiness

/// Per-connection state for settings and status surfaces. `implemented`
/// means a real driver is registered; `configured` means dispatch
/// prerequisites exist; `availability` is the last diagnostic probe;
/// `qualifiedCommandIDs` are bound to the effective profile material.
public struct ModelConnectionReadiness: Sendable, Equatable, Codable {
    public let connectionID: String
    public let displayName: String
    public let driverID: ModelDriverID
    public let authRoute: ModelAuthRoute
    public let enabled: Bool
    public let implemented: Bool
    public let configured: Bool
    public let configurationIssue: ModelFailureKind?
    public let availability: ModelConnectionAvailability
    public let availabilityDetail: String?
    public let observedAuthRoute: ModelAuthRoute?
    public let reportedPlan: String?
    public let profiles: [ModelProfileReadiness]
    public let fixture: Bool

    public var unavailabilityReason: String? {
        let provider = ModelHumanFailure.providerName(displayName: displayName, driverID: driverID)
        if !implemented { return "\(provider): no driver is available" }
        if !enabled { return "\(provider): connection is off" }
        if !configured {
            return "\(provider): \(ModelHumanFailure.reason(kind: configurationIssue ?? .needsConfiguration, driverID: driverID, detail: availabilityDetail))"
        }
        guard let (kind, detail) = ModelHumanFailure.probeBlock(availability, driverID: driverID, detail: availabilityDetail) else { return nil }
        return "\(provider): \(ModelHumanFailure.reason(kind: kind, driverID: driverID, detail: detail))"
    }

    public var summary: String {
        if fixture { return unavailabilityReason.map { "\($0) · test fixture" } ?? "Test fixture" }
        if let unavailabilityReason { return unavailabilityReason }
        switch availability {
        case .ready: return "Ready to run"
        case .unverified: return "Connection status not checked"
        default: return "Connection unavailable"
        }
    }
}

public struct ModelProfileReadiness: Sendable, Equatable, Codable {
    public let profileID: String
    public let displayName: String
    public let modelSelector: String
    public let options: ModelGenerationOptions
    public let revision: Int
    public let eligibleCommandIDs: [String]
    public let qualifiedCommandIDs: [String]
}

// MARK: - Settings store actor

/// Long-lived composition retains this actor while the explicit settings
/// surface validates and applies a new immutable broker. Existing requests
/// keep their captured broker; later requests observe the new one.
public actor ProviderRuntimeBrokerStore: ModelGenerating {
    private struct ProbeFlight {
        let id: UUID
        let task: Task<ModelConnectionProbe, Never>
    }
    public nonisolated let policy: ModelProviderPolicy
    /// The registry never changes across settings revisions.
    public nonisolated let registry: ModelProviderRegistry
    private var broker: ProviderRuntimeBroker
    private var probes: [String: ModelConnectionProbe] = [:]
    /// A verified dispatch isolation failure outranks a later auth-only probe.
    /// It is ephemeral and cleared when the saved connection settings change.
    private var isolationBlocks: [String: ModelConnectionProbe] = [:]
    private var inFlightProbes: [String: ProbeFlight] = [:]
    private var settingsEpoch = 0
    /// Every active generation owns a cancellable child task. Epoch checks
    /// remain necessary because a driver may ignore cancellation and reply.
    private var activeRequests: [UUID: Task<ModelBrokerResult, any Error>] = [:]
    private let probeTTL: TimeInterval
    private let isolationBlockTTL: TimeInterval
    /// When the migration write failed, generation depending on migrated
    /// settings must stay unavailable rather than dispatch against an
    /// unpersisted replacement.
    private var settingsBlock: String?

    public init(broker: ProviderRuntimeBroker, probeTTL: TimeInterval = 60, isolationBlockTTL: TimeInterval = 60) {
        policy = broker.policy
        registry = broker.registry
        self.broker = broker
        self.probeTTL = probeTTL
        self.isolationBlockTTL = max(0, isolationBlockTTL)
    }

    public func settingsSnapshot() -> ProviderRuntimeSettings { broker.settingsSnapshot() }
    public func validateSettings(_ candidate: ProviderRuntimeSettings) throws { try broker.validateSettings(candidate) }
    public func applySettings(_ candidate: ProviderRuntimeSettings) throws {
        let replacement = try broker.applySettings(candidate)
        invalidateActiveRequests()
        broker = replacement
        settingsBlock = nil
        probes.removeAll()
        isolationBlocks.removeAll()
    }

    /// Used by settings, AI pause, offline mode, and module disable. It stops
    /// transport tasks and invalidates even a late result from a noncooperative
    /// driver; no new provider or fallback is selected here.
    public func invalidateActiveRequests() {
        settingsEpoch &+= 1
        let tasks = Array(activeRequests.values)
        activeRequests.removeAll()
        tasks.forEach { $0.cancel() }
        inFlightProbes.values.forEach { $0.task.cancel() }
        inFlightProbes.removeAll()
    }

    public func markSettingsBlocked(_ detail: String) {
        invalidateActiveRequests()
        settingsBlock = detail
    }
    public func settingsBlockReason() -> String? { settingsBlock }

    private func activeIsolationBlock(for connectionID: String, now: Date = Date()) -> ModelConnectionProbe? {
        guard let block = isolationBlocks[connectionID] else { return nil }
        guard now.timeIntervalSince(block.checkedAt) < isolationBlockTTL else {
            isolationBlocks.removeValue(forKey: connectionID)
            probes.removeValue(forKey: connectionID) // Expiry requires a fresh auth-only check.
            inFlightProbes.removeValue(forKey: connectionID)
            return nil
        }
        return block
    }

    // MARK: Qualification evidence

    /// Durable evidence admitted at launch or recorded since; never trial entries.
    private var ledger: [ModelQualification]?
    private var trial: QualificationTrial?
    private var trialEntries: [ModelQualification] = []

    private func durableQualifications() -> [ModelQualification] { ledger ?? registry.qualifications }

    private func rebuildBroker() throws {
        broker = try ProviderRuntimeBroker(
            registry: registry.replacingQualifications(durableQualifications() + trialEntries),
            settings: broker.settings,
            bounds: broker.bounds,
            limiter: broker.limiter
        )
    }

    /// Evidence currently admitted by the broker (ledger plus any active trial).
    public func activeQualifications() -> [ModelQualification] { broker.registry.qualifications }
    public func durableQualificationEntries() -> [ModelQualification] { durableQualifications() }

    /// Records durable evidence for one command on the effective profile
    /// material and admits it immediately. The caller has inspected the
    /// command-specific output; this method never invokes a model.
    public func recordQualification(commandID: String, profileID: String, evidenceReference: String, now: Date = Date()) throws -> ModelQualification {
        guard let command = policy.command(named: commandID) else { throw ModelBrokerError.missingPolicy(commandID: commandID) }
        guard let profile = registry.effectiveProfile(profileID, settings: broker.settings) else {
            throw ModelBrokerError.invalidSettings("unknown profile \(profileID)")
        }
        guard profile.eligibleCommandIDs.contains(commandID) else {
            throw ModelBrokerError.invalidSettings("\(profileID) is not declared for \(commandID)")
        }
        guard !evidenceReference.hasPrefix("qualification-trial:") else {
            throw ModelBrokerError.invalidSettings("a trial reference is not durable evidence")
        }
        let qualification = ModelQualification(
            commandID: commandID,
            profileID: profileID,
            qualificationBinding: profile.qualificationBinding,
            outputShape: command.outputShape,
            evidenceReference: evidenceReference,
            recordedAt: now
        )
        var kept = durableQualifications().filter {
            !($0.commandID == commandID && $0.profileID == profileID && $0.qualificationBinding == profile.qualificationBinding)
        }
        kept.append(qualification)
        ledger = kept
        try rebuildBroker()
        return qualification
    }

    public struct QualificationTrial: Sendable, Equatable {
        public let trialID: String
        public let profileID: String
        public let commandIDs: [String]
        public let maximumAttempts: Int
        public var remainingAttempts: Int
        public var evidenceReference: String { "qualification-trial:\(trialID)" }
    }

    /// Admits one profile for the named commands for a bounded number of
    /// generations so command-specific output can be produced and inspected.
    /// Every other rule (enabled, permitted route, capability, eligibility,
    /// offline, auth verification) still applies. Attempts record the trial
    /// evidence reference; nothing durable is qualified until `recordQualification`.
    public func beginQualificationTrial(profileID: String, commandIDs: [String], maximumAttempts: Int, now: Date = Date()) throws -> QualificationTrial {
        guard trial == nil else { throw ModelBrokerError.invalidSettings("a qualification trial is already active") }
        guard settingsBlock == nil else { throw ModelBrokerError.invalidSettings("provider settings are blocked; save a valid document before a trial") }
        guard maximumAttempts > 0, maximumAttempts <= 12 else { throw ModelBrokerError.invalidSettings("trial attempts must be 1...12") }
        guard !registry.isFixture else { throw ModelBrokerError.invalidSettings("fixture registries do not run qualification trials") }
        guard !commandIDs.isEmpty else { throw ModelBrokerError.invalidSettings("a trial names at least one command") }
        guard let profile = registry.effectiveProfile(profileID, settings: broker.settings) else {
            throw ModelBrokerError.invalidSettings("unknown profile \(profileID)")
        }
        let trialID = UUID().uuidString.lowercased()
        let candidate = QualificationTrial(trialID: trialID, profileID: profileID, commandIDs: commandIDs.sorted(), maximumAttempts: maximumAttempts, remainingAttempts: maximumAttempts)
        var entries: [ModelQualification] = []
        for commandID in commandIDs {
            guard let command = policy.command(named: commandID) else { throw ModelBrokerError.missingPolicy(commandID: commandID) }
            guard profile.eligibleCommandIDs.contains(commandID) else { throw ModelBrokerError.invalidSettings("\(profileID) is not declared for \(commandID)") }
            entries.append(ModelQualification(commandID: commandID, profileID: profileID, qualificationBinding: profile.qualificationBinding, outputShape: command.outputShape, evidenceReference: candidate.evidenceReference, recordedAt: now))
        }
        trialEntries = entries
        trial = candidate
        try rebuildBroker()
        return candidate
    }

    public func activeQualificationTrial() -> QualificationTrial? { trial }

    public func endQualificationTrial() throws {
        guard trial != nil else { return }
        trial = nil
        trialEntries = []
        try rebuildBroker()
    }

    public func resolve(commandID: String, offline: Bool, dispatch: ModelDispatchContext?) throws -> ModelRouteResolution {
        try broker.resolve(commandID: commandID, offline: offline, dispatch: dispatch)
    }

    /// Pre-submit check for explicit picks. Saved fallback IDs are explicit;
    /// policy-added offline candidates remain automatic and are not probed.
    public func resolveReadiness(commandID: String, offline: Bool, dispatch: ModelDispatchContext?) async throws -> ModelRouteResolution {
        try await resolveReadiness(commandID: commandID, offline: offline, dispatch: dispatch,
                                   retryAfterSettingsChange: true)
    }

    private func resolveReadiness(commandID: String, offline: Bool, dispatch: ModelDispatchContext?,
                                  retryAfterSettingsChange: Bool) async throws -> ModelRouteResolution {
        let epoch = settingsEpoch
        let resolution = try broker.resolve(commandID: commandID, offline: offline, dispatch: dispatch)
        var candidates = resolution.candidates
        let explicitIDs: Set<String> = switch resolution.selectionSource {
        case .invocationOverride: Set([resolution.selectedProfileID].compactMap { $0 })
        case .savedCommandOptIn:
            Set(([resolution.selectedProfileID].compactMap { $0 }
                 + (broker.settings.command(commandID)?.savedFallbackProfileIDs ?? [])
                    .map(ProviderRuntimeCatalog.canonicalProfileID)))
        case .policyDefault: []
        }
        for index in candidates.indices where explicitIDs.contains(candidates[index].profileID) && candidates[index].isEligible {
            let candidate = candidates[index]
            let checkedProbe = await probe(connectionID: candidate.connectionID,
                                           retryAfterSettingsChange: retryAfterSettingsChange)
            if settingsEpoch != epoch {
                if retryAfterSettingsChange {
                    return try await resolveReadiness(commandID: commandID, offline: offline, dispatch: dispatch,
                                                      retryAfterSettingsChange: true)
                }
                return resolution // caller's captured-epoch guard returns cancellation
            }
            guard let probe = checkedProbe else { continue }
            let block = ModelHumanFailure.probeBlock(probe.availability, driverID: candidate.driverID, detail: probe.detail)
            let modelMissing = candidate.driverID == .ollamaHTTP
                && probe.availability == .ready
                && probe.availableModelSelectors.map { !$0.contains(candidate.modelSelector) } == true
            let failure: (ModelFailureKind, String)? = modelMissing
                ? (.modelMismatch, "local model not installed")
                : block
            guard let (kind, detail) = failure else { continue }
            candidates[index] = ModelRouteCandidate(
                profileID: candidate.profileID, profileRevision: candidate.profileRevision,
                connectionID: candidate.connectionID, driverID: candidate.driverID,
                authRoute: candidate.authRoute, displayName: candidate.displayName,
                modelSelector: candidate.modelSelector, verdict: .excluded(kind, detail: detail),
                qualificationEvidence: candidate.qualificationEvidence
            )
        }
        return resolution.replacing(candidates: candidates)
    }

    public func execute(_ request: ModelGenerationRequest) async throws -> ModelBrokerResult {
        let startEpoch = settingsEpoch
        let startBroker = broker
        if let settingsBlock {
            throw ModelBrokerError.unavailable(ModelExecutionRecord(
                runtimePolicyVersion: policy.version,
                commandID: request.commandID,
                runID: request.runID,
                offline: request.offline,
                styleGuide: request.styleGuide,
                contextGuides: request.contextGuides,
                settingsConfigurationID: broker.settings.configurationID,
                settingsConfigurationVersion: broker.settings.revision,
                attempts: [.init(providerID: "settings-storage", providerClass: .fastHosted, outcome: .unavailable, detail: "provider settings unavailable until an explicit save succeeds: \(settingsBlock)")]
            ))
        }
        let preflight = try await resolveReadiness(commandID: request.commandID, offline: request.offline,
                                                   dispatch: request.dispatch, retryAfterSettingsChange: false)
        guard settingsEpoch == startEpoch, !Task.isCancelled else {
            throw ModelBrokerError.cancelled(startBroker.cancellationRecord(for: request))
        }
        if var active = trial, active.commandIDs.contains(request.commandID) {
            // Each trial generation consumes one bounded attempt; the trial
            // ends itself when exhausted so no later request can ride on it.
            guard active.remainingAttempts > 0 else {
                try endQualificationTrial()
                return try await executeChecked(request, resolution: preflight, using: broker)
            }
            active.remainingAttempts -= 1
            trial = active
            let trialBroker = broker
            if active.remainingAttempts == 0 { try endQualificationTrial() }
            return try await executeChecked(request, resolution: preflight, using: trialBroker)
        }
        return try await executeChecked(request, resolution: preflight, using: broker)
    }

    /// Execute an explicitly selected ephemeral request with at most one
    /// provider dispatch. Concept Lens uses this to avoid a second model call,
    /// including after a malformed response or transient provider failure.
    public func executeOnce(_ request: ModelGenerationRequest) async throws -> ModelBrokerResult {
        let startEpoch = settingsEpoch
        let startBroker = broker
        guard request.dispatch?.selection != nil else {
            throw ModelBrokerError.invalidSettings("single-attempt execution requires an explicit profile")
        }
        guard settingsBlock == nil else { throw ModelBrokerError.invalidSettings("provider settings are unavailable") }
        let preflight = try await resolveReadiness(commandID: request.commandID, offline: request.offline,
                                                   dispatch: request.dispatch, retryAfterSettingsChange: false)
        guard settingsEpoch == startEpoch, !Task.isCancelled else {
            throw ModelBrokerError.cancelled(startBroker.cancellationRecord(for: request))
        }
        return try await executeChecked(request, resolution: preflight, using: broker, maximumAttempts: 1)
    }

    /// Transient text deltas for the live translation tool. The caller owns
    /// the displayed text and must cancel its task when that text is obsolete.
    /// A settings revision is captured per request, like `execute`.
    public func stream(
        _ request: ModelGenerationRequest,
        onText: @escaping @Sendable (String) async -> Void
    ) async throws -> ModelBrokerResult {
        let startEpoch = settingsEpoch
        let startBroker = broker
        guard settingsBlock == nil else { throw ModelBrokerError.invalidSettings("provider settings are unavailable") }
        let preflight = try await resolveReadiness(commandID: request.commandID, offline: request.offline,
                                                   dispatch: request.dispatch, retryAfterSettingsChange: false)
        guard settingsEpoch == startEpoch, !Task.isCancelled else {
            throw ModelBrokerError.cancelled(startBroker.cancellationRecord(for: request))
        }
        let activeBroker = broker
        return try await runActive(request, using: activeBroker) { id, epoch in
            try await activeBroker.stream(request, resolution: preflight) { delta in
                guard !Task.isCancelled, await self.isActive(id, epoch: epoch) else { return }
                await onText(delta)
            }
        }
    }

    /// One selected ephemeral provider, with live deltas when its driver
    /// supports them. A non-streaming driver returns one completed delta.
    /// Neither path changes the selected profile or starts a fallback.
    public func executeEphemeral(
        _ request: ModelGenerationRequest,
        onText: @escaping @Sendable (String) async -> Void
    ) async throws -> ModelBrokerResult {
        let epoch = settingsEpoch
        let originalBroker = broker
        guard let selection = request.dispatch?.selection,
              let profile = registry.effectiveProfile(selection.profileID, settings: broker.settings),
              let connection = registry.effectiveConnection(profile.connectionID, settings: broker.settings),
              let driver = registry.driver(for: connection) else {
            throw ModelBrokerError.invalidSettings("ephemeral execution needs a selected provider profile")
        }
        if driver is any ModelStreamingProviderDriver {
            return try await stream(request, onText: onText)
        }
        let result = try await executeOnce(request)
        guard settingsEpoch == epoch, !Task.isCancelled else {
            throw ModelBrokerError.cancelled(originalBroker.cancellationRecord(for: request))
        }
        await onText(result.response.text)
        guard settingsEpoch == epoch, !Task.isCancelled else {
            throw ModelBrokerError.cancelled(originalBroker.cancellationRecord(for: request))
        }
        return result
    }

    private func executeChecked(_ request: ModelGenerationRequest, resolution: ModelRouteResolution, using activeBroker: ProviderRuntimeBroker, maximumAttempts: Int? = nil) async throws -> ModelBrokerResult {
        let epoch = settingsEpoch
        do {
            return try await runActive(request, using: activeBroker) { _, _ in
                try await activeBroker.execute(request, resolution: resolution, maximumAttempts: maximumAttempts)
            }
        } catch let error as ModelBrokerError {
            if settingsEpoch == epoch, let record = error.record {
                for attempt in record.attempts where attempt.outcome == .failed && attempt.identity?.failure == .isolationViolation {
                    guard let connectionID = attempt.identity?.connectionID else { continue }
                    isolationBlocks[connectionID] = ModelConnectionProbe(availability: .unsupported, detail: "dispatch isolation failed")
                    probes.removeValue(forKey: connectionID)
                    inFlightProbes.removeValue(forKey: connectionID)
                }
            }
            throw error
        }
    }

    private func isActive(_ id: UUID, epoch: Int) -> Bool {
        settingsEpoch == epoch && activeRequests[id] != nil
    }

    /// The caller task can be cancelled independently of a settings update.
    /// Both paths cancel the child transport task and return a truthful old-
    /// settings cancellation record even if a driver completes late.
    private func runActive(
        _ request: ModelGenerationRequest,
        using activeBroker: ProviderRuntimeBroker,
        operation: @escaping @Sendable (UUID, Int) async throws -> ModelBrokerResult
    ) async throws -> ModelBrokerResult {
        let epoch = settingsEpoch
        let id = UUID()
        let task = Task { try await operation(id, epoch) }
        activeRequests[id] = task
        defer { activeRequests.removeValue(forKey: id) }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard isActive(id, epoch: epoch), !Task.isCancelled else {
                throw ModelBrokerError.cancelled(activeBroker.cancellationRecord(for: request))
            }
            return result
        } catch {
            if !isActive(id, epoch: epoch) || Task.isCancelled {
                if case .cancelled(let record)? = error as? ModelBrokerError {
                    throw ModelBrokerError.cancelled(record)
                }
                throw ModelBrokerError.cancelled(activeBroker.cancellationRecord(for: request))
            }
            throw error
        }
    }

    public func cancellationRecord(for request: ModelGenerationRequest) async -> ModelExecutionRecord {
        broker.cancellationRecord(for: request)
    }

    /// Diagnostic probe with a short cache. It never grants dispatch
    /// permission and never runs for disabled or unconfigured connections.
    public func probe(connectionID: String, force: Bool = false) async -> ModelConnectionProbe? {
        await probe(connectionID: connectionID, force: force, retryAfterSettingsChange: true)
    }

    private func probe(connectionID: String, force: Bool = false,
                       retryAfterSettingsChange: Bool) async -> ModelConnectionProbe? {
        let epoch = settingsEpoch
        let settings = broker.settings
        guard let connection = broker.registry.effectiveConnection(connectionID, settings: settings),
              let driver = broker.registry.driver(for: connection)
        else { return nil }
        guard connection.enabled else { return ModelConnectionProbe(availability: .disabled) }
        if let issue = driver.configurationIssue(for: connection) {
            return ModelConnectionProbe(availability: issue == .needsLogin ? .needsLogin : .needsConfiguration,
                                        detail: ProviderRuntimeBroker.configurationDetail(connection: connection, issue: issue))
        }
        if let blocked = activeIsolationBlock(for: connectionID) { return blocked }
        if !force, let cached = probes[connectionID], Date().timeIntervalSince(cached.checkedAt) < probeTTL {
            return cached
        }
        let flight: ProbeFlight
        if let existing = inFlightProbes[connectionID] {
            flight = existing
        } else {
            flight = ProbeFlight(id: UUID(), task: Task { await driver.probe(connection: connection) })
            inFlightProbes[connectionID] = flight
        }
        let probe = await flight.task.value
        if settingsEpoch != epoch {
            return retryAfterSettingsChange
                ? await self.probe(connectionID: connectionID, force: force, retryAfterSettingsChange: true)
                : nil
        }
        if let blocked = activeIsolationBlock(for: connectionID) { return blocked }
        if inFlightProbes[connectionID]?.id == flight.id {
            probes[connectionID] = probe
            inFlightProbes.removeValue(forKey: connectionID)
            return probe
        }
        // Another waiter may have cached the same flight; if dispatch invalidated
        // it, start a fresh auth check instead of returning the stale result.
        if let cached = probes[connectionID] { return cached }
        return await self.probe(connectionID: connectionID, force: true,
                                retryAfterSettingsChange: retryAfterSettingsChange)
    }

    public func readiness(probe shouldProbe: Bool) async -> [ModelConnectionReadiness] {
        let settings = broker.settings
        var report: [ModelConnectionReadiness] = []
        for connection in broker.registry.effectiveConnections(settings: settings) {
            let driver = broker.registry.driver(for: connection)
            let issue = driver?.configurationIssue(for: connection)
            let profiles = broker.registry.effectiveProfiles(settings: settings).filter { $0.connectionID == connection.id }.map { profile in
                ModelProfileReadiness(
                    profileID: profile.id,
                    displayName: profile.displayName,
                    modelSelector: profile.modelSelector,
                    options: profile.options,
                    revision: profile.revision,
                    eligibleCommandIDs: profile.eligibleCommandIDs.sorted(),
                    // Qualified means durable evidence only; an active trial is
                    // admission for inspection, not a readiness claim.
                    qualifiedCommandIDs: registry.replacingQualifications(durableQualifications()).qualifiedCommandIDs(for: profile).sorted()
                )
            }
            var availability: ModelConnectionAvailability = .unverified
            var detail: String?
            var observed: ModelAuthRoute?
            var plan: String?
            var availableModels: Set<String>?
            if driver == nil {
                availability = .unsupported
                detail = "driver not implemented"
            } else if !connection.enabled {
                availability = .disabled
            } else if let issue {
                availability = issue == .needsLogin ? .needsLogin : .needsConfiguration
                detail = ProviderRuntimeBroker.configurationDetail(connection: connection, issue: issue)
            } else if shouldProbe, let probe = await self.probe(connectionID: connection.id) {
                availability = probe.availability
                detail = probe.detail
                observed = probe.observedAuthRoute
                plan = probe.reportedPlan
                availableModels = probe.availableModelSelectors
            } else if let cached = activeIsolationBlock(for: connection.id) ?? probes[connection.id] {
                availability = cached.availability
                detail = cached.detail
                observed = cached.observedAuthRoute
                plan = cached.reportedPlan
                availableModels = cached.availableModelSelectors
            }
            if connection.driverID == .ollamaHTTP,
               availability == .ready,
               let availableModels,
               !profiles.isEmpty,
               profiles.allSatisfy({ !availableModels.contains($0.modelSelector) }) {
                availability = .needsConfiguration
                detail = "local model not installed"
            }
            report.append(ModelConnectionReadiness(
                connectionID: connection.id,
                displayName: connection.displayName,
                driverID: connection.driverID,
                authRoute: connection.authRoute,
                enabled: connection.enabled,
                implemented: driver != nil,
                configured: driver != nil && issue == nil,
                configurationIssue: issue,
                availability: availability,
                availabilityDetail: detail,
                observedAuthRoute: observed,
                reportedPlan: plan,
                profiles: profiles,
                fixture: broker.registry.isFixture
            ))
        }
        return report
    }
}
