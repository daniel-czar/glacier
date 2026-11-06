import Foundation

// MARK: - Versioned model-routing contracts

/// Provider classes are policy labels. They deliberately do not name a vendor,
/// model, credential source, or executable.
public enum ModelProviderClass: String, Codable, Sendable, CaseIterable, Hashable {
    case localFast = "local-fast"
    case localCapable = "local-capable"
    case fastHosted = "fast-hosted"
    case capableRemote = "capable-remote"
}

public struct ModelProviderRoute: Codable, Sendable, Equatable, Hashable {
    public let providerClass: ModelProviderClass
    public let requiresQualityEvidence: Bool

    public init(providerClass: ModelProviderClass, requiresQualityEvidence: Bool = false) {
        self.providerClass = providerClass
        self.requiresQualityEvidence = requiresQualityEvidence
    }
}

public struct ModelCommandRuntimePolicy: Codable, Sendable, Equatable {
    public let commandID: String
    public let primary: [ModelProviderRoute]
    public let fallback: [ModelProviderRoute]
    public let offline: [ModelProviderRoute]

    public init(
        commandID: String,
        primary: [ModelProviderRoute],
        fallback: [ModelProviderRoute] = [],
        offline: [ModelProviderRoute] = []
    ) {
        self.commandID = commandID
        self.primary = primary
        self.fallback = fallback
        self.offline = offline
    }

    public func ladder(offline: Bool) -> [ModelProviderRoute] {
        offline ? self.offline : primary + fallback
    }
}

/// A Phase 4 policy is independent from frozen declaration profiles. New
/// receipts record this version so later changes do not reinterpret old runs.
public struct ModelRuntimePolicy: Codable, Sendable, Equatable {
    public let version: String
    public let commands: [ModelCommandRuntimePolicy]

    public init(version: String, commands: [ModelCommandRuntimePolicy]) {
        self.version = version
        self.commands = commands
    }

    public func command(named commandID: String) -> ModelCommandRuntimePolicy? {
        commands.first { $0.commandID == commandID }
    }

    public static let phase4V1 = ModelRuntimePolicy(
        version: "4.0.0",
        commands: [
            .init(
                commandID: "draft.email",
                primary: [.init(providerClass: .capableRemote)],
                fallback: [
                    .init(providerClass: .fastHosted, requiresQualityEvidence: true),
                    .init(providerClass: .localCapable),
                ],
                offline: [.init(providerClass: .localCapable)]
            ),
            .init(
                commandID: "draft.message",
                primary: [
                    .init(providerClass: .localCapable),
                    .init(providerClass: .fastHosted, requiresQualityEvidence: true),
                ],
                fallback: [.init(providerClass: .capableRemote)],
                offline: [.init(providerClass: .localCapable)]
            ),
            .init(
                commandID: "answer.quick",
                primary: [.init(providerClass: .localFast)],
                fallback: [
                    .init(providerClass: .fastHosted, requiresQualityEvidence: true),
                    .init(providerClass: .capableRemote),
                ],
                offline: [.init(providerClass: .localFast)]
            ),
            .init(
                commandID: "translate",
                primary: [.init(providerClass: .localFast)],
                fallback: [
                    .init(providerClass: .fastHosted, requiresQualityEvidence: true),
                    .init(providerClass: .capableRemote),
                ],
                offline: [.init(providerClass: .localFast)]
            ),
            .init(
                commandID: "tier2.proposal",
                primary: [.init(providerClass: .capableRemote)],
                fallback: [.init(providerClass: .localCapable)],
                offline: [.init(providerClass: .localCapable)]
            ),
        ]
    )

    /// Phase 5 records the accepted two remote lanes without changing the
    /// historical Phase 4 interpretation. Concrete provider availability and
    /// command-quality evidence remain runtime inputs, never policy claims.
    public static let phase5V1 = ModelRuntimePolicy(
        version: "5.0.0",
        commands: [
            .init(
                commandID: "draft.email",
                primary: [.init(providerClass: .capableRemote, requiresQualityEvidence: true)],
                fallback: [.init(providerClass: .localCapable, requiresQualityEvidence: true)],
                offline: [.init(providerClass: .localCapable, requiresQualityEvidence: true)]
            ),
            .init(
                commandID: "draft.message",
                primary: [.init(providerClass: .capableRemote, requiresQualityEvidence: true)],
                fallback: [.init(providerClass: .localCapable, requiresQualityEvidence: true)],
                offline: [.init(providerClass: .localCapable, requiresQualityEvidence: true)]
            ),
            .init(
                commandID: "answer.quick",
                primary: [.init(providerClass: .fastHosted, requiresQualityEvidence: true)],
                fallback: [.init(providerClass: .localFast, requiresQualityEvidence: true)],
                offline: [.init(providerClass: .localFast, requiresQualityEvidence: true)]
            ),
            .init(
                commandID: "translate",
                primary: [.init(providerClass: .fastHosted, requiresQualityEvidence: true)],
                fallback: [.init(providerClass: .localFast, requiresQualityEvidence: true)],
                offline: [.init(providerClass: .localFast, requiresQualityEvidence: true)]
            ),
            .init(
                commandID: "tier2.proposal",
                primary: [.init(providerClass: .capableRemote, requiresQualityEvidence: true)],
                fallback: [.init(providerClass: .localCapable, requiresQualityEvidence: true)],
                offline: [.init(providerClass: .localCapable, requiresQualityEvidence: true)]
            ),
        ]
    )
}

/// Frozen 1.1.0 declaration profiles remain historical evidence. In
/// particular, `draft` covers both /email and /msg and remains eligible for
/// capable-remote and local-capable providers even after Phase 4 adds distinct
/// command ladders.
public struct HistoricalModelEligibility: Codable, Sendable, Equatable {
    public let declarationFixtureVersion: String
    public let profile: String
    public let providerClasses: [ModelProviderClass]

    public init(declarationFixtureVersion: String, profile: String, providerClasses: [ModelProviderClass]) {
        self.declarationFixtureVersion = declarationFixtureVersion
        self.profile = profile
        self.providerClasses = providerClasses
    }

    public static func fromFrozenDeclaration(profile: String, fixtureVersion: String = "1.1.0") -> HistoricalModelEligibility? {
        let classes: [ModelProviderClass]
        switch profile {
        case "none": return HistoricalModelEligibility(declarationFixtureVersion: fixtureVersion, profile: profile, providerClasses: [])
        case "draft": classes = [.capableRemote, .localCapable]
        case "quick": classes = [.localFast, .fastHosted, .capableRemote]
        default: return nil
        }
        return HistoricalModelEligibility(
            declarationFixtureVersion: fixtureVersion,
            profile: profile,
            providerClasses: classes
        )
    }
}

// MARK: - Request, attempt, and settings records

public struct ModelGenerationRequest: Codable, Sendable, Equatable {
    public let runID: String
    public let commandID: String
    public let prompt: String
    public let offline: Bool
    public let styleGuide: ModelStyleGuideReference?
    public let contextGuides: [ModelStyleGuideReference]
    /// Preserves canonical syntax and typed semantics separately from a prompt.
    public let input: ModuleInput?
    public let outputConstraint: ModelOutputConstraint
    /// Provider-neutral routing data (generation correlation ID and any
    /// explicit invocation selection). Absent for historical requests.
    public let dispatch: ModelDispatchContext?

    public init(
        runID: String,
        commandID: String,
        prompt: String,
        offline: Bool,
        styleGuide: ModelStyleGuideReference? = nil,
        contextGuides: [ModelStyleGuideReference] = [],
        input: ModuleInput? = nil,
        outputConstraint: ModelOutputConstraint = .plainText(),
        dispatch: ModelDispatchContext? = nil
    ) {
        self.runID = runID
        self.commandID = commandID
        self.prompt = prompt
        self.offline = offline
        self.styleGuide = styleGuide
        self.contextGuides = contextGuides
        self.input = input
        self.outputConstraint = outputConstraint
        self.dispatch = dispatch
    }

    public func with(offline: Bool? = nil, dispatch: ModelDispatchContext?? = nil) -> ModelGenerationRequest {
        ModelGenerationRequest(
            runID: runID,
            commandID: commandID,
            prompt: prompt,
            offline: offline ?? self.offline,
            styleGuide: styleGuide,
            contextGuides: contextGuides,
            input: input,
            outputConstraint: outputConstraint,
            dispatch: dispatch ?? self.dispatch
        )
    }
}

/// Request-independent output discipline appended to every model prompt (the
/// language workflows and in-run follow-ups). A command bar shows the model's
/// text verbatim, so anything that is not the deliverable is a defect: on
/// 2026-09-09 a `/shorter` follow-up came back as a list of options with
/// commentary. Prompts state this once, in one place.
public enum ModelOutputDiscipline {
    public static let instruction = """
    Output discipline: return only the deliverable itself, exactly once. No preamble, headings, options or alternatives unless the task asks for them, no explanation of choices, no meta-commentary, no offers of further help, no questions back, no assistant phrasing such as "Here is" or "Happy to help". If the request is ambiguous, take the most likely reading and return one result.
    """

    /// `/find` in words: the query, never results (D2).
    public static let findQuery = """
    Output discipline: return one JSON object only, with no Markdown, code fence, preamble or trailing text, in exactly this shape: {"filters":"…","terms":"…"}. No other keys, no file names, paths, titles or results, no explanation.
    """

    /// `/stance` asks for options, so its task-level discipline replaces the
    /// shared clause (whose "return one result" would contradict it). Every
    /// other prompt keeps `instruction` unchanged.
    public static let stance = """
    Output discipline: return one JSON object only, with no Markdown, code fence, preamble or trailing text, in exactly this shape: {"positions":[{"title":"…","approach":"…","kind":"accept|decline|other"}],"noticed":[{"type":"…","quote":"…","note":"…"}]}. No draft, no meta-commentary, no questions back.
    """
}

public enum ModelOutputShape: String, Codable, Sendable, Equatable {
    case plainText
    case numberedTranslations
    /// A JSON object only. The proposal subsystem independently validates its
    /// schema, authority, and executable plan after inference.
    case jsonObject
    /// One lowercase hyphenated URL slug of 2-6 words (`URLSlug.normalize`
    /// tolerates surrounding whitespace, quotes and code fences).
    case urlSlug
    /// `/stance`: a JSON object of two to four positions and up to six
    /// noticed items (`StanceResult.parse`). Amendment 1.4.0.
    case stancePositions
    /// `/find` in words (D2): a JSON object of a filter line and a terms
    /// string, nothing else (`FindQueryReply.parse`). Amendment 1.5.0.
    case findQuery

    /// Shapes the provider is asked to return as a JSON object.
    public var requestsJSONObject: Bool {
        switch self {
        case .jsonObject, .stancePositions, .findQuery: true
        case .plainText, .numberedTranslations, .urlSlug: false
        }
    }
}

/// Deterministic slug normalisation shared by output validation and result
/// presentation, so the copied value is exactly what the shape check accepted.
public enum URLSlug {
    public static let minimumWords = 2
    public static let maximumWords = 6

    /// Lowercases, strips wrapping quotes/backticks/fences, folds diacritics,
    /// replaces every non-alphanumeric run with one hyphen and trims hyphens.
    /// Returns `nil` when nothing slug-like remains.
    public static func normalize(_ text: String) -> String? {
        var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Take the first non-empty line: a model that adds commentary after
        // the slug still yields the slug, never the commentary.
        if let first = line.split(whereSeparator: \.isNewline).map(String.init).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            line = first
        }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'“”‘’ \t.,;:!?"))
        // A labelled reply ("Slug: …", "URL slug: …") still yields the slug.
        for label in ["url slug:", "url-slug:", "slug:", "title:"] where line.lowercased().hasPrefix(label) {
            line = String(line.dropFirst(label.count)).trimmingCharacters(in: CharacterSet(charactersIn: "`\"'“”‘’ \t"))
            break
        }
        let folded = line.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var words: [String] = []
        var current = ""
        for scalar in folded.unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        guard !words.isEmpty else { return nil }
        return words.joined(separator: "-")
    }

    /// A normalised slug with an acceptable word count.
    public static func isValid(_ slug: String) -> Bool {
        let words = slug.split(separator: "-", omittingEmptySubsequences: false)
        guard (minimumWords...maximumWords).contains(words.count) else { return false }
        return words.allSatisfy { word in
            !word.isEmpty && word.unicodeScalars.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") }
        }
    }
}

public struct ModelOutputConstraint: Codable, Sendable, Equatable {
    public let shape: ModelOutputShape
    public let maximumCharacters: Int

    public init(shape: ModelOutputShape, maximumCharacters: Int) {
        self.shape = shape
        self.maximumCharacters = maximumCharacters
    }

    public static func plainText(maximumCharacters: Int = 12_000) -> ModelOutputConstraint {
        .init(shape: .plainText, maximumCharacters: maximumCharacters)
    }
}

public struct ModelStyleGuideReference: Codable, Sendable, Equatable {
    public let identifier: String
    public let version: String
    public let status: String
    public let contentSHA256: String

    public init(identifier: String, version: String, status: String, contentSHA256: String) {
        self.identifier = identifier
        self.version = version
        self.status = status
        self.contentSHA256 = contentSHA256
    }
}

public struct ModelUsage: Codable, Sendable, Equatable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    /// Hidden reasoning tokens when the provider reports them separately.
    public let reasoningTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, reasoningTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
    }
}

public enum ModelAttemptOutcome: String, Codable, Sendable, Equatable {
    case succeeded
    case unavailable
    case failed
    case cancelled
}

public struct ModelAttemptRecord: Codable, Sendable, Equatable {
    public let providerID: String
    public let providerClass: ModelProviderClass
    public let outcome: ModelAttemptOutcome
    public let latencyMilliseconds: Int?
    public let usage: ModelUsage?
    public let detail: String?
    /// Policy 6.0.0 attempt identity. Absent for historical v4/v5 receipts,
    /// which keep their original class-ladder interpretation.
    public let identity: ModelAttemptIdentity?

    public init(
        providerID: String,
        providerClass: ModelProviderClass,
        outcome: ModelAttemptOutcome,
        latencyMilliseconds: Int? = nil,
        usage: ModelUsage? = nil,
        detail: String? = nil,
        identity: ModelAttemptIdentity? = nil
    ) {
        self.providerID = providerID
        self.providerClass = providerClass
        self.outcome = outcome
        self.latencyMilliseconds = latencyMilliseconds
        self.usage = usage
        self.detail = detail
        self.identity = identity
    }
}

/// Attached to a result or an explicit failure/cancellation outcome. Missing
/// usage fields mean the provider did not report them; they never mean zero.
public struct ModelExecutionRecord: Codable, Sendable, Equatable {
    public let runtimePolicyVersion: String
    public let commandID: String
    public let runID: String
    public let offline: Bool
    public let styleGuide: ModelStyleGuideReference?
    public let contextGuides: [ModelStyleGuideReference]
    public let settingsConfigurationID: String
    public let settingsConfigurationVersion: Int
    public let attempts: [ModelAttemptRecord]
    /// Policy 6.0.0 routing receipt: selection source/scope and any explicit
    /// API-transition permission. Absent for historical receipts.
    public let route: ModelRouteReceipt?

    public init(
        runtimePolicyVersion: String,
        commandID: String,
        runID: String,
        offline: Bool,
        styleGuide: ModelStyleGuideReference? = nil,
        contextGuides: [ModelStyleGuideReference] = [],
        settingsConfigurationID: String = "default",
        settingsConfigurationVersion: Int = 1,
        attempts: [ModelAttemptRecord],
        route: ModelRouteReceipt? = nil
    ) {
        self.runtimePolicyVersion = runtimePolicyVersion
        self.commandID = commandID
        self.runID = runID
        self.offline = offline
        self.styleGuide = styleGuide
        self.contextGuides = contextGuides
        self.settingsConfigurationID = settingsConfigurationID
        self.settingsConfigurationVersion = settingsConfigurationVersion
        self.attempts = attempts
        self.route = route
    }
}

public struct ModelCommandSettings: Codable, Sendable, Equatable {
    public let commandID: String
    public let enabledProviderIDs: [String]
    public let offlineDefault: Bool
    /// Explicit selections reorder only a command's declared Phase 4 ladder.
    public let mainProviderClass: ModelProviderClass?
    public let fallbackProviderClasses: [ModelProviderClass]

    public init(
        commandID: String,
        enabledProviderIDs: [String] = [],
        offlineDefault: Bool = false,
        mainProviderClass: ModelProviderClass? = nil,
        fallbackProviderClasses: [ModelProviderClass] = []
    ) {
        self.commandID = commandID
        self.enabledProviderIDs = enabledProviderIDs.sorted()
        self.offlineDefault = offlineDefault
        self.mainProviderClass = mainProviderClass
        self.fallbackProviderClasses = fallbackProviderClasses
    }
}

/// Settings are inert data. A separate, explicit owner operation is required
/// to persist them; constructing or reading this value has no side effects.
public struct ModelSettings: Codable, Sendable, Equatable {
    public let runtimePolicyVersion: String
    public let configurationID: String
    public let configurationVersion: Int
    public let commandSettings: [ModelCommandSettings]

    public init(
        runtimePolicyVersion: String = ModelRuntimePolicy.phase4V1.version,
        configurationID: String = "default",
        configurationVersion: Int = 1,
        commandSettings: [ModelCommandSettings] = []
    ) {
        self.runtimePolicyVersion = runtimePolicyVersion
        self.configurationID = configurationID
        self.configurationVersion = configurationVersion
        self.commandSettings = commandSettings.sorted { $0.commandID < $1.commandID }
    }

    public func settings(for commandID: String) -> ModelCommandSettings? {
        commandSettings.first { $0.commandID == commandID }
    }
}
