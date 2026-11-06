import AppKit
import Foundation
import ClipboardHistory
import GlacierBuiltins
import GlacierConfiguration
import GlacierConnections
import GlacierModuleKit
import GlacierPlatform
import GlacierPronunciation
import GlacierSearch
import GlacierWorkspace
import HyperOverlayRuntime
import HyperOverlayCore
import HyperKeyOverlay
import ServiceManagement
import OmniCore
import OmniModels
import OmniPresentation

/// A self-contained menu-bar lifecycle; never starts or contacts the original host.
@MainActor
public final class GlacierDesktop: NSObject, NSApplicationDelegate {
    private let supportOverride: URL?
    private let additionalModules: [AnyGlacierToolModule]
    public let preview: Bool
    public private(set) var composition: GlacierComposition?
    public private(set) var native: OmniNativeWorkspaceController?
    private var settingsWindow: GlacierSettingsController?
    var onboardingWindow: GlacierOnboardingWindowController?
    var onboardingIsActive: Bool { lifecycle.isActive }
    public private(set) var pronunciationSettings: PronunciationSettingsStore?
    private var clipboard: ClipboardHistoryController?
    private var shortcuts: ShortcutController?
    private var help: HyperKeyOverlayController?
    private var launchPalette: LaunchPaletteController?
    private var launchManifestURL: URL?
    private var keyEffects: PortableKeyActionEffects?
    private var keyActions: KeyActionController?
    private var collect: CollectController?
    private var foregroundDispatcher: GlacierForegroundDispatcher?
    private var focusObserver: NSObjectProtocol?
    private let lifecycle = GlacierDesktopLifecycle()
    private var startup: Task<Void, Never>?
    public var registeredShortcutCount: Int { shortcuts?.registeredActionIDs.count ?? 0 }
    private var changes: Task<Bool, Never>?
    private var modelRoutes: [ModelCommandRouteSettings] = []
    private var routesURL: URL?
    public var report: (String) -> Void = { _ in }

    public init(supportOverride: URL? = nil, preview: Bool = false, additionalModules: [AnyGlacierToolModule] = []) {
        self.additionalModules = additionalModules
        self.supportOverride = supportOverride; self.preview = preview
        super.init()
    }
    public func applicationDidFinishLaunching(_ notification: Notification) {
        startup = Task {
            do { try await start() }
            catch {
                guard lifecycle.isActive else { return }
                let alert = NSAlert(); alert.messageText = "Glacier could not start"
                alert.informativeText = "No changes were made to Omni. " + error.localizedDescription
                alert.runModal(); NSApplication.shared.terminate(nil)
            }
        }
    }
    public func start() async throws {
        guard lifecycle.isActive else { return }
        let home = OmniLayout.homeDirectory
        let paths = try GlacierPaths(home: home, supportOverride: supportOverride)
        let actions = GlacierHostActions()
        let composition = try await GlacierComposition.make(paths: paths, home: home, hostActions: actions, additionalModules: additionalModules)
        guard lifecycle.isActive else { _ = await composition.service.shutdown(); return }
        self.composition = composition
        launchManifestURL = paths.support.appendingPathComponent("manifest.json")
        launchPalette = LaunchPaletteController()
        launchPalette?.onError = { [weak self] in self?.report($0); self?.settingsWindow?.showError($0) }
        let routesURL = paths.support.appendingPathComponent("model-routes.json")
        self.routesURL = routesURL
        if FileManager.default.fileExists(atPath: routesURL.path) {
            modelRoutes = try JSONDecoder().decode([ModelCommandRouteSettings].self, from: Data(contentsOf: routesURL))
            try await refreshConnections()
            guard lifecycle.isActive else { return }
        }
        await composition.refreshReadiness()
        guard lifecycle.isActive else { return }
        let pronunciationSettings = try PronunciationSettingsStore(directory: paths.support.appendingPathComponent("pronunciation"))
        self.pronunciationSettings = pronunciationSettings
        let helperRoot = (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("Pronunciation")
        let pronunciation = GlacierPronunciationClient(paths: .init(bundleRoot: helperRoot, supportDirectory: paths.support.appendingPathComponent("pronunciation")), settings: pronunciationSettings, offline: { composition.snapshot.read().ai.offline })
        let foreground = ForegroundArbitrator(allowedOverlays: ["omni-editing", "omni-attached", "omni-ephemeral", "omni-capture", "hyper-clipboard"])
        let native = OmniNativeWorkspaceController(environment: composition.workspace, foreground: foreground,
            displayName: "Glacier", statusItemTitle: "Glacier", workspaceTitle: "Glacier",
            beforeOmniForeground: { [weak self] in self?.foregroundDispatcher?.nativeWillForeground() },
            onForegroundIntentReserved: { [weak self] in self?.foregroundDispatcher?.nativeIntentReserved() },
            launcher: composition.launcher, ephemeralProducers: [.pronunciation: pronunciation.producer])
        self.native = native
        native.hostSurfaceOrigin = { [weak self] in
            guard let self else { return (active: false, processID: nil) }
            if self.clipboard?.isKeyWindow == true {
                return (active: true, processID: self.clipboard?.capturedExternalOriginPID)
            }
            if self.onboardingWindow?.window?.isKeyWindow == true {
                return (active: true, processID: nil)
            }
            return (active: false, processID: nil)
        }
        foregroundDispatcher = GlacierForegroundDispatcher(
            invalidateNative: { [weak native] in native?.invalidatePendingForegroundIntent() },
            prepareNative: { [weak self] in self?.prepareForNativeForeground() },
            canOpenNative: { [weak self] action in
                self?.lifecycle.isActive == true && composition.snapshot.permits(action.actionID)
            },
            openNative: { [weak native] action in
                guard let native else { return }
                await action.perform(on: native)
            })
        native.canInvoke = { [weak self] action in self?.lifecycle.isActive == true && composition.snapshot.permits(action) }
        native.canUseIndexedPath = { composition.search.permits($0) }
        native.contributedQuickLaunchTools = composition.tools.quickLaunchDescriptors
        native.contributedSlashRoutes = composition.tools.modules.flatMap { module in module.descriptor.slashTokens.map { OmniContributedSlashRoute(token: $0, toolID: module.presentation.id, title: module.presentation.title, detail: module.presentation.subtitle) } }
        native.onContributedQuickLaunch = { [weak native] toolID in
            guard let module = composition.tools.modules.first(where: { $0.presentation.id == toolID }), composition.snapshot.permits(module.descriptor.id) else { return false }
            return native?.beginContributedTool(descriptor: module.presentation, producer: module.makeProducer()) ?? false
        }
        native.onContributedSlash = { [weak native] raw in
            let match = composition.tools.resolveSlash(raw, settings: composition.snapshot.read(), unavailable: composition.snapshot.unavailableActions())
            guard match.resolution.actionID != nil else { return nil }
            guard let module = match.module else { return false }
            return native?.beginContributedTool(descriptor: module.presentation, producer: module.makeProducer(), input: match.payload) ?? false
        }

        native.onShowSettings = { [weak self] (_: Bool) in self?.showSettings() }
        actions.showSettings = { [weak self] in self?.showSettings() }
        settingsWindow = GlacierSettingsController(owner: self)
        let clipboardStore = try ClipboardHistoryStore(directory: paths.support.appendingPathComponent("clipboard"))
        let clipboard = ClipboardHistoryController(store: clipboardStore, foreground: foreground)
        self.clipboard = clipboard
        clipboard.onCaptureIntent = { [weak self] enabled in
            guard let self, !self.preview, composition.snapshot.permits("clipboard.history") else {
                throw GlacierRuntimeError.unavailable("Clipboard capture is unavailable in this profile")
            }
            let pending = self.change { $0.clipboard.captureEnabled = enabled }
            let applied = await pending.value
            guard applied, composition.snapshot.read().clipboard.captureEnabled == enabled else {
                throw GlacierRuntimeError.unavailable("The clipboard preference could not be saved")
            }
        }
        configureClipboardStash()
        native.onClipboardRequested = { [weak self] query, pid in
            self?.showClipboard(query: query, originPID: pid, authoritativeOrigin: true)
        }
        native.onCloseHostWindow = { [weak self] window in
            if self?.onboardingWindow?.window === window {
                self?.onboardingWindow?.close()
                return true
            }
            return Self.closeHostSettings(window, settingsWindow: self?.settingsWindow?.window)
        }
        if composition.snapshot.permits("clipboard.history") {
            try await clipboard.start(effectiveCapture: Self.effectiveClipboardCapture(settings: composition.snapshot.read(), preview: preview))
            guard lifecycle.isActive else { clipboard.stop(); return }
        }
        let effects = CollectSystemEffects(normalization: { GlacierTextNormalizer.normalize($0) },
            onFailure: { [weak self] in self?.report($0.rawValue) }, onNotice: { [weak self] in self?.report($0) })
        collect = CollectController(store: ClipboardBufferStore(url: paths.support.appendingPathComponent("collection.json")), effects: effects)
        let keyEffects = PortableKeyActionEffects(collect: effects, settings: composition.snapshot.read(),
            fileFinder: { text in composition.launcher.query(text).rows.map { URL(fileURLWithPath: $0.candidate.path) }.filter { composition.search.permits($0.path) } },
            onFailure: { [weak self] in self?.report($0) }, onNotice: { [weak self] in self?.report($0) })
        self.keyEffects = keyEffects; keyActions = KeyActionController(effects: keyEffects)
        shortcuts = ShortcutController(settings: composition.snapshot.read(), safePreview: preview, availability: { composition.snapshot.permits($0, settingsOverride: $1) }) { [weak self] id in self?.invoke(id) }
        if !preview && composition.snapshot.read().shortcuts.values.contains(where: \.enabled) {
            do { try shortcuts?.activate(registry: composition.snapshot.registry, unavailable: composition.snapshot.unavailableActions()) }
            catch { report(error.localizedDescription) }
        }
        rebuildHelp()
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyActions?.invalidate(); self?.collect?.invalidate() }
        }
        native.refreshActionAvailability()
        try await native.show()
        guard lifecycle.isActive else { native.stop(); return }
        if composition.snapshot.permits("launcher.open") { try composition.search.startWatching { [weak launcher = composition.launcher] snapshot in launcher?.publish(snapshot) } }
        presentInitialOnboarding(paths: paths)
    }
    public func showSettings() {
        guard lifecycle.isActive else { return }
        launchPalette?.dismiss()
        settingsWindow?.show()
    }
    public func launchAppsForSettings() -> (lines: [String], problems: [String]) {
        guard let launchManifestURL else { return ([], []) }
        do {
            let manifest = try LaunchManifest.load(from: launchManifestURL)
            let inspector = LaunchPaletteController(presentsInterface: false)
            let resolvedProblems = inspector.load(bundleIDs: manifest.bundleIDs, keyOverrides: manifest.keyOverrides)
            let keys = LaunchPaletteLayout.keys(for: inspector.applications)
            return (zip(keys, inspector.applications).map { "\($0.0)  \($0.1.name) · \($0.1.bundleID)" },
                    manifest.problems + resolvedProblems.map(\.message))
        } catch { return ([], [error.localizedDescription]) }
    }
    public func editLaunchManifest() {
        guard let launchManifestURL else { return }
        do {
            if !FileManager.default.fileExists(atPath: launchManifestURL.path) {
                try Data("{\"launch\":[]}\n".utf8).write(to: launchManifestURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: launchManifestURL.path)
            }
            NSWorkspace.shared.open(launchManifestURL)
        } catch { settingsWindow?.showError(error.localizedDescription) }
    }
    @discardableResult
    public func change(activateShortcuts: Bool = false,
                       authorizeCommit: @escaping @Sendable () throws -> Void = {},
                       _ transform: @escaping @Sendable (inout GlacierSettings) throws -> Void) -> Task<Bool, Never> {
        guard lifecycle.isActive else { return Task { false } }
        let previous = changes
        let task = Task { [weak self] () -> Bool in
            guard let self, await self.lifecycle.afterPriorChange(previous), let composition = self.composition else { return false }
            var saved = false
            do {
                let old = composition.snapshot.read()
                var proposed = old
                try transform(&proposed)
                let candidate = proposed
                if let shortcuts {
                    try await shortcuts.apply(candidate, registry: composition.snapshot.registry, unavailable: composition.snapshot.unavailableActions(), activate: activateShortcuts) { next in
                        _ = try await composition.settings.update(authorizeCommit: authorizeCommit) { $0 = next }
                    }
                } else { _ = try await composition.settings.update(authorizeCommit: authorizeCommit) { $0 = candidate } }
                guard lifecycle.isActive else { _ = shortcuts?.stop(); return false }
                saved = true
                let current = candidate
                await composition.applyRuntimePolicy(current)
                guard lifecycle.isActive else { return false }
                keyEffects?.applySettings(current)
                rebuildHelp()
                native?.refreshActionAvailability()
                configureClipboardStash()
                if old.modules != current.modules || old.ai != current.ai {
                    keyActions?.invalidate(); collect?.invalidate()
                    if !composition.snapshot.permits("launcher.open") { composition.search.stopWatching() }
                    else if old.modules["launcher"]?.enabled == false {
                        try composition.search.startWatching { [weak launcher = composition.launcher] snapshot in launcher?.publish(snapshot) }
                        composition.launcher.refreshIfDue(force: true)
                    }
                    if !composition.snapshot.permits("clipboard.history") { clipboard?.dismiss(restoreFocus: false); clipboard?.stop() }
                }
                if old.roots != current.roots {
                    let sources = GlacierComposition.sources(settings: current, home: OmniLayout.homeDirectory)
                    let protected = [composition.paths.support, composition.paths.cache, composition.paths.logs,
                        OmniLayout.homeDirectory.appendingPathComponent("Library/Application Support/DanielTooling"),
                        OmniLayout.homeDirectory.appendingPathComponent("Library/Application Support/OmniIntent")]
                    try composition.search.replacePolicy(SourcePolicy(roots: sources, protectedRoots: protected))
                    composition.launcher.publish(try composition.search.load()!)
                    if composition.snapshot.permits("launcher.open") {
                        try composition.search.startWatching { [weak launcher = composition.launcher] snapshot in launcher?.publish(snapshot) }
                        composition.launcher.refreshIfDue(force: true)
                    }
                    await native?.refreshSourceAccess()
                    guard lifecycle.isActive else { return false }
                }
                let captureEnabled = Self.effectiveClipboardCapture(settings: current, preview: preview)
                do {
                    if composition.snapshot.permits("clipboard.history"), let clipboard, !clipboard.isMonitoring {
                        try await clipboard.start(effectiveCapture: captureEnabled)
                    } else { try await clipboard?.setCaptureEnabled(captureEnabled) }
                    guard lifecycle.isActive else { clipboard?.stop(); return false }
                }
                catch {
                    if !captureEnabled { clipboard?.stop() }
                    throw error
                }
                settingsWindow?.refresh()
                return true
            } catch {
                guard lifecycle.isActive else { return false }
                settingsWindow?.refresh()
                if saved { settingsWindow?.showNotice("Settings saved · " + error.localizedDescription) }
                else { settingsWindow?.showError(error.localizedDescription) }
                return false
            }
        }
        changes = task
        return task
    }
    public func beginConnectionChange() async {
        guard lifecycle.isActive, let composition else { return }
        composition.snapshot.beginModelConfigurationChange()
        native?.invalidateModelSessions()
        await composition.broker.invalidateActiveRequests()
    }
    public func endConnectionChange() async {
        guard lifecycle.isActive, let composition else { return }
        composition.snapshot.endModelConfigurationChange()
        native?.refreshActionAvailability()
        await reconcileShortcutReadiness()
        guard lifecycle.isActive else { return }
        rebuildHelp()
    }
    public func refreshConnections() async throws {
        guard lifecycle.isActive, let composition else { return }
        native?.invalidateModelSessions()
        composition.snapshot.invalidateModels()
        composition.snapshot.setProfiles(modelRoutes)
        let settings = await composition.connections.runtimeSettings(commands: modelRoutes)
        guard lifecycle.isActive else { return }
        try await composition.broker.applySettings(settings)
        guard lifecycle.isActive else { return }
        await composition.refreshReadiness()
        guard lifecycle.isActive else { return }
        await reconcileShortcutReadiness()
        guard lifecycle.isActive else { return }
        native?.refreshActionAvailability()
        rebuildHelp()
        native?.invalidateRoutePreviews()
    }
    public func selectModel(_ id: String, for command: String? = nil,
                            authorizeCommit: @Sendable () throws -> Void = {}) async throws {
        guard lifecycle.isActive, let composition, let routesURL, let profile = ProviderRuntimeCatalog.profiles.first(where: { $0.id == id }) else { return }
        let commands = command.map { [$0] } ?? ModelProviderPolicy.v6.commands.map(\.commandID)
        let revision = await composition.connections.snapshot().revision
        guard lifecycle.isActive else { return }
        let api: ModelAPITransitionPermission? = [.openAIHTTP, .anthropicHTTP].contains(ProviderRuntimeCatalog.connection(profile.connectionID)?.driverID)
            ? .init(connectionID: profile.connectionID, scope: .saved(settingsRevision: revision)) : nil
        var next = modelRoutes.filter { !commands.contains($0.commandID) }
        next += commands.map { .init(commandID: $0, savedProfileID: id, savedAPITransition: api) }
        let settings = await composition.connections.runtimeSettings(commands: next)
        guard lifecycle.isActive else { return }
        try await composition.broker.validateSettings(settings)
        guard lifecycle.isActive else { return }
        try authorizeCommit()
        try JSONEncoder().encode(next).write(to: routesURL, options: .atomic)
        modelRoutes = next
        composition.snapshot.invalidateModels()
        composition.snapshot.setProfiles(next)
        try await composition.broker.applySettings(settings)
        guard lifecycle.isActive else { return }
        await composition.refreshReadiness()
        guard lifecycle.isActive else { return }
        await reconcileShortcutReadiness()
        guard lifecycle.isActive else { return }
        native?.refreshActionAvailability()
        rebuildHelp()
        if command == nil { try native?.preferences.update { $0.ephemeralProfileID = id } }
        native?.invalidateRoutePreviews()
    }
    private func configureClipboardStash() {
        guard let composition else { return }
        if composition.snapshot.permits("tool.stash") {
            clipboard?.onStash = { payload, summary in ClipboardStashBridge.push(payload, summary, into: composition.stash) }
        } else { clipboard?.onStash = nil }
    }
    public static func effectiveClipboardCapture(settings: GlacierSettings, preview: Bool) -> Bool {
        !preview && settings.clipboard.captureEnabled && settings.modules["clipboard"]?.enabled != false
    }
    public var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    public func setLaunchAtLogin(_ enabled: Bool) {
        guard lifecycle.isActive else { return }
        guard !preview else { settingsWindow?.showError("Login registration is disabled in preview"); return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            settingsWindow?.refresh()
        } catch { settingsWindow?.showError(error.localizedDescription) }
    }
    public func clipboardStatus() async -> (paused: Bool, retentionHours: Int, itemCount: Int, usedBytes: Int?)? { await clipboard?.historyState() }
    public func setClipboardRetention(_ hours: Int) async throws { try await clipboard?.setRetentionHours(hours) }
    public func clearClipboardHistory() async throws { try await clipboard?.clearSavedHistory() }
    public func activateShortcuts() {
        guard lifecycle.isActive, let composition else { return }
        do { try shortcuts?.activate(registry: composition.snapshot.registry, unavailable: composition.snapshot.unavailableActions()); rebuildHelp(); settingsWindow?.refresh() }
        catch { settingsWindow?.showError(error.localizedDescription) }
    }
    private func reconcileShortcutReadiness() async {
        guard lifecycle.isActive, let composition, let shortcuts else { return }
        do {
            try await shortcuts.apply(composition.snapshot.read(), registry: composition.snapshot.registry, unavailable: composition.snapshot.unavailableActions()) { _ in }
            if !lifecycle.isActive { _ = shortcuts.stop() }
        } catch {
            guard lifecycle.isActive else { return }
            settingsWindow?.showNotice("Connection saved · " + error.localizedDescription)
        }
    }
    public func showHelp() { guard lifecycle.isActive, composition?.snapshot.permits("help.pin") == true else { return }; launchPalette?.dismiss(); help?.helpPressed() }
    private func rebuildHelp() {
        guard lifecycle.isActive, let composition else { return }
        help?.stop()
        help = shortcuts?.makeHelpOverlay(registry: composition.snapshot.registry)
        help?.start(monitoringKeyboard: !preview && shortcuts?.holdModifierFlags() != nil)
        if let shortcuts {
            let projection = ShortcutLabelProjection()
            let settings = composition.snapshot.read()
            composition.snapshot.setShortcutLabels(Dictionary(uniqueKeysWithValues: shortcuts.registeredActionIDs.compactMap { id in
                guard composition.snapshot.permits(id), let chord = settings.shortcuts[id]?.chord else { return nil }
                return (id, projection.label(chord))
            }))
            native?.refreshActionAvailability()
        }
    }
    private func prepareForNativeForeground() {
        guard lifecycle.isActive else { return }
        launchPalette?.dismiss()
        help?.dismiss()
        keyActions?.invalidate()
        collect?.invalidate()
        clipboard?.capturePendingBeforeForeground()
        clipboard?.dismiss(restoreFocus: false)
    }
    static func closeHostSettings(_ window: NSWindow, settingsWindow: NSWindow?) -> Bool {
        guard let settingsWindow, settingsWindow === window else { return false }
        settingsWindow.close()
        return true
    }
    private func showClipboard(query: String = "", originPID: pid_t? = nil, authoritativeOrigin: Bool = false) {
        guard lifecycle.isActive, let clipboard, let native, let foregroundDispatcher else { return }
        launchPalette?.dismiss()
        help?.dismiss()
        keyActions?.invalidate()
        collect?.invalidate()
        foregroundDispatcher.handoffToClipboard(
            query: query, explicitPID: originPID, authoritativeOrigin: authoritativeOrigin,
            nativeVisible: native.hasForegroundSurface,
            capturedNativeOrigin: { [weak native] in native?.capturedExternalOriginPID },
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            dismissNative: { [weak native] in native?.dismissOmniForeground(restoreFocus: false) },
            showClipboard: { [weak clipboard] query, pid in clipboard?.show(query: query, originPID: pid) })
    }
    public func invoke(_ id: String) {
        guard lifecycle.isActive, let native, let composition, composition.snapshot.permits(id) else { return }
        if id != "launch.open" { launchPalette?.dismiss() }
        if id == "help.pin" { showHelp(); return }
        help?.bindingFired(id)
        // A newer command wins even while an older helper awaits Hyper release.
        keyActions?.invalidate()
        collect?.invalidate()
        if id == "launch.open" {
            guard let launchPalette else { return }
            if launchPalette.isShown { launchPalette.dismiss(); return }
            guard let launchManifestURL else { return }
            do {
                let manifest = try LaunchManifest.load(from: launchManifestURL)
                let problems = launchPalette.load(bundleIDs: manifest.bundleIDs, keyOverrides: manifest.keyOverrides)
                (manifest.problems + problems.map(\.message)).forEach(report)
            } catch { report(error.localizedDescription); return }
            guard !launchPalette.applications.isEmpty else { return }
            foregroundDispatcher?.supersedeNative()
            native.dismissOmniForeground(restoreFocus: false)
            clipboard?.dismiss(restoreFocus: false)
            launchPalette.show()
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        let target = PasteTarget(front?.processIdentifier)
        let nativeActions: [String: HyperKeyAction] = ["native.reveal": .reveal, "native.open": .openNaturally, "native.jump-to-root": .jumpToRoot,
            "native.editor": .editInSublime, "native.terminal": .terminalHere, "native.copy-path": .copyPath, "native.fence": .fence, "native.gather-files": .gatherFiles]
        if let action = nativeActions[id] {
            foregroundDispatcher?.supersedeNative()
            _ = keyActions?.start(action, target: target, frontIsFinder: front?.bundleIdentifier == "com.apple.finder")
            return
        }
        let collection: [String: CollectAction] = ["clipboard.collect": .collect, "clipboard.paste-next": .pasteNext, "clipboard.paste-all": .pasteAll, "clipboard.clear-collection": .clear, "clipboard.equalize": .equalize]
        if let action = collection[id] {
            foregroundDispatcher?.dispatchEffect { [weak self] in
                guard let self, self.lifecycle.isActive, composition.snapshot.permits(id) else { return }
                await self.collect?.perform(action, target: target)
            }
            return
        }
        if id == "clipboard.history" { showClipboard(); return }
        if foregroundDispatcher?.dispatch(id) != nil { return }
        if let module = composition.tools.modules.first(where: { $0.descriptor.id == id }) {
            foregroundDispatcher?.supersedeNative()
            _ = native.beginContributedTool(descriptor: module.presentation, producer: module.makeProducer())
        }
    }
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        lifecycle.terminate()
        onboardingWindow?.close()
        foregroundDispatcher?.supersedeNative()
        startup?.cancel(); changes?.cancel(); native?.stop(); clipboard?.stop(); composition?.search.stopWatching()
        help?.stop(); _ = shortcuts?.stop(); keyActions?.invalidate(); collect?.invalidate()
        launchPalette?.dismiss()
        if let focusObserver { NSWorkspace.shared.notificationCenter.removeObserver(focusObserver) }
        guard let composition else { return .terminateNow }
        Task { _ = await composition.service.shutdown(); NSApplication.shared.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
