import Foundation

// MARK: - Policy 6.0.0 provider runtime contracts
//
// Provider family, connection/auth route, model profile and command lane are
// distinct identities. None of them implies command authority or output
// quality. These types are inert data: constructing them performs no lookup,
// launches nothing and resolves no credential.

/// Stable driver identities. A driver translates requests for one protocol;
/// it never selects another provider or changes a billing route.
public enum ModelDriverID: String, Codable, Sendable, CaseIterable, Hashable {
    case cerebrasHTTP = "cerebras-http"
    /// OpenRouter's own chat API (provider preferences, `reasoning` object,
    /// upstream provider and cost in the response).
    case openRouterHTTP = "openrouter-http"
    case codexAppServer = "codex-app-server"
    case claudePrint = "claude-print"
    case openAIHTTP = "openai-http"
    case anthropicHTTP = "anthropic-http"
    case ollamaHTTP = "ollama-http"
}

/// The intended and verifiable auth/billing route of a connection. A label
/// describes the intended route; only a verified attempt establishes the
/// observed route.
public enum ModelAuthRoute: String, Codable, Sendable, CaseIterable, Hashable {
    case cerebrasAPIKey = "cerebras-api-key"
    /// Prepaid OpenRouter credits; a routine hosted route like Cerebras, not
    /// an optional alternative to a subscription.
    case openRouterAPIKey = "openrouter-api-key"
    case chatGPTSubscription = "chatgpt-subscription"
    case claudeSubscription = "claude-subscription"
    case openAIAPIKey = "openai-api-key"
    case anthropicAPIKey = "anthropic-api-key"
    case localService = "local-service"

    /// Subscription routes are never reached by routine automatic routing.
    public var isSubscription: Bool {
        switch self {
        case .chatGPTSubscription, .claudeSubscription: true
        default: false
        }
    }

    /// The optional API-key alternatives are disabled by default and require
    /// an explicit route permission in addition to an enabled connection.
    public var isOptionalAPIAlternative: Bool {
        switch self {
        case .openAIAPIKey, .anthropicAPIKey: true
        default: false
        }
    }

    public var billingFamily: String {
        switch self {
        case .cerebrasAPIKey, .openRouterAPIKey, .openAIAPIKey, .anthropicAPIKey: "api-key"
        case .chatGPTSubscription, .claudeSubscription: "subscription"
        case .localService: "local"
        }
    }
}

public enum ModelReasoningLevel: String, Codable, Sendable, CaseIterable, Hashable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
}

/// Explicit generation settings of a model profile. Unsupported settings are
/// rejected before dispatch, never dropped silently.
public struct ModelGenerationOptions: Codable, Sendable, Equatable, Hashable {
    public let reasoning: ModelReasoningLevel?
    public let maximumOutputTokens: Int?
    public let temperature: Double?

    public init(reasoning: ModelReasoningLevel? = nil, maximumOutputTokens: Int? = nil, temperature: Double? = nil) {
        self.reasoning = reasoning
        self.maximumOutputTokens = maximumOutputTokens
        self.temperature = temperature
    }

    /// Stable digest input used to bind qualification evidence to the exact
    /// transmitted options.
    public var stableDescription: String {
        "reasoning=\(reasoning?.rawValue ?? "unset");maxOutput=\(maximumOutputTokens.map(String.init) ?? "unset");temperature=\(temperature.map { String(format: "%.3f", $0) } ?? "unset")"
    }
}

/// Technical capabilities a driver/profile supports. They are distinct from
/// command-specific quality qualification.
public enum ModelCapability: String, Codable, Sendable, CaseIterable, Hashable {
    case plainText
    case structuredJSONObject
    case reasoningLevel
    case outputTokenLimit
    case temperature
}

/// How a connection locates its credential. Values are references only; no
/// secret is ever stored in configuration, descriptors, snapshots or receipts.
public enum ModelCredentialReference: Codable, Sendable, Equatable, Hashable {
    case environmentVariable(name: String)
    case dotenvFile(path: String, key: String)
    case keychain(service: String, account: String)

    public var redactedDescription: String {
        switch self {
        case .keychain: "keychain:<credential-reference>"
        case .environmentVariable(let name): "env:\(name)"
        case .dotenvFile(let path, let key): "dotenv:\(path)#\(key)"
        }
    }
}

/// Reference to an owned CLI configuration boundary. The runtime owns the
/// configuration directory and neutral workspace; the CLI owns login/refresh.
public struct ModelCLIProfileReference: Codable, Sendable, Equatable, Hashable {
    /// Executable name resolved through the allowlisted PATH, or an absolute path.
    public let executable: String
    /// Owned configuration directory (`CODEX_HOME` / `CLAUDE_CONFIG_DIR`).
    /// Relative values resolve beneath the runtime's provider support root.
    public let configurationDirectory: String

    public init(executable: String, configurationDirectory: String) {
        self.executable = executable
        self.configurationDirectory = configurationDirectory
    }
}

public struct ModelConnectionProfile: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let driverID: ModelDriverID
    public let displayName: String
    public let enabled: Bool
    public let authRoute: ModelAuthRoute
    public let isRemote: Bool
    public let endpoint: URL?
    public let credentialReference: ModelCredentialReference?
    public let cliProfile: ModelCLIProfileReference?
    public let revision: Int

    public init(
        id: String,
        driverID: ModelDriverID,
        displayName: String,
        enabled: Bool,
        authRoute: ModelAuthRoute,
        isRemote: Bool,
        endpoint: URL? = nil,
        credentialReference: ModelCredentialReference? = nil,
        cliProfile: ModelCLIProfileReference? = nil,
        revision: Int = 1
    ) {
        self.id = id
        self.driverID = driverID
        self.displayName = displayName
        self.enabled = enabled
        self.authRoute = authRoute
        self.isRemote = isRemote
        self.endpoint = endpoint
        self.credentialReference = credentialReference
        self.cliProfile = cliProfile
        self.revision = revision
    }

    public func with(enabled: Bool? = nil, endpoint: URL?? = nil, credentialReference: ModelCredentialReference?? = nil, cliProfile: ModelCLIProfileReference?? = nil, revision: Int? = nil) -> ModelConnectionProfile {
        ModelConnectionProfile(
            id: id,
            driverID: driverID,
            displayName: displayName,
            enabled: enabled ?? self.enabled,
            authRoute: authRoute,
            isRemote: isRemote,
            endpoint: endpoint ?? self.endpoint,
            credentialReference: credentialReference ?? self.credentialReference,
            cliProfile: cliProfile ?? self.cliProfile,
            revision: revision ?? self.revision
        )
    }
}

public struct ModelProfile: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let connectionID: String
    public let displayName: String
    public let modelSelector: String
    public let options: ModelGenerationOptions
    public let capabilities: Set<ModelCapability>
    public let eligibleCommandIDs: Set<String>
    public let revision: Int

    public init(
        id: String,
        connectionID: String,
        displayName: String? = nil,
        modelSelector: String,
        options: ModelGenerationOptions = .init(),
        capabilities: Set<ModelCapability>,
        eligibleCommandIDs: Set<String>,
        revision: Int = 1
    ) {
        self.id = id
        self.connectionID = connectionID
        self.displayName = displayName ?? ProviderRuntimeCatalog.displayLabel(profileID: id, connectionID: connectionID, modelSelector: modelSelector, options: options)
        self.modelSelector = modelSelector
        self.options = options
        self.capabilities = capabilities
        self.eligibleCommandIDs = eligibleCommandIDs
        self.revision = revision
    }

    public func with(modelSelector: String? = nil, options: ModelGenerationOptions? = nil, revision: Int? = nil) -> ModelProfile {
        ModelProfile(
            id: id,
            connectionID: connectionID,
            displayName: nil,
            modelSelector: modelSelector ?? self.modelSelector,
            options: options ?? self.options,
            capabilities: capabilities,
            eligibleCommandIDs: eligibleCommandIDs,
            revision: revision ?? self.revision
        )
    }

    /// Qualification binds to this exact material identity. Changing the
    /// model, reasoning or output options invalidates transferred evidence.
    public var qualificationBinding: String {
        "\(id)@\(revision)|\(modelSelector)|\(options.stableDescription)"
    }
}

/// Ordered command routing under policy 6.0.0. IDs are persisted, never labels.
public struct ModelCommandPolicy: Codable, Sendable, Equatable {
    public let commandID: String
    public let primaryProfileIDs: [String]
    public let fallbackProfileIDs: [String]
    public let offlineProfileIDs: [String]
    public let requiredCapabilities: Set<ModelCapability>
    public let outputShape: ModelOutputShape

    public init(
        commandID: String,
        primaryProfileIDs: [String],
        fallbackProfileIDs: [String] = [],
        offlineProfileIDs: [String] = [],
        requiredCapabilities: Set<ModelCapability> = [.plainText],
        outputShape: ModelOutputShape = .plainText
    ) {
        self.commandID = commandID
        self.primaryProfileIDs = primaryProfileIDs
        self.fallbackProfileIDs = fallbackProfileIDs
        self.offlineProfileIDs = offlineProfileIDs
        self.requiredCapabilities = requiredCapabilities
        self.outputShape = outputShape
    }

    public func ladder(offline: Bool) -> [String] {
        offline ? offlineProfileIDs : primaryProfileIDs + fallbackProfileIDs
    }
}

public struct ModelProviderPolicy: Codable, Sendable, Equatable {
    public let version: String
    public let commands: [ModelCommandPolicy]

    public init(version: String, commands: [ModelCommandPolicy]) {
        self.version = version
        self.commands = commands
    }

    public func command(named commandID: String) -> ModelCommandPolicy? {
        commands.first { $0.commandID == commandID }
    }

    public var commandIDs: [String] { commands.map(\.commandID) }
}

/// Command-specific quality evidence bound to the exact profile material.
public struct ModelQualification: Codable, Sendable, Equatable, Hashable {
    public let commandID: String
    public let profileID: String
    public let qualificationBinding: String
    public let outputShape: ModelOutputShape
    public let evidenceReference: String
    public let recordedAt: Date

    public init(commandID: String, profileID: String, qualificationBinding: String, outputShape: ModelOutputShape, evidenceReference: String, recordedAt: Date) {
        self.commandID = commandID
        self.profileID = profileID
        self.qualificationBinding = qualificationBinding
        self.outputShape = outputShape
        self.evidenceReference = evidenceReference
        self.recordedAt = recordedAt
    }

    public func covers(commandID: String, profile: ModelProfile, outputShape: ModelOutputShape) -> Bool {
        self.commandID == commandID
            && profileID == profile.id
            && qualificationBinding == profile.qualificationBinding
            && self.outputShape == outputShape
    }
}

// MARK: - Dispatch context and selection scope

/// Where a selected profile came from. Saved choices reference their settings
/// revision; invocation choices are scoped to one generation correlation ID.
public enum ModelSelectionSource: Codable, Sendable, Equatable, Hashable {
    case policyDefault
    case savedCommandOptIn(settingsRevision: Int)
    case invocationOverride(generationID: String)

    public var label: String {
        switch self {
        case .policyDefault: "policy-default"
        case .savedCommandOptIn(let revision): "saved-opt-in@\(revision)"
        case .invocationOverride(let generationID): "invocation-override:\(generationID)"
        }
    }
}

public enum ModelPermissionScope: Codable, Sendable, Equatable, Hashable {
    case saved(settingsRevision: Int)
    case invocation(generationID: String)
}

/// Explicit permission for the billing transition onto an optional API-key
/// connection. Enabling a connection alone never creates this permission.
public struct ModelAPITransitionPermission: Codable, Sendable, Equatable, Hashable {
    public let connectionID: String
    public let scope: ModelPermissionScope

    public init(connectionID: String, scope: ModelPermissionScope) {
        self.connectionID = connectionID
        self.scope = scope
    }
}

/// The user's deliberate one-invocation selection. It travels with the
/// invocation input and expires with that generation; follow-ups never inherit it.
public struct ModelInvocationSelection: Codable, Sendable, Equatable, Hashable {
    public let profileID: String
    /// Required in addition to the profile when the profile's connection is an
    /// optional API alternative; false never permits an API billing route.
    public let permitsAPIRoute: Bool

    public init(profileID: String, permitsAPIRoute: Bool = false) {
        self.profileID = profileID
        self.permitsAPIRoute = permitsAPIRoute
    }
}

/// Provider-neutral routing data passed by the application, separate from the
/// workflow prompt. This is ordinary dispatch data, not an approval system.
public struct ModelDispatchContext: Codable, Sendable, Equatable, Hashable {
    /// Generation correlation ID, distinct from the durable Omni RunID and from
    /// provider-native session/turn identifiers.
    public let generationID: String
    public let selection: ModelInvocationSelection?

    public init(generationID: String, selection: ModelInvocationSelection? = nil) {
        self.generationID = generationID
        self.selection = selection
    }
}

// MARK: - Normalized outcomes

public enum ModelFailureKind: String, Codable, Sendable, CaseIterable, Hashable {
    case disabled
    case unconfigured
    case needsConfiguration
    case needsLogin
    case authRequired
    case authMismatch
    case rateLimited
    case quotaExhausted
    case timeout
    case cancelled
    case unsupportedCapability
    case ineligibleCommand
    case unqualified
    case contextOrOutputLimit
    case invalidResponse
    case modelMismatch
    case isolationViolation
    case offlineExcludesRemote
    case requiresExplicitSelection
    case apiRoutePermissionRequired
    case attemptBudgetExhausted
    case concurrencyLimit
    case providerFailure
    case storageFailure

    /// Authentication and quota outcomes never trigger blind retries or a
    /// fallback onto another billing route.
    public var stopsFallback: Bool {
        switch self {
        case .authRequired, .authMismatch, .needsLogin, .quotaExhausted, .isolationViolation, .modelMismatch, .cancelled, .attemptBudgetExhausted: true
        default: false
        }
    }
}

/// Derived connection state. Enabled does not mean ready; ready does not
/// mean qualified. This is diagnostic; dispatch re-verifies every attempt.
public enum ModelConnectionAvailability: String, Codable, Sendable, CaseIterable, Hashable {
    case disabled
    case needsConfiguration
    case needsLogin
    case authMismatch
    case quotaLimited
    case unsupported
    case unverified
    case ready
}

/// Non-secret facts a driver observed about the effective execution
/// environment of one attempt. Absence means unknown, never verified.
public struct ModelIsolationAttestation: Codable, Sendable, Equatable, Hashable {
    public let environmentAllowlisted: Bool
    public let configurationOwned: Bool
    public let workspaceNeutral: Bool
    public let toolsDisabled: Bool
    public let instructionSourcesEmpty: Bool
    public let freshConversation: Bool
    public let detail: [String: String]

    public init(
        environmentAllowlisted: Bool,
        configurationOwned: Bool,
        workspaceNeutral: Bool,
        toolsDisabled: Bool,
        instructionSourcesEmpty: Bool,
        freshConversation: Bool,
        detail: [String: String] = [:]
    ) {
        self.environmentAllowlisted = environmentAllowlisted
        self.configurationOwned = configurationOwned
        self.workspaceNeutral = workspaceNeutral
        self.toolsDisabled = toolsDisabled
        self.instructionSourcesEmpty = instructionSourcesEmpty
        self.freshConversation = freshConversation
        self.detail = detail
    }

    public var isFullyIsolated: Bool {
        environmentAllowlisted && configurationOwned && workspaceNeutral && toolsDisabled && instructionSourcesEmpty && freshConversation
    }
}

/// Per-execution routing receipt recorded alongside attempts.
public struct ModelRouteReceipt: Codable, Sendable, Equatable, Hashable {
    public let policyVersion: String
    public let settingsRevision: Int
    public let generationID: String
    public let selectionSource: ModelSelectionSource
    public let selectedProfileID: String?
    public let apiTransition: ModelAPITransitionPermission?
    public let candidateProfileIDs: [String]

    public init(
        policyVersion: String,
        settingsRevision: Int,
        generationID: String,
        selectionSource: ModelSelectionSource,
        selectedProfileID: String? = nil,
        apiTransition: ModelAPITransitionPermission? = nil,
        candidateProfileIDs: [String] = []
    ) {
        self.policyVersion = policyVersion
        self.settingsRevision = settingsRevision
        self.generationID = generationID
        self.selectionSource = selectionSource
        self.selectedProfileID = selectedProfileID
        self.apiTransition = apiTransition
        self.candidateProfileIDs = candidateProfileIDs
    }
}

/// Provider/connection identity of one attempt. Secrets, raw environments and
/// full process streams are never part of this record.
public struct ModelAttemptIdentity: Codable, Sendable, Equatable, Hashable {
    public let attemptID: String
    public let profileID: String
    public let profileRevision: Int
    public let connectionID: String
    public let driverID: ModelDriverID
    public let expectedAuthRoute: ModelAuthRoute
    public let observedAuthRoute: ModelAuthRoute?
    public let requestedModel: String
    public let resolvedModel: String?
    public let options: ModelGenerationOptions
    public let failure: ModelFailureKind?
    public let retryAfterSeconds: Double?
    public let nativeReference: String?
    public let reportedPlan: String?
    /// Upstream provider named by a routing connection (OpenRouter's
    /// `provider`); `nil` when the connection serves the model itself.
    public let servedBy: String?
    public let estimatedCostUSD: Double?
    public let isolation: ModelIsolationAttestation?
    public let fixture: Bool
    /// Evidence reference of the qualification that admitted this profile, or a
    /// `qualification-trial:` reference when an explicit bounded trial admitted it.
    public let qualificationEvidence: String?

    public init(
        attemptID: String,
        profileID: String,
        profileRevision: Int,
        connectionID: String,
        driverID: ModelDriverID,
        expectedAuthRoute: ModelAuthRoute,
        observedAuthRoute: ModelAuthRoute? = nil,
        requestedModel: String,
        resolvedModel: String? = nil,
        options: ModelGenerationOptions = .init(),
        failure: ModelFailureKind? = nil,
        retryAfterSeconds: Double? = nil,
        nativeReference: String? = nil,
        reportedPlan: String? = nil,
        servedBy: String? = nil,
        estimatedCostUSD: Double? = nil,
        isolation: ModelIsolationAttestation? = nil,
        fixture: Bool = false,
        qualificationEvidence: String? = nil
    ) {
        self.attemptID = attemptID
        self.profileID = profileID
        self.profileRevision = profileRevision
        self.connectionID = connectionID
        self.driverID = driverID
        self.expectedAuthRoute = expectedAuthRoute
        self.observedAuthRoute = observedAuthRoute
        self.requestedModel = requestedModel
        self.resolvedModel = resolvedModel
        self.options = options
        self.failure = failure
        self.retryAfterSeconds = retryAfterSeconds
        self.nativeReference = nativeReference
        self.reportedPlan = reportedPlan
        self.servedBy = servedBy
        self.estimatedCostUSD = estimatedCostUSD
        self.isolation = isolation
        self.fixture = fixture
        self.qualificationEvidence = qualificationEvidence
    }
}
