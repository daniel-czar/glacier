import AppKit
import Foundation
import GlacierBuiltins
import GlacierConfiguration
import GlacierConnections
import GlacierModuleKit
import GlacierSearch
import GlacierWorkspace
import HyperOverlayRuntime
import OmniAdapters
import OmniApplication
import OmniCore
import OmniModels
import OmniRun

public enum GlacierRuntimeError: Error, LocalizedError {
    case unavailable(String)
    public var errorDescription: String? { switch self { case .unavailable(let message): message } }
}

public final class RuntimeSnapshot: @unchecked Sendable {
    public let registry: GlacierModuleKit.ModuleRegistry
    private let lock = NSLock()
    private var settings: GlacierSettings
    private var profiles: [String: String] = [:]
    private var authorityEpoch: UInt64 = 0
    private var modelsUpdating = false
    private var modelEpochs: [String: UInt64] = [:]
    private var shortcutLabels: [String: String] = [:]
    private var unavailable: [String: String] = RuntimeSnapshot.unavailableModules
    public init(_ settings: GlacierSettings, registry: GlacierModuleKit.ModuleRegistry = .builtIn) { self.settings = settings; self.registry = registry }
    public func read() -> GlacierSettings { lock.withLock { settings } }
    public func setProfiles(_ routes: [ModelCommandRouteSettings]) { lock.withLock { profiles = Dictionary(uniqueKeysWithValues: routes.compactMap { row in row.savedProfileID.map { (row.commandID, $0) } }) } }
    public func setShortcutLabels(_ labels: [String: String]) { lock.withLock { shortcutLabels = labels } }
    public func shortcutLabel(_ action: String) -> String? { lock.withLock { shortcutLabels[action] } }
    public func setUnavailable(_ values: [String: String]) { lock.withLock { unavailable = Self.unavailableModules.merging(values) { _, new in new } } }
    public func unavailableActions() -> [String: String] { lock.withLock { unavailable } }
    public func profile(_ command: String) -> String? { lock.withLock { profiles[command] } }
    public func translationOptions() -> TranslationOptions {
        let value = read().translation
        return TranslationOptions(sourceLanguageCode: value.sourceLanguage == "auto" ? nil : value.sourceLanguage, targetLanguageCode: value.targetLanguage)
    }
    public struct ModelLease: Equatable, Sendable { let authority: UInt64; let command: UInt64 }
    public func modelLease(_ task: String) -> ModelLease { lock.withLock { .init(authority: authorityEpoch, command: modelEpochs[task, default: 0]) } }
    public func beginModelConfigurationChange() { lock.withLock { modelsUpdating = true; authorityEpoch &+= 1 } }
    public func endModelConfigurationChange() { lock.withLock { modelsUpdating = false } }
    public func modelConfigurationIsUpdating() -> Bool { lock.withLock { modelsUpdating } }
    public func invalidateModels() { lock.withLock { authorityEpoch &+= 1 } }
    public func replace(_ value: GlacierSettings) {
        lock.withLock {
            if settings.ai != value.ai { authorityEpoch &+= 1 }
            if settings.translation != value.translation { modelEpochs["translate", default: 0] &+= 1 }
            let tasks = Set(registry.descriptors.compactMap { descriptor -> String? in
                guard (settings.modules[descriptor.moduleID]?.enabled ?? true) != (value.modules[descriptor.moduleID]?.enabled ?? true) else { return nil }
                return descriptor.modelCommandID
            })
            for task in tasks { modelEpochs[task, default: 0] &+= 1 }
            if (settings.modules["launcher"]?.enabled ?? true) != (value.modules["launcher"]?.enabled ?? true) { modelEpochs["tier2.proposal", default: 0] &+= 1 }
            settings = value
        }
    }
    public static let unavailableModules = ["tasks": "Configure an optional task-owner adapter", "reminders": "Configure an optional reminder-owner adapter"]
    public func automaticRequests(_ action: String) -> Bool {
        let current = read()
        guard !current.ai.paused, let module = registry.descriptor(for: action)?.moduleID else { return false }
        return current.modules[module]?.automaticRequests ?? false
    }
    public func permits(_ action: String, settingsOverride: GlacierSettings? = nil) -> Bool {
        var effective = settingsOverride ?? read()
        let canonical: String
        if action.hasPrefix("command.") {
            guard let token = action.dropFirst("command.".count).split(separator: ":").first,
                  let id = registry.resolveSlash("/" + token, settings: effective).actionID else { return false }
            canonical = id
        } else { canonical = action }
        if modelConfigurationIsUpdating(), registry.descriptor(for: canonical)?.networkRequirement == .remoteAI { return false }
        if effective.ai.offline, let task = registry.descriptor(for: canonical)?.modelCommandID,
           let chosen = profile(task), ProviderRuntimeCatalog.profiles.first(where: { $0.id == chosen })?.connectionID == ProviderRuntimeCatalog.localConnectionID {
            // This only permits reaching the local adapter; the transport still checks the actual destination.
            effective.ai.offline = false
        }
        return registry.resolveAction(canonical, settings: effective, unavailable: unavailableActions()).status == .available
    }
    public func permitsModel(_ task: String) -> Bool {
        guard !read().ai.paused, !modelConfigurationIsUpdating() else { return false }
        if task == "tier2.proposal" { return permits("launcher.open") }
        let actions = registry.descriptors.filter { $0.modelCommandID == task }
        return actions.contains { permits($0.id) }
    }
    public func checkAI(_ destination: URL) throws {
        let current = read()
        guard !modelConfigurationIsUpdating() else { throw GlacierRuntimeError.unavailable("Provider settings are changing") }
        guard !current.ai.paused else { throw GlacierRuntimeError.unavailable("AI is paused") }
        if current.ai.offline && !["localhost", "127.0.0.1", "::1", "[::1]"].contains(destination.host ?? "") {
            throw GlacierRuntimeError.unavailable("Remote requests are disabled offline")
        }
    }
}

@MainActor
public final class GlacierHostActions {
    public var showSettings: (() -> Void)?
    public init() {}
    public func openSettings() throws {
        guard let showSettings else { throw GlacierRuntimeError.unavailable("Settings is not available in headless mode") }
        showSettings()
    }
}

/// The only production composition. It never creates a fixture, replica or installed personal owner.
public struct GlacierComposition: Sendable {
    public let tools: GlacierToolCatalog
    public let paths: GlacierPaths
    public let settings: GlacierSettingsStore
    public let snapshot: RuntimeSnapshot
    public let connections: ConnectionStore
    public let broker: ProviderRuntimeBrokerStore
    public let store: OmniRunStore
    public let service: OmniApplicationService
    public let search: GlacierSearchService
    public let launcher: LauncherService
    public let workspace: GlacierWorkspaceEnvironment
    public let stash: OmniStashStack

    public static let applicationRoots = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
        URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
    ]
    public static func defaultApplicationRoots(home: URL) -> [URL] {
        applicationRoots + [home.appendingPathComponent("Applications")]
    }
    public static func appSources(_ roots: [URL]) -> [GlacierSourceRoot] {
        roots.enumerated().map { index, url in .init(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 10))!, path: url.path, applicationDiscoveryOnly: true) }
    }
    public static func sources(settings: GlacierSettings, home: URL, applicationRoots: [URL]? = nil) -> [GlacierSourceRoot] {
        var selected = settings.roots.sources
        let explicit = Set(selected.map { URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path })
        selected += appSources(applicationRoots ?? defaultApplicationRoots(home: home)).filter { !explicit.contains($0.path) }
        if settings.roots.includeHome && !explicit.contains(home.path) {
            selected.append(.init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, path: home.path))
        }
        return selected
    }
    public static func make(paths: GlacierPaths, home: URL, hostActions: GlacierHostActions,
                            applicationRoots: [URL]? = nil,
                            additionalModules: [AnyGlacierToolModule] = [],
                            network: any ConnectionNetworkTransport = NoRedirectURLSessionTransport(),
                            secrets: any SecretStore = GlacierKeychainSecretStore(),
                            platform: any RecordingPlatformActionPerforming = LivePlatformAdapter(),
                            fileEffect: @escaping @Sendable (URL, LauncherOpenAction) async throws -> Void = { url, action in
                                try await MainActor.run {
                                    if action == .reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                    else if !NSWorkspace.shared.open(url) { throw GlacierRuntimeError.unavailable("The selected item could not be opened") }
                                }
                            }) async throws -> Self {
        try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let settings = try GlacierSettingsStore(paths: paths)
        let tools = try GlacierToolCatalog(modules: additionalModules)
        let actionRegistry = try GlacierModuleKit.ModuleRegistry(descriptors: GlacierModuleKit.ModuleRegistry.builtIn.descriptors + tools.modules.map(\.descriptor))
        let snapshot = RuntimeSnapshot(await settings.snapshot(), registry: actionRegistry)
        let connections = try ConnectionStore(fileURL: paths.support.appendingPathComponent("connections.json"), secrets: secrets)
        let broker = try await connections.makeRuntimeBrokerStore(network: network, gate: { try snapshot.checkAI($0) })
        let guardedModel = GlacierModelAuthority(broker: broker, state: snapshot)
        let corpus = FrozenContractCorpus()
        let manifest = try corpus.manifest()
        let declarations = try corpus.moduleDeclarations()
        let parser = OmniParser(manifest: manifest, references: try ReferenceRegistry([]))
        let runs = paths.support.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        let store = try OmniRunStore(developmentRoot: runs, allowedRoot: paths.support, moduleVersion: "glacier-0.1", manifestVersion: declarations.fixtureVersion)
        let protected = [paths.support, paths.cache, paths.logs,
            home.appendingPathComponent("Library/Application Support/DanielTooling"),
            home.appendingPathComponent("Library/Application Support/OmniIntent"),
            home.appendingPathComponent("Library/Application Support/OmniIntentStandalone")]
        let sources = Self.sources(settings: snapshot.read(), home: home, applicationRoots: applicationRoots)
        let search = try GlacierSearchService(directory: paths.support.appendingPathComponent("search"), policy: SourcePolicy(roots: sources, protectedRoots: protected))
        let opener = GlacierSearchOpener(search: search, effect: fileEffect)
        let log = FileLaunchLog(directory: paths.support.appendingPathComponent("search"))
        let launcher = LauncherService(builder: search, snapshots: search, log: log, opener: opener, home: home.path)
        launcher.loadPersisted()
        let stash = OmniStashStack(url: paths.support.appendingPathComponent("stash.json"))
        let handles = ownerHandles(store: store, paths: paths, state: snapshot, stash: stash, platform: platform, actions: hostActions)
        let capabilities = try CapabilityEnvironment(profile: .standalone, installedPolicy: Set(handles.map(\.operation)), handles: handles)
        let base = try ProductionModuleCatalog(manifest: manifest, declarations: declarations.declarations, environment: capabilities)
        let language = try ProductionLanguageModuleCatalog(manifest: manifest, declarations: declarations.declarations,
            broker: guardedModel, promptBuilder: LanguagePromptBuilder(emailGuide: .init(identifier: "glacier-email", version: "1", status: "default", text: "Write clear, concise emails. Preserve supplied facts, intent and degree of commitment. Never invent personal details."), sharedGuide: .init(identifier: "glacier-writing", version: "1", status: "default", text: "Use clear English. Preserve supplied facts, uncertainty and voice. Do not invent identity, relationships or circumstances."), translationOptionsProvider: { snapshot.translationOptions() }))
        var factories = Dictionary(uniqueKeysWithValues: language.factories.map { ($0.moduleID, $0) })
        let span = try SpanModuleCatalog(manifest: manifest, declarations: declarations.declarations)
        factories[span.factory.moduleID] = span.factory
        let find = try FindModuleCatalog(manifest: manifest, declarations: declarations.declarations, index: search, broker: nil)
        factories[find.factory.moduleID] = find.factory
        let registry = try OmniCore.ModuleRegistry(manifest.moduleIDs.sorted().compactMap { id in
            guard let factory = factories[id] ?? base.registry.factory(for: id), let token = declarations.declarations.first(where: { $0.moduleID == id })?.tokens.canonical else { return nil }
            return AnyCommandModuleFactory(moduleID: id) {
                GuardedModule(base: factory.build(), state: snapshot, action: token == "/settings" ? "settings.open" : token == "/model" ? "settings.model" : "command." + token.dropFirst())
            }
        })
        try ManifestParityValidator().validate(manifest: manifest, declarations: declarations.declarations, registry: registry)
        let service = OmniApplicationService(parser: parser, registry: registry, proposalSource: ProductionTier2UnavailableSource(), store: store,
            capabilityEnvironment: capabilities, proposalGenerator: GlacierProposalGenerator(broker: guardedModel, manifest: manifest, state: snapshot), followUpGenerator: ModelBrokerFollowUpGenerator(broker: guardedModel), executionTimeout: .seconds(180))
        _ = try await service.reconcileAfterRestart()
        let workspaceSettings = WorkspaceSettings(connections: connections, broker: broker, store: store)
        let workspace = GlacierWorkspaceEnvironment(configuration: .init(root: paths.support, allowedRoot: paths.support,
            recallSheet: paths.support.appendingPathComponent("recall.json"), regexSheet: paths.support.appendingPathComponent("regex.json"), pronunciationConfig: paths.support.appendingPathComponent("pronunciation.json")),
            store: store, service: service, modelGenerating: guardedModel, providerRuntime: broker, platform: platform, settings: workspaceSettings, stashStack: stash, findIndex: search, translationOptions: { snapshot.translationOptions() }, profileID: { snapshot.profile($0) }, automaticRequestsEnabled: { snapshot.automaticRequests($0) }, shortcutLabel: { snapshot.shortcutLabel($0) }, remoteServicesEnabled: { !snapshot.read().ai.offline })
        let composition = Self(tools: tools, paths: paths, settings: settings, snapshot: snapshot, connections: connections, broker: broker, store: store, service: service,
                    search: search, launcher: launcher, workspace: workspace, stash: stash)
        await composition.refreshReadiness()
        return composition
    }

    /// Configuration readiness only: never resolves a key or probes a provider in the background.
    public func refreshReadiness() async {
        let connections = await connections.snapshot().profiles
        let ready = Set(connections.filter { $0.enabled && $0.isReadyForCredential }.map(\.id))
        var missing: [String: String] = [:]
        for action in snapshot.registry.descriptors where action.networkRequirement == .remoteAI {
            guard let task = action.modelCommandID else {
                if ready.isEmpty { missing[action.id] = "Configure a connection in Settings" }
                continue
            }
            let selected = snapshot.profile(task)
            if action.kind == .durableCommand && selected == nil {
                missing[action.id] = "Choose a model in Connections"
                continue
            }
            let profileID = selected ?? ModelProviderPolicy.v6.commands.first(where: { $0.commandID == task })?.primaryProfileIDs.first
            guard let profileID, let profile = ProviderRuntimeCatalog.profiles.first(where: { $0.id == profileID }), ready.contains(profile.connectionID) else {
                missing[action.id] = "Configure the selected provider in Connections"
                continue
            }
        }
        snapshot.setUnavailable(missing)
    }

    /// Shared by Settings and integration tests. Terminal parents can still own pending follow-ups.
    public func applyRuntimePolicy(_ current: GlacierSettings) async {
        let old = snapshot.read()
        snapshot.replace(current)
        let changedModelModules = snapshot.registry.descriptors.contains { descriptor in
            descriptor.modelCommandID != nil && (old.modules[descriptor.moduleID]?.enabled ?? true) != (current.modules[descriptor.moduleID]?.enabled ?? true)
        }
        let launcherChanged = (old.modules["launcher"]?.enabled ?? true) != (current.modules["launcher"]?.enabled ?? true)
        if old.ai != current.ai || changedModelModules || old.translation != current.translation || launcherChanged {
            await broker.invalidateActiveRequests()
        }
        if old.modules != current.modules || old.ai != current.ai {
            let runs = await store.recentRuns(limit: Int.max)
            for run in runs {
                guard let task = run.moduleID else {
                    if (run.status == .proposing || run.status == .proposalReady), !snapshot.permitsModel("tier2.proposal") {
                        try? await service.cancel(runID: run.id)
                    }
                    continue
                }
                let action = service.parser.manifest.commands.first(where: { $0.moduleID == task && $0.role == .primary }).map { "command." + $0.token.dropFirst() }
                let disabled = action.map { !snapshot.permits($0) } ?? (task == "tier2.proposal" && !snapshot.permitsModel(task))
                guard disabled else { continue }
                try? await service.cancelFollowUp(runID: run.id)
                if !run.status.isTerminal { try? await service.cancel(runID: run.id) }
            }
        }
    }

    private static func ownerHandles(store: OmniRunStore, paths: GlacierPaths, state: RuntimeSnapshot, stash: OmniStashStack,
                                     platform: any RecordingPlatformActionPerforming, actions: GlacierHostActions) -> [OwnerOperationHandle] {
        let operations: [(OwnerOperation, String)] = [(.openSearchURL, "command.g"), (.captureBaseNote, "command.capture"), (.captureLink, "command.fav"),
            (.replaceCurrentStash, "command.stash"), (.openOmniSettings, "settings.open"), (.openModelSettings, "settings.model")]
        return operations.map { operation, action in
            OwnerOperationHandle(operation: operation, profile: .standalone,
                target: .init(ownerID: "glacier-local", operation: operation, redactedTarget: operation.rawValue, targetDigest: operation.rawValue),
                invoke: { request in
                    guard state.permits(action), let runID = RunID(rawValue: request.runID) else { return .failed(summary: "This module is disabled") }
                    let effect = request.runID + ":" + operation.rawValue
                    do {
                        try Task.checkCancellation()
                        try await store.recordEffectAttempt(runID, effectID: effect, adapterID: "glacier-local", operationID: operation.rawValue)
                        let message: String
                        switch operation {
                        case .openSearchURL:
                            guard !request.offline && !state.read().ai.offline else { throw GlacierRuntimeError.unavailable("Web search is unavailable offline") }
                            var parts = URLComponents(string: "https://www.google.com/search")!; parts.queryItems = [.init(name: "q", value: request.payload)]
                            _ = try await platform.perform(.openURL(parts.url!)); message = "Opened web search"
                        case .openOmniSettings, .openModelSettings:
                            try await actions.openSettings(); message = "Opened Settings"
                        case .replaceCurrentStash:
                            _ = try stash.push(.init(text: request.payload, source: request.source ?? "Glacier", runID: request.runID)); message = "Saved to stash"
                        case .captureBaseNote, .captureLink:
                            let chosen = operation == .captureLink ? state.read().roots.linkDirectory : state.read().roots.captureDirectory
                            let folder = try GlacierPaths.validateUserDirectory(chosen.map { URL(fileURLWithPath: $0) } ?? paths.support.appendingPathComponent(operation == .captureLink ? "links" : "captures"))
                            // Explicit destinations cannot alias the protected Omni installation or either source checkout.

                            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            let destination = folder.appendingPathComponent(request.runID + ".md")
                            let body = "---\nid: \(request.runID)\nkind: \(operation == .captureLink ? "link" : "note")\ncreated: \(ISO8601DateFormatter().string(from: Date()))\n---\n\n\(request.payload)\n"
                            if FileManager.default.fileExists(atPath: destination.path) {
                                guard try String(contentsOf: destination, encoding: .utf8) == body else { throw GlacierRuntimeError.unavailable("Capture already exists") }
                            } else { try Data(body.utf8).write(to: destination, options: .withoutOverwriting) }
                            message = "Saved \(destination.lastPathComponent)"
                        default: throw GlacierRuntimeError.unavailable("No portable adapter is configured")
                        }
                        try await store.recordEffectOutcome(runID, effectID: effect, outcome: .succeeded, certainty: .certain, ownerAcknowledgement: "glacier-local")
                        let keepsText = operation == .captureBaseNote || operation == .captureLink || operation == .replaceCurrentStash
                        return .succeeded(.init(summary: message, allowedActions: keepsText ? [.copy, .dismiss] : [.dismiss], fullText: keepsText ? request.payload : nil))
                    } catch {
                        try? await store.recordEffectOutcome(runID, effectID: effect, outcome: .failed, certainty: .certain)
                        return .failed(summary: (error as? LocalizedError)?.errorDescription ?? "The local action could not be completed")
                    }
                })
        }
    }
}

private struct GuardedModule: CommandModule {
    let base: any CommandModule
    let state: RuntimeSnapshot
    let action: String
    var descriptor: OmniCore.ModuleDescriptor { base.descriptor }
    func validate(input: ModuleInput) throws {
        guard state.permits(action) else { throw GlacierRuntimeError.unavailable("This module is disabled or unavailable") }
        try base.validate(input: input)
    }
    func makePlan(input: ModuleInput) throws -> CommandPlan { try validate(input: input); return try base.makePlan(input: input) }
    func start(plan: CommandPlan, capabilities: CapabilityBroker, runID: String) async throws -> any RunExecutionHandle {
        guard state.permits(action) else { throw GlacierRuntimeError.unavailable("This module is disabled or unavailable") }
        return try await base.start(plan: plan, capabilities: capabilities, runID: runID)
    }
    func reconcile(runID: String, plan: CommandPlan) async -> ReconciliationDisposition { await base.reconcile(runID: runID, plan: plan) }
}

private actor WorkspaceSettings: GlacierWorkspaceSettingsSaving {
    let connections: ConnectionStore
    let broker: ProviderRuntimeBrokerStore
    let store: OmniRunStore
    init(connections: ConnectionStore, broker: ProviderRuntimeBrokerStore, store: OmniRunStore) { self.connections = connections; self.broker = broker; self.store = store }
    func saveProviderSettings(_ candidate: ProviderRuntimeSettings) async throws -> RunID {
        try await broker.validateSettings(candidate)
        try await broker.applySettings(candidate)
        let id = try await store.submit(commandText: "/model", moduleID: "settings.model", executionProfile: "standalone")
        try await store.enqueue(id); try await store.beginExecution(id); try await store.succeed(id, summary: "Applied model settings")
        return id
    }
}
