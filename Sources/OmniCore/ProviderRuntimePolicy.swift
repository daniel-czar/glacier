import Foundation

// MARK: - Policy 6.0.0 and the initial connection/profile catalogue

public extension ModelProviderPolicy {
    /// Cerebras-first routine routing with OpenRouter's GPT-OSS profile as the
    /// hosted fallback (accepted 2026-09-09 after latency-sorted OpenRouter
    /// served it from Cerebras at 300-520 ms) ahead of the local Ollama
    /// profiles. Fallback still dispatches only where the command is
    /// qualified. Subscription and API-alternative profiles appear in no
    /// automatic ladder; they are reached only through a saved per-command
    /// opt-in or a one-invocation override.
    static let v6 = ModelProviderPolicy(
        version: "6.0.0",
        commands: [
            .init(
                commandID: "answer.quick",
                primaryProfileIDs: [ProviderRuntimeCatalog.cerebrasFastProfileID],
                fallbackProfileIDs: [ProviderRuntimeCatalog.openRouterGPTOSSProfileID, ProviderRuntimeCatalog.localFastProfileID],
                offlineProfileIDs: [ProviderRuntimeCatalog.localFastProfileID]
            ),
            .init(
                commandID: "translate",
                primaryProfileIDs: [ProviderRuntimeCatalog.cerebrasFastProfileID],
                fallbackProfileIDs: [ProviderRuntimeCatalog.openRouterGPTOSSProfileID, ProviderRuntimeCatalog.localFastProfileID],
                offlineProfileIDs: [ProviderRuntimeCatalog.localFastProfileID],
                outputShape: .numberedTranslations
            ),
            .init(
                commandID: "title.slug",
                primaryProfileIDs: [ProviderRuntimeCatalog.cerebrasFastProfileID],
                fallbackProfileIDs: [ProviderRuntimeCatalog.openRouterGPTOSSProfileID, ProviderRuntimeCatalog.localFastProfileID],
                offlineProfileIDs: [ProviderRuntimeCatalog.localFastProfileID],
                outputShape: .urlSlug
            ),
            // Drafting favors the high-reasoning profile. Online failure does
            // not silently downgrade to a weaker automatic model.
            .init(
                commandID: "draft.email",
                primaryProfileIDs: [ProviderRuntimeCatalog.cerebrasDraftProfileID],
                fallbackProfileIDs: [],
                offlineProfileIDs: [ProviderRuntimeCatalog.localFastProfileID]
            ),
            .init(
                commandID: "draft.message",
                primaryProfileIDs: [ProviderRuntimeCatalog.cerebrasDraftProfileID],
                fallbackProfileIDs: [],
                offlineProfileIDs: [ProviderRuntimeCatalog.localFastProfileID]
            ),
            // Amendment 1.4.0: `/stance` defaults to the careful profile (the H7
            // comparison saw the fast one reverse roles in an incoming reply);
            // automatic routing still needs recorded qualification (C67).
            .init(
                commandID: "decide.stance",
                primaryProfileIDs: [ProviderRuntimeCatalog.cerebrasCarefulProfileID],
                fallbackProfileIDs: [ProviderRuntimeCatalog.openRouterGPTOSSProfileID, ProviderRuntimeCatalog.localFastProfileID],
                offlineProfileIDs: [ProviderRuntimeCatalog.localFastProfileID],
                requiredCapabilities: [.structuredJSONObject],
                outputShape: .stancePositions
            ),
            // Milestone 3 transforms: routine text results on the fast profile.
            .init(
                commandID: "think.structure",
                primaryProfileIDs: [ProviderRuntimeCatalog.cerebrasFastProfileID],
                fallbackProfileIDs: [ProviderRuntimeCatalog.openRouterGPTOSSProfileID, ProviderRuntimeCatalog.localFastProfileID],
                offlineProfileIDs: [ProviderRuntimeCatalog.localFastProfileID]
            ),
            .init(
                commandID: "think.expand",
                primaryProfileIDs: [ProviderRuntimeCatalog.cerebrasFastProfileID],
                fallbackProfileIDs: [ProviderRuntimeCatalog.openRouterGPTOSSProfileID, ProviderRuntimeCatalog.localFastProfileID],
                offlineProfileIDs: [ProviderRuntimeCatalog.localFastProfileID]
            ),
            .init(
                commandID: "think.meaning",
                primaryProfileIDs: [ProviderRuntimeCatalog.cerebrasFastProfileID],
                fallbackProfileIDs: [ProviderRuntimeCatalog.openRouterGPTOSSProfileID, ProviderRuntimeCatalog.localFastProfileID],
                offlineProfileIDs: [ProviderRuntimeCatalog.localFastProfileID]
            ),
            // Amendment 1.5.0: `/find` in words writes a query, never sees
            // rows (D2). Ids and filters never reach this row.
            .init(
                commandID: "find.indexed",
                primaryProfileIDs: [ProviderRuntimeCatalog.cerebrasFastProfileID],
                fallbackProfileIDs: [ProviderRuntimeCatalog.openRouterGPTOSSProfileID, ProviderRuntimeCatalog.localFastProfileID],
                offlineProfileIDs: [ProviderRuntimeCatalog.localFastProfileID],
                requiredCapabilities: [.structuredJSONObject],
                outputShape: .findQuery
            ),
            .init(
                commandID: "recall.command",
                primaryProfileIDs: [ProviderRuntimeCatalog.cerebrasFastProfileID],
                fallbackProfileIDs: [],
                offlineProfileIDs: [],
                requiredCapabilities: [.structuredJSONObject],
                outputShape: .jsonObject
            ),
            .init(
                commandID: "emoji.suggest",
                primaryProfileIDs: [ProviderRuntimeCatalog.cerebrasFastProfileID],
                fallbackProfileIDs: [],
                offlineProfileIDs: [],
                requiredCapabilities: [.structuredJSONObject],
                outputShape: .jsonObject
            ),
            .init(
                commandID: "express.alternatives",
                primaryProfileIDs: [ProviderRuntimeCatalog.cerebrasFastLowProfileID],
                fallbackProfileIDs: [ProviderRuntimeCatalog.cerebrasFastProfileID, ProviderRuntimeCatalog.openRouterGPTOSSProfileID],
                offlineProfileIDs: [],
                requiredCapabilities: [.plainText],
                outputShape: .plainText
            ),
            .init(
                commandID: "map.draw",
                primaryProfileIDs: [ProviderRuntimeCatalog.cerebrasConceptHighProfileID],
                fallbackProfileIDs: [],
                offlineProfileIDs: [],
                requiredCapabilities: [.plainText],
                outputShape: .plainText
            ),
            .init(
                commandID: "regex.write",
                primaryProfileIDs: [ProviderRuntimeCatalog.cerebrasRegexHighProfileID],
                fallbackProfileIDs: [],
                offlineProfileIDs: [],
                requiredCapabilities: [.plainText],
                outputShape: .plainText
            ),
            .init(
                commandID: "tier2.proposal",
                primaryProfileIDs: [ProviderRuntimeCatalog.cerebrasCarefulProfileID],
                fallbackProfileIDs: [],
                offlineProfileIDs: [ProviderRuntimeCatalog.localFastProfileID],
                requiredCapabilities: [.structuredJSONObject],
                outputShape: .jsonObject
            ),
        ]
    )
}

/// Initial configurable defaults under the accepted policy. Model selectors
/// are configuration values seeded from the evaluated Cerebras lab, not
/// permanent workflow identifiers.
public enum ProviderRuntimeCatalog {
    public static let cerebrasConnectionID = "cerebras"
    public static let openRouterConnectionID = "openrouter"
    public static let chatGPTConnectionID = "chatgpt"
    public static let claudeConnectionID = "claude"
    public static let openAIAPIConnectionID = "openai-api"
    public static let anthropicAPIConnectionID = "anthropic-api"
    public static let localConnectionID = "local-ollama"

    public static let cerebrasFastProfileID = "cerebras-fast"
    /// High-reasoning Qwen profile for deliberate email and message drafting.
    public static let cerebrasDraftProfileID = "cerebras-draft"
    /// Qwen 3.8 27B with low reasoning: the live translation tool (Hyper+L)
    /// selects it explicitly; no automatic ladder contains it.
    public static let cerebrasFastLowProfileID = "cerebras-fast-low"
    /// Concept Lens uses one nonstreaming, high-reasoning Cerebras call.
    public static let cerebrasConceptHighProfileID = "cerebras-concept-high"
    /// Regex needs a larger high-reasoning completion budget for its checked examples.
    public static let cerebrasRegexHighProfileID = "cerebras-regex-high"
    public static let cerebrasCarefulProfileID = "cerebras-careful"
    public static let openRouterGemmaProfileID = "openrouter-gemma"
    public static let openRouterGPTOSSProfileID = "openrouter-gpt-oss"
    public static let chatGPTCapableProfileID = "chatgpt-capable"
    public static let claudeCapableProfileID = "claude-capable"
    public static let openAIAPICapableProfileID = "openai-api-capable"
    public static let anthropicAPICapableProfileID = "anthropic-api-capable"
    public static let localFastProfileID = "local-fast"
    /// Retired identity retained only to read saved routes and historical evidence.
    public static let localCapableProfileID = "local-capable"

    public static func canonicalProfileID(_ id: String) -> String {
        id == localCapableProfileID ? localFastProfileID : id
    }

    /// Catalog labels are computed from the actual selector and generation options.
    /// Explicit names handle provider aliases; unknown saved selectors remain legible.
    public static func displayLabel(connectionID: String, modelSelector: String, options: ModelGenerationOptions) -> String {
        let provider: String
        switch connectionID {
        case cerebrasConnectionID: provider = "Cerebras"
        case openRouterConnectionID: provider = "OpenRouter"
        case chatGPTConnectionID: provider = "ChatGPT"
        case claudeConnectionID: provider = "Claude"
        case openAIAPIConnectionID: provider = "OpenAI API"
        case anthropicAPIConnectionID: provider = "Anthropic API"
        case localConnectionID: provider = "Local"
        default: provider = connectionID
        }
        let model: String
        switch modelSelector {
        case "qwen-3.8-27b": model = "Qwen 3.8 27B"
        case "gpt-oss-120b", "openai/gpt-oss-120b": model = "GPT-OSS 120B"
        case "google/gemma-4-31b-it": model = "Gemma 4 31B"
        case "gpt-5.6-sol": model = "GPT-5.6"
        case "gpt-5.4": model = "GPT-5.4"
        case "sonnet": model = "Sonnet"
        case "claude-sonnet-4-5": model = "Claude Sonnet 4.5"
        case "qwen3:8b": model = "Qwen3 8B"
        default:
            model = modelSelector.replacingOccurrences(of: ".", with: " ")
                .replacingOccurrences(of: "/", with: " ")
                .replacingOccurrences(of: ":", with: " ")
                .replacingOccurrences(of: "_", with: " ")
        }
        let effort = options.reasoning.flatMap { $0 == .none ? nil : $0.rawValue }
        let capacity = options.maximumOutputTokens.flatMap { tokens -> String? in
            guard tokens >= 16_384 else { return nil }
            return (tokens.isMultiple(of: 1_024) ? "\(tokens / 1_024)k" : "\(tokens)") + " output"
        }
        return ([provider, model] + (effort.map { [$0] } ?? []) + (capacity.map { [$0] } ?? [])).joined(separator: " ")
    }

    public static func displayLabel(profileID: String, connectionID: String, modelSelector: String, options: ModelGenerationOptions) -> String {
        let label = displayLabel(connectionID: connectionID, modelSelector: modelSelector, options: options)
        return profileID == cerebrasDraftProfileID ? label + " drafting" : label
    }

    /// Command-set amendment 1.2.0 added `title.slug` (`/slug`) as a routine
    /// command; it follows the quick ladder like `translate`. Amendment 1.4.0
    /// adds `decide.stance` and the three `think.*` transforms, eligible on
    /// both Cerebras profiles (eligibility is not part of a qualification
    /// binding, so no evidence moves). Amendment 1.5.0 adds `find.indexed`,
    /// the `/find` in words tier. The ephemeral Recall and Emoji tools add
    /// `recall.command` and `emoji.suggest`, both cerebras-fast only.
    public static let routineCommandIDs: Set<String> = ["answer.quick", "translate", "title.slug", "draft.email", "draft.message", "decide.stance", "think.structure", "think.expand", "think.meaning", "find.indexed", "recall.command", "emoji.suggest", "express.alternatives"]
    public static let allModelCommandIDs: Set<String> = routineCommandIDs.union(["map.draw", "regex.write", "tier2.proposal"])

    public static let connections: [ModelConnectionProfile] = [
        .init(
            id: cerebrasConnectionID,
            driverID: .cerebrasHTTP,
            displayName: "Cerebras",
            enabled: true,
            authRoute: .cerebrasAPIKey,
            isRemote: true,
            endpoint: URL(string: "https://api.cerebras.ai/v1/chat/completions")
        ),
        // OpenRouter: prepaid credits, routes each request to the fastest
        // upstream for the selected model. `openrouter-gpt-oss` is the hosted
        // fallback of the routine ladders; `openrouter-gemma` is explicit only.
        .init(
            id: openRouterConnectionID,
            driverID: .openRouterHTTP,
            displayName: "OpenRouter",
            enabled: true,
            authRoute: .openRouterAPIKey,
            isRemote: true,
            endpoint: URL(string: "https://openrouter.ai/api/v1/chat/completions")
        ),
        .init(
            id: chatGPTConnectionID,
            driverID: .codexAppServer,
            displayName: "ChatGPT (Codex CLI)",
            enabled: true,
            authRoute: .chatGPTSubscription,
            isRemote: true,
            cliProfile: .init(executable: "codex", configurationDirectory: "codex-home")
        ),
        .init(
            id: claudeConnectionID,
            driverID: .claudePrint,
            displayName: "Claude (Claude Code CLI)",
            enabled: true,
            authRoute: .claudeSubscription,
            isRemote: true,
            cliProfile: .init(executable: "claude", configurationDirectory: "~/.claude-omni")
        ),
        .init(
            id: openAIAPIConnectionID,
            driverID: .openAIHTTP,
            displayName: "OpenAI API",
            enabled: false,
            authRoute: .openAIAPIKey,
            isRemote: true,
            endpoint: URL(string: "https://api.openai.com/v1/chat/completions")
        ),
        .init(
            id: anthropicAPIConnectionID,
            driverID: .anthropicHTTP,
            displayName: "Anthropic API",
            enabled: false,
            authRoute: .anthropicAPIKey,
            isRemote: true,
            endpoint: URL(string: "https://api.anthropic.com/v1/messages")
        ),
        .init(
            id: localConnectionID,
            driverID: .ollamaHTTP,
            displayName: "Local (Ollama)",
            enabled: true,
            authRoute: .localService,
            isRemote: false,
            endpoint: URL(string: "http://127.0.0.1:11434")
        ),
    ]

    public static let profiles: [ModelProfile] = [
        .init(
            id: cerebrasFastProfileID,
            connectionID: cerebrasConnectionID,
            // gemma-4-31b left Cerebras' public endpoints on 2026-09-03; Qwen
            // 3.8 27B is the documented public replacement (reasoning default
            // high, disabled here through reasoning_effort none).
            modelSelector: "qwen-3.8-27b",
            options: .init(reasoning: ModelReasoningLevel.none, maximumOutputTokens: 1_200, temperature: 0.1),
            capabilities: [.plainText, .structuredJSONObject, .reasoningLevel, .outputTokenLimit, .temperature],
            eligibleCommandIDs: routineCommandIDs
        ),
        .init(
            id: cerebrasFastLowProfileID,
            connectionID: cerebrasConnectionID,
            // Same model as cerebras-fast, allowed to think briefly. With
            // reasoning off it echoed lowercase German nouns ("hutmacher")
            // untranslated; Express gets them right on the same model with
            // low reasoning. The output limit counts reasoning tokens.
            modelSelector: "qwen-3.8-27b",
            options: .init(reasoning: .low, maximumOutputTokens: 2_400, temperature: 0.25),
            capabilities: [.plainText, .structuredJSONObject, .reasoningLevel, .outputTokenLimit, .temperature],
            eligibleCommandIDs: ["translate", "express.alternatives"]
        ),
        .init(
            id: cerebrasDraftProfileID,
            connectionID: cerebrasConnectionID,
            modelSelector: "qwen-3.8-27b",
            options: .init(reasoning: .high, maximumOutputTokens: 16_384, temperature: 0.1),
            capabilities: [.plainText, .structuredJSONObject, .reasoningLevel, .outputTokenLimit, .temperature],
            eligibleCommandIDs: ["draft.email", "draft.message"]
        ),
        .init(
            id: cerebrasConceptHighProfileID,
            connectionID: cerebrasConnectionID,
            modelSelector: "qwen-3.8-27b",
            options: .init(reasoning: .high, maximumOutputTokens: 4_096, temperature: 0.1),
            capabilities: [.plainText, .structuredJSONObject, .reasoningLevel, .outputTokenLimit, .temperature],
            eligibleCommandIDs: ["think.meaning", "map.draw"]
        ),
        .init(
            id: cerebrasRegexHighProfileID,
            connectionID: cerebrasConnectionID,
            modelSelector: "qwen-3.8-27b",
            options: .init(reasoning: .high, maximumOutputTokens: 16_384, temperature: 0.1),
            capabilities: [.plainText, .structuredJSONObject, .reasoningLevel, .outputTokenLimit, .temperature],
            eligibleCommandIDs: ["regex.write"]
        ),
        .init(
            id: cerebrasCarefulProfileID,
            connectionID: cerebrasConnectionID,
            modelSelector: "gpt-oss-120b",
            options: .init(reasoning: .medium, maximumOutputTokens: 2_400, temperature: 0.1),
            capabilities: [.plainText, .structuredJSONObject, .reasoningLevel, .outputTokenLimit, .temperature],
            eligibleCommandIDs: allModelCommandIDs
        ),
        .init(
            id: openRouterGemmaProfileID,
            connectionID: openRouterConnectionID,
            modelSelector: "google/gemma-4-31b-it",
            options: .init(reasoning: ModelReasoningLevel.none, maximumOutputTokens: 1_200, temperature: 0.1),
            capabilities: [.plainText, .structuredJSONObject, .reasoningLevel, .outputTokenLimit, .temperature],
            eligibleCommandIDs: routineCommandIDs
        ),
        .init(
            id: openRouterGPTOSSProfileID,
            connectionID: openRouterConnectionID,
            modelSelector: "openai/gpt-oss-120b",
            options: .init(reasoning: .low, maximumOutputTokens: 2_400, temperature: 0.1),
            capabilities: [.plainText, .structuredJSONObject, .reasoningLevel, .outputTokenLimit, .temperature],
            eligibleCommandIDs: allModelCommandIDs
        ),
        .init(
            id: chatGPTCapableProfileID,
            connectionID: chatGPTConnectionID,
            modelSelector: "gpt-5.6-sol",
            options: .init(reasoning: .medium),
            capabilities: [.plainText, .structuredJSONObject, .reasoningLevel],
            eligibleCommandIDs: allModelCommandIDs,
            revision: 2
        ),
        .init(
            id: claudeCapableProfileID,
            connectionID: claudeConnectionID,
            modelSelector: "sonnet",
            options: .init(reasoning: .medium),
            capabilities: [.plainText, .structuredJSONObject, .reasoningLevel],
            eligibleCommandIDs: allModelCommandIDs
        ),
        .init(
            id: openAIAPICapableProfileID,
            connectionID: openAIAPIConnectionID,
            modelSelector: "gpt-5.4",
            options: .init(reasoning: .medium, maximumOutputTokens: 2_400),
            capabilities: [.plainText, .structuredJSONObject, .reasoningLevel, .outputTokenLimit],
            eligibleCommandIDs: allModelCommandIDs
        ),
        .init(
            id: anthropicAPICapableProfileID,
            connectionID: anthropicAPIConnectionID,
            modelSelector: "claude-sonnet-4-5",
            // Extended thinking budgets must fit inside this limit.
            options: .init(reasoning: .medium, maximumOutputTokens: 4_096),
            capabilities: [.plainText, .structuredJSONObject, .reasoningLevel, .outputTokenLimit],
            eligibleCommandIDs: allModelCommandIDs
        ),
        .init(
            id: localFastProfileID,
            connectionID: localConnectionID,
            modelSelector: "qwen3:8b",
            options: .init(maximumOutputTokens: 2_048),
            capabilities: [.plainText, .structuredJSONObject, .outputTokenLimit],
            eligibleCommandIDs: allModelCommandIDs
        ),
    ]

    public static func connection(_ id: String) -> ModelConnectionProfile? { connections.first { $0.id == id } }
    public static func profile(_ id: String) -> ModelProfile? { profiles.first { $0.id == canonicalProfileID(id) } }
}
