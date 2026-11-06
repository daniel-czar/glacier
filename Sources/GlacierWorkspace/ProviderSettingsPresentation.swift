import Foundation
import OmniCore
import OmniModels
import OmniPresentation

/// Bridges the policy 6.0.0 provider runtime to the native settings and
/// launcher surfaces. Rows carry display labels; every save maps labels back to
/// stable profile IDs through the registry, never through enum raw values.
public struct ProviderSettingsPresenter: Sendable {
    public static let defaultChoice = "Default"
    public static let noneChoice = "None"

    let environment: GlacierWorkspaceEnvironment

    public init(environment: GlacierWorkspaceEnvironment) {
        self.environment = environment
    }

    var runtime: ProviderRuntimeBrokerStore? { environment.providerRuntime }

    // MARK: Labels <-> IDs

    func labelsByProfileID(settings: ProviderRuntimeSettings) -> [String: String] {
        guard let runtime else { return [:] }
        var labels: [String: String] = [:]
        for profile in runtime.registry.effectiveProfiles(settings: settings) { labels[profile.id] = profile.displayName }
        return labels
    }

    func profileID(forLabel label: String?, settings: ProviderRuntimeSettings) -> String? {
        guard let label, label != Self.defaultChoice, label != Self.noneChoice, label != "Unavailable" else { return nil }
        return labelsByProfileID(settings: settings).first { $0.value == label }?.key
    }

    /// A saved assignment is a manual choice (C66), so policy eligibility does
    /// not narrow these choices. API permissions are recorded on explicit save.
    func selectableProfiles(for commandID: String?, settings: ProviderRuntimeSettings) -> [ModelProfile] {
        guard let runtime else { return [] }
        return runtime.registry.effectiveProfiles(settings: settings).filter { profile in
            guard let connection = runtime.registry.effectiveConnection(profile.connectionID, settings: settings), connection.enabled else { return false }
            return true
        }
    }

    // MARK: Launcher surface

    public func modelChoices(commandText: String = "", didUpdate: (@Sendable ([OmniModelChoice]) async -> Void)? = nil) async -> [OmniModelChoice] {
        guard let runtime else { return [] }
        let settings = await runtime.settingsSnapshot()
        let intent = environment.service.parser.parse(commandText)
        let commandID = modelCommandID(for: intent) ?? "answer.quick"
        let profiles = runtime.registry.effectiveProfiles(settings: settings)
        var choices: [OmniModelChoice] = []
        for profile in profiles {
            let selection = await selection(forProfileID: profile.id)
            let resolution = try? await runtime.resolve(commandID: commandID, offline: intent.modes.contains("/offline"), dispatch: .init(generationID: "preview", selection: selection))
            var reason = resolution?.candidates.first?.unavailabilityReason ?? (resolution == nil ? "Model settings need attention" : nil)
            if reason == nil, !runtime.registry.isFixture, let connection = runtime.registry.effectiveConnection(profile.connectionID, settings: settings), connection.authRoute.isSubscription || connection.authRoute == .localService {
                reason = "Checking connection…"
            }
            choices.append(OmniModelChoice(id: profile.id, label: profile.displayName, unavailabilityReason: reason))
        }
        // Present the chevron before any auth process can stall. Individual
        // results replace checking entries as they arrive.
        await didUpdate?(choices)
        await withTaskGroup(of: (Int, OmniModelChoice).self) { group in
            for (index, profile) in profiles.enumerated() {
                group.addTask {
                    let selection = await selection(forProfileID: profile.id)
                    let resolution = try? await runtime.resolveReadiness(commandID: commandID, offline: intent.modes.contains("/offline"), dispatch: .init(generationID: "preview", selection: selection))
                    let reason = resolution?.candidates.first?.unavailabilityReason ?? (resolution == nil ? "Model settings need attention" : nil)
                    return (index, OmniModelChoice(id: profile.id, label: profile.displayName, unavailabilityReason: reason))
                }
            }
            for await (index, choice) in group {
                choices[index] = choice
                await didUpdate?(choices)
            }
        }
        return choices
    }

    /// Tier 2 has the same readiness check as a named model command (C67).
    func modelCommandID(for intent: ParsedIntent) -> String? {
        switch SubmissionClassifier().classify(intent) {
        // An id-shaped text never asks for a proposal (D1), so it has no
        // model route to check or show.
        case .tier2: return OmniIDAddress(intent.rawText) == nil ? "tier2.proposal" : nil
        case .tier1(let token):
            guard let command = environment.service.parser.manifest.command(for: token), runtime?.policy.command(named: command.moduleID) != nil else { return nil }
            guard Self.asksModel(command: command, intent: intent) else { return nil }
            return command.moduleID
        case .disabled, .referenceChoice: return nil
        }
    }

    /// Whether this invocation of a model-backed command reaches a model.
    /// Only `/find` has local tiers: its ids and filters, and its words
    /// under `/offline`, run on this Mac (D2).
    static func asksModel(command: ManifestCommand, intent: ParsedIntent) -> Bool {
        guard command.moduleID == FindModuleCatalog.moduleID else { return true }
        return !intent.modes.contains("/offline") && FindQuery(payload: SlashTokenSyntax.payloadText(from: intent.rawText)).asksModel
    }

    public func selection(forProfileID profileID: String?) async -> ModelInvocationSelection? {
        guard let profileID, let runtime else { return nil }
        let settings = await runtime.settingsSnapshot()
        guard let profile = runtime.registry.effectiveProfile(profileID, settings: settings),
              let connection = runtime.registry.effectiveConnection(profile.connectionID, settings: settings)
        else { return nil }
        // Picking an API-alternative profile for this one invocation is the
        // explicit invocation-scoped route permission.
        return ModelInvocationSelection(profileID: profileID, permitsAPIRoute: connection.authRoute.isOptionalAPIAlternative)
    }

    /// Effective route for the typed command, before submit and without any
    /// model call. Deterministic commands report no model route.
    public func routeSummary(commandText: String, selectedProfileID: String?) async -> String? {
        guard let runtime else { return nil }
        let intent = environment.service.parser.parse(commandText)
        guard let commandID = modelCommandID(for: intent) else { return nil }
        if await runtime.settingsBlockReason() != nil { return "Model settings need attention" }
        let selection = await selection(forProfileID: selectedProfileID)
        let dispatch = ModelDispatchContext(generationID: "preview", selection: selection)
        guard let resolution = try? await runtime.resolveReadiness(commandID: commandID, offline: intent.modes.contains("/offline"), dispatch: dispatch) else { return nil }
        return Self.summary(resolution, fixture: runtime.registry.isFixture)
    }

    /// The pad's route line ingredients (C21, C30): provider in one word, the
    /// override scope, or the attention line when nothing can dispatch.
    public func padRoute(commandText: String, selectedProfileID: String?) async -> OmniPadRoute? {
        guard let runtime else { return nil }
        let intent = environment.service.parser.parse(commandText)
        guard let commandID = modelCommandID(for: intent) else { return nil }
        if await runtime.settingsBlockReason() != nil {
            return OmniPadRoute(providerName: nil, unavailable: "Model settings need attention", offersSettings: true)
        }
        let selection = await selection(forProfileID: selectedProfileID)
        let dispatch = ModelDispatchContext(generationID: "preview", selection: selection)
        guard let resolution = try? await runtime.resolveReadiness(commandID: commandID, offline: intent.modes.contains("/offline"), dispatch: dispatch) else {
            return OmniPadRoute(providerName: nil, unavailable: "No model is available")
        }
        let scope: OmniPadRoute.Scope = switch resolution.selectionSource {
        case .policyDefault: .policyDefault
        case .savedCommandOptIn: .savedOptIn
        case .invocationOverride: .thisRunOnly
        }
        if let first = resolution.dispatchable.first {
            let name = runtime.registry.isFixture ? "Sample replies" : Self.providerName(connectionID: first.connectionID, displayName: first.displayName)
            return OmniPadRoute(providerName: name, scope: scope, displayName: first.displayName)
        }
        if let culprit = resolution.candidates.first {
            return OmniPadRoute(providerName: nil, scope: scope, displayName: culprit.displayName, unavailable: culprit.unavailabilityReason ?? "No model is available", recoveryHint: Self.recoveryHint(culprit), offersSettings: resolution.migrationIssue != nil)
        }
        return OmniPadRoute(providerName: nil, scope: scope, unavailable: "No model is available")
    }

    static func recoveryHint(_ candidate: ModelRouteCandidate) -> String? {
        guard case .excluded(let kind, _) = candidate.verdict else { return nil }
        switch kind {
        case .needsLogin:
            return candidate.connectionID == ProviderRuntimeCatalog.chatGPTConnectionID
                ? "Log in with codex login in Terminal"
                : "Log in with CLAUDE_CONFIG_DIR=~/.claude-omni claude auth login in Terminal"
        case .needsConfiguration:
            switch candidate.driverID {
            case .codexAppServer: return "Install Codex CLI or set its executable path in provider settings"
            case .claudePrint: return "Install Claude CLI or set its executable path in provider settings"
            default: return "Check this connection in Settings → Connections"
            }
        case .disabled: return "Open Settings → Connections to enable this connection"
        default: return nil
        }
    }

    /// One word per connection for the route line.
    static func providerName(connectionID: String, displayName: String) -> String {
        switch connectionID {
        case "cerebras": "Cerebras"
        case "openrouter": "OpenRouter"
        case "chatgpt": "ChatGPT"
        case "claude": "Claude"
        case "openai-api": "OpenAI API"
        case "anthropic-api": "Anthropic API"
        case "local-ollama": "Local"
        default: String(displayName.split(separator: "·").first ?? Substring(displayName)).trimmingCharacters(in: .whitespaces)
        }
    }

    static func summary(_ resolution: ModelRouteResolution, fixture: Bool) -> String {
        let scope: String = switch resolution.selectionSource {
        case .policyDefault: "default"
        case .savedCommandOptIn: "saved opt-in"
        case .invocationOverride: "this command only"
        }
        if let first = resolution.dispatchable.first {
            return "\(first.displayName) · \(scope)\(fixture ? " · sample replies" : "")"
        }
        if resolution.migrationIssue != nil {
            return "Model settings need attention"
        }
        if let excluded = resolution.candidates.first {
            return excluded.unavailabilityReason ?? "No model is available"
        }
        return "No model is available"
    }

    // MARK: Settings rows

    public func assignmentRows() async -> [OmniModelAssignmentRow] {
        guard let runtime else { return [] }
        let settings = await runtime.settingsSnapshot()
        let block = await runtime.settingsBlockReason()
        var rows: [OmniModelAssignmentRow] = []
        for command in environment.service.parser.manifest.commands where command.role == .primary || command.role == .settings {
            guard let policy = runtime.policy.command(named: command.moduleID) else {
                rows.append(OmniModelAssignmentRow(commandID: command.token, main: nil, fallback: nil, availability: "Deterministic · no model", supportsModel: false))
                continue
            }
            let saved = settings.command(command.moduleID)
            let labels = labelsByProfileID(settings: settings)
            let eligible = selectableProfiles(for: command.moduleID, settings: settings)
            let resolution = try? await runtime.resolveReadiness(commandID: command.moduleID, offline: false, dispatch: nil)
            var availability = resolution.map { Self.summary($0, fixture: runtime.registry.isFixture) } ?? "unavailable"
            if block != nil { availability = "Model settings need attention" }
            if settings.migrationIssue(for: command.moduleID) != nil {
                availability = "Needs configuration · choose a model for this command"
            }
            let defaultLabel = policy.primaryProfileIDs.first.flatMap { labels[$0] }.map { "\(Self.defaultChoice) (\($0))" } ?? Self.defaultChoice
            let mainLabel = saved?.savedProfileID.flatMap { labels[$0] } ?? defaultLabel
            let fallbackLabel = saved?.savedFallbackProfileIDs.first.flatMap { labels[$0] } ?? Self.noneChoice
            rows.append(OmniModelAssignmentRow(
                commandID: command.token,
                main: mainLabel,
                fallback: fallbackLabel,
                availability: availability,
                supportsModel: true,
                allowedMainChoices: [defaultLabel] + eligible.map(\.displayName),
                // A saved fallback onto an API alternative would need its own
                // route permission, which this surface records only for the main
                // choice; keep API profiles out of the fallback list.
                allowedFallbackChoices: [Self.noneChoice] + eligible.filter { profile in
                    runtime.registry.baseConnection(profile.connectionID)?.authRoute.isOptionalAPIAlternative == false
                }.map(\.displayName)
            ))
        }
        // Connection readiness rows are informational; enable/disable and
        // credential references are edited through the settings document.
        for connection in await runtime.readiness(probe: false) {
            let profiles = connection.profiles.map { "\($0.displayName): \($0.modelSelector)" }.joined(separator: ", ")
            rows.append(OmniModelAssignmentRow(
                commandID: Self.providerName(connectionID: connection.connectionID, displayName: connection.displayName),
                main: nil,
                fallback: nil,
                availability: "\(connection.unavailabilityReason ?? connection.summary)\(profiles.isEmpty ? "" : " · \(profiles)")",
                supportsModel: false
            ))
        }
        return rows
    }

    /// Builds the next settings revision from edited rows. Selecting the default
    /// label clears the opt-in; selecting an API-alternative profile records the
    /// per-command route permission; resolving an issue command clears its issue.
    public func settings(fromRows rows: [OmniModelAssignmentRow]) async throws -> ProviderRuntimeSettings {
        guard let runtime else { throw GlacierWorkspaceError.providerRuntimeUnavailable }
        let current = await runtime.settingsSnapshot()
        let nextRevision = current.revision + 1
        var commands = current.commands
        var issues = current.migrationIssues
        for row in rows where row.supportsModel {
            guard let moduleID = environment.service.parser.manifest.command(for: row.commandID)?.moduleID,
                  runtime.policy.command(named: moduleID) != nil
            else { continue }
            let mainLabel = row.main.map { $0.hasPrefix(Self.defaultChoice) ? Self.defaultChoice : $0 }
            let main = profileID(forLabel: mainLabel, settings: current)
            let fallback = main == nil ? nil : profileID(forLabel: row.fallback, settings: current)
            var permission: ModelAPITransitionPermission?
            if let main, let profile = runtime.registry.baseProfile(main), let connection = runtime.registry.baseConnection(profile.connectionID), connection.authRoute.isOptionalAPIAlternative {
                permission = .init(connectionID: connection.id, scope: .saved(settingsRevision: nextRevision))
            }
            let existing = current.command(moduleID)
            let route = ModelCommandRouteSettings(
                commandID: moduleID,
                offlineDefault: existing?.offlineDefault ?? false,
                savedProfileID: main,
                savedFallbackProfileIDs: fallback.map { [$0] } ?? [],
                savedAPITransition: permission
            )
            // A migration issue is resolved only by an explicit profile choice
            // for that command; leaving the row at "Default" preserves the issue.
            if main != nil || fallback != nil {
                issues.removeAll { $0.commandID == moduleID }
            } else if issues.contains(where: { $0.commandID == moduleID }) {
                continue
            }
            commands.removeAll { $0.commandID == moduleID }
            commands.append(route)
        }
        return ProviderRuntimeSettings(
            policyVersion: current.policyVersion,
            configurationID: current.configurationID,
            revision: nextRevision,
            connections: current.connections,
            profiles: current.profiles,
            commands: commands,
            migrationIssues: issues,
            migratedFrom: current.migratedFrom
        )
    }

    // MARK: Release inspection

    /// The native release inspection reads model rows as a person would: each
    /// names its effective route (a profile label, then its scope) or says
    /// plainly why nothing can run, in this presenter's own wording. Labels and
    /// provider names come from the registry, so relabelled profiles stay legible.
    func rowsShowRouteOrUnavailability(_ rows: [OmniModelAssignmentRow]) async -> Bool {
        guard let runtime else { return false }
        let settings = await runtime.settingsSnapshot()
        let labels = labelsByProfileID(settings: settings).values
        let providers = runtime.registry.effectiveConnections(settings: settings).map {
            ModelHumanFailure.providerName(displayName: $0.displayName, driverID: $0.driverID)
        }
        let unavailable: Set = ["unavailable", "No model is available", "Model settings need attention", "Selected model: unavailable"]
        let modelRows = rows.filter(\.supportsModel)
        return !modelRows.isEmpty && modelRows.allSatisfy { row in
            let text = row.availability
            return labels.contains { text.hasPrefix("\($0) · ") }
                || unavailable.contains(text)
                || text.hasPrefix("Needs configuration")
                || providers.contains { text.hasPrefix("\($0): ") }
        }
    }

    /// Both paid-API alternatives ship off: each has its own connection row,
    /// and that row leads with the provider's "connection is off".
    static func rowsShowAPIAlternativesOff(_ rows: [OmniModelAssignmentRow]) -> Bool {
        [ProviderRuntimeCatalog.openAIAPIConnectionID, ProviderRuntimeCatalog.anthropicAPIConnectionID].allSatisfy { id in
            guard let connection = ProviderRuntimeCatalog.connection(id) else { return false }
            let rowID = providerName(connectionID: id, displayName: connection.displayName)
            let off = "\(ModelHumanFailure.providerName(displayName: connection.displayName, driverID: connection.driverID)): \(ModelHumanFailure.reason(kind: .disabled, driverID: connection.driverID))"
            return rows.contains { !$0.supportsModel && $0.commandID == rowID && $0.availability.hasPrefix(off) }
        }
    }
}
