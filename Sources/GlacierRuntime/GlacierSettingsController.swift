import AppKit
import Foundation
import GlacierConfiguration
import GlacierConnections
import GlacierModuleKit
import GlacierPlatform
import GlacierPronunciation
import OmniPresentation
import OmniCore
import OmniModels

@MainActor
final class FlippedSettingsStack: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
final class ActionButton: NSButton {
    var handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler; super.init(frame: .zero)
        self.title = title; bezelStyle = .rounded; target = self; action = #selector(run)
    }
    @objc private func run() { handler() }
    required init?(coder: NSCoder) { fatalError() }
}
@MainActor
final class ActionField: NSTextField, NSTextFieldDelegate {
    var changed: (String) -> Void = { _ in }
    init(_ text: String, placeholder: String = "", changed: @escaping (String) -> Void) {
        super.init(frame: .zero); stringValue = text; placeholderString = placeholder; self.changed = changed
        delegate = self; target = self; action = #selector(submit)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
    }
    func controlTextDidEndEditing(_ obj: Notification) { changed(stringValue) }
    @objc private func submit() { changed(stringValue) }
    required init?(coder: NSCoder) { fatalError() }
}

/// Native, apply-on-change settings. Credential submission is explicit and never tests a provider automatically.
@MainActor
public final class GlacierSettingsController: NSWindowController {
    private weak var desktop: GlacierDesktop?
    private let tabs = NSTabView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var rendering = false
    private var renderRevision = 0
    public init(owner: GlacierDesktop) {
        self.desktop = owner
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 570), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Glacier Settings"; window.isReleasedWhenClosed = false; window.center()
        super.init(window: window)
        let content = NSStackView(views: [tabs, errorLabel]); content.orientation = .vertical; content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 14, right: 18)
        window.contentView = content
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 450).isActive = true
        tabs.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -36).isActive = true
        errorLabel.textColor = .systemRed
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    public func show() { refresh(); showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true) }
    public func showError(_ message: String) { errorLabel.stringValue = "Not saved · " + message }
    public func showNotice(_ message: String) { errorLabel.stringValue = message }
    public func refresh() {
        guard !rendering, let owner = desktop, let composition = owner.composition else { return }
        rendering = true; defer { rendering = false }
        renderRevision += 1
        let revision = renderRevision
        let selected = tabs.selectedTabViewItem?.identifier as? String
        tabs.tabViewItems.forEach(tabs.removeTabViewItem)
        let settings = composition.snapshot.read()
        pane("General", views: [
            label("Glacier", bold: true), label("A standalone workspace. No account is required. Online tools use your own provider connections."),
            toggle("Pause AI requests", value: settings.ai.paused) { value in owner.change { $0.ai.paused = value } },
            toggle("Offline mode — no remote services", value: settings.ai.offline) { value in owner.change { $0.ai.offline = value } },
            label("Offline mode allows configured loopback models. Local tools work without an AI key. Your folders and clipboard history are not uploaded automatically."),
            ActionButton("Open Glacier") { owner.invoke("launcher.open") },
            ActionButton("Getting started…") { owner.showOnboarding() },
            toggle("Launch at login", value: owner.launchAtLogin) { owner.setLaunchAtLogin($0) },
            label(owner.preview ? "Preview mode: global shortcuts and clipboard collection are disabled." : "Shortcuts begin unbound. Choose each binding in Shortcuts; existing Omni remains independent.")
        ])
        var modules: [NSView] = [label("Choose which functions are available. Turning a module off also disables its typed routes and shortcuts.")]
        let groups = Dictionary(grouping: composition.snapshot.registry.descriptors, by: \.moduleID)
        for id in groups.keys.sorted() where id != "settings" {
            let title = ["native-utilities": "File and text utilities", "writing": "Writing tools", "clipboard": "Clipboard and Collect" ][id] ?? groups[id]!.first!.title
            if let reason = composition.snapshot.unavailableActions()[id] { modules.append(label(title + " · " + reason)); continue }
            modules.append(toggle(title, value: settings.modules[id]?.enabled ?? true) { value in owner.change { var item = $0.modules[id] ?? .init(); item.enabled = value; $0.modules[id] = item } })
            let reasons = Set(groups[id]!.compactMap { composition.snapshot.unavailableActions()[$0.id] })
            if !reasons.isEmpty { modules.append(label(reasons.sorted().joined(separator: " · "))) }
            if groups[id]!.contains(where: { $0.networkRequirement == .remoteAI }) {
                modules.append(toggle("Generate automatically while typing", value: settings.modules[id]?.automaticRequests ?? false) { value in owner.change { var item = $0.modules[id] ?? .init(); item.automaticRequests = value; $0.modules[id] = item } })
            }
        }
        pane("Modules", views: modules)
        pane("Connections", views: [label("Keys stay in Glacier's Keychain namespace. Saving is local. Using an online tool sends its input and captured selection to the provider you choose."), label("Loading connections…")])
        Task { [weak self] in
            let document = await composition.connections.snapshot()
            guard let self, self.renderRevision == revision else { return }
            self.populateConnections(document)
        }
        var sources: [NSView] = [label("Applications are indexed automatically. Add files or folders to local filename search. Home is opt-in; protected application state, dependencies and hidden files are excluded."),
            toggle("Include my Home folder", value: settings.roots.includeHome) { value in owner.change { $0.roots.includeHome = value } },
            ActionButton("Add files or folders…") { [weak self] in self?.addSources() }]
        for root in settings.roots.sources {
            sources.append(row([toggle(root.path, value: root.enabled) { value in owner.change { if let i = $0.roots.sources.firstIndex(where: { $0.id == root.id }) { $0.roots.sources[i].enabled = value } } }, ActionButton("Remove") { owner.change { $0.roots.sources.removeAll { $0.id == root.id } } }]))
            sources.append(toggle("Search subfolders", value: root.recursive) { value in owner.change { if let i = $0.roots.sources.firstIndex(where: { $0.id == root.id }) { $0.roots.sources[i].recursive = value } } })
            sources.append(toggle("Include source files and JSON", value: root.includeSourceFiles) { value in owner.change { if let i = $0.roots.sources.firstIndex(where: { $0.id == root.id }) { $0.roots.sources[i].includeSourceFiles = value } } })
            sources.append(ActionField(root.excludedNames.joined(separator: ", "), placeholder: "Excluded directory names, comma separated") { value in
                owner.change { if let i = $0.roots.sources.firstIndex(where: { $0.id == root.id }) { $0.roots.sources[i].excludedNames = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } }
            })
        }
        pane("Sources", views: sources)
        var shortcuts: [NSView] = [label("Record an actual modifier chord. Caps Lock → Hyper remapping, if wanted, is configured externally. Glacier never edits your remapper."), label("Conflicting shortcuts remain inactive. Disabling a shortcut leaves its typed route available."), label("Registered shortcuts: \(owner.registeredShortcutCount)"), ActionButton("Load suggested Hyper layout") { owner.change { $0 = try SuggestedHyperPreset.applying(to: $0) } }, label("The preset uses ⌘⌥⌃⇧. It does not remap a physical key. Quick Question stays unbound; record a chord that works on your system."), ActionButton("Activate saved shortcuts") { owner.activateShortcuts() }, ActionButton("Show keyboard help") { owner.showHelp() }]
        for descriptor in composition.snapshot.registry.descriptors where descriptor.hasShortcut {
            let item = settings.shortcuts[descriptor.id] ?? .init()
            let recorder = ShortcutRecorder(chord: item.chord) { chord in owner.change { $0.shortcuts[descriptor.id] = .init(enabled: true, chord: chord) } }
            shortcuts.append(row([toggle(descriptor.title, value: item.enabled) { value in owner.change { var item = $0.shortcuts[descriptor.id] ?? .init(); item.enabled = value; $0.shortcuts[descriptor.id] = item } }, recorder,
                ActionButton("Clear") { owner.change { $0.shortcuts[descriptor.id] = .init() } }]))
        }
        shortcuts.append(label("Apps · Launch", bold: true))
        let launchListing = owner.launchAppsForSettings()
        if launchListing.lines.isEmpty { shortcuts.append(label("No apps in Launch. Add up to eight bundle IDs in the manifest.")) }
        else { shortcuts.append(contentsOf: launchListing.lines.map { label($0) }) }
        shortcuts.append(contentsOf: launchListing.problems.map { label("Manifest: " + $0) })
        shortcuts.append(ActionButton("Edit manifest…") { owner.editLaunchManifest() })
        pane("Shortcuts", views: shortcuts)
        let terminal = NSPopUpButton(); terminal.addItems(withTitles: ["Terminal", "Ghostty"])
        terminal.selectItem(at: settings.terminal == .ghostty ? 1 : 0)
        let terminalChoice = PopupAction(terminal) { index in owner.change { $0.terminal = index == 1 ? .ghostty : .systemTerminal } }
        var tools: [NSView] = [row([label("Preferred terminal"), terminalChoice]),
            ActionField(settings.editorBundleID, placeholder: "Preferred editor bundle identifier") { value in owner.change { $0.editorBundleID = value } },
            ActionField(settings.roots.jumpToRoot ?? "", placeholder: "Jump to Root folder") { value in owner.change { $0.roots.jumpToRoot = value.isEmpty ? nil : value } },
            label("Translation defaults to detected source → English."),
            ActionField(settings.translation.sourceLanguage, placeholder: "Source language: auto") { value in owner.change { $0.translation.sourceLanguage = value } },
            ActionField(settings.translation.targetLanguage, placeholder: "Target language: en") { value in owner.change { $0.translation.targetLanguage = value } },
            ActionField(settings.roots.captureDirectory ?? "", placeholder: "Note folder — empty uses Glacier storage") { value in owner.change { $0.roots.captureDirectory = value.isEmpty ? nil : value } },
            ActionField(settings.roots.linkDirectory ?? "", placeholder: "Link folder — empty uses Glacier storage") { value in owner.change { $0.roots.linkDirectory = value.isEmpty ? nil : value } },
            toggle("Collect clipboard history", value: settings.clipboard.captureEnabled) { value in owner.change { $0.clipboard.captureEnabled = value } }]
        tools.append(label("Clipboard collection starts off. Changing this does not affect Omni's clipboard settings."))
        tools.append(row([ActionButton("Export preferences…") { [weak self] in self?.exportPreferences() }, ActionButton("Import preferences…") { [weak self] in self?.importPreferences() }]))
        tools.append(label("Preferences exports contain no provider connections, keys or history. Imports leave shortcuts, capture and automatic network work off until you enable them."))
        pane("Tools & Data", views: tools)
        let baseTools = tools
        Task { [weak self] in
            let pronunciation = await owner.pronunciationSettings?.preferences()
            let clipboard = await owner.clipboardStatus()
            guard let self, self.renderRevision == revision else { return }
            var rows = baseTools
            if let native = owner.native {
                let express = native.preferences.current
                rows.append(label("Express", bold: true))
                rows.append(label("Express uses its own language pair. Translate source and target settings above are independent."))
                let primary = NSPopUpButton(); primary.addItems(withTitles: OmniLanguagePair.choices.map(\.name))
                primary.selectItem(at: OmniLanguagePair.choices.firstIndex(where: { $0.code == express.expressLanguages.primary }) ?? 0)
                rows.append(row([label("Primary language"), PopupAction(primary) { [weak self] index in
                    do { try native.preferences.update { $0.expressLanguages = $0.expressLanguages.withPrimary(OmniLanguagePair.choices[index].code) } }
                    catch { self?.showError(error.localizedDescription) }
                }]))
                let secondary = NSPopUpButton(); secondary.addItems(withTitles: OmniLanguagePair.choices.map(\.name))
                secondary.selectItem(at: OmniLanguagePair.choices.firstIndex(where: { $0.code == express.expressLanguages.secondary }) ?? 1)
                rows.append(row([label("Secondary language"), PopupAction(secondary) { [weak self] index in
                    do { try native.preferences.update { $0.expressLanguages = $0.expressLanguages.withSecondary(OmniLanguagePair.choices[index].code) } }
                    catch { self?.showError(error.localizedDescription) }
                }]))
                let output = NSPopUpButton(); output.addItems(withTitles: ["Primary language", "Switch between languages"])
                output.selectItem(at: OmniExpressOutputMode.allCases.firstIndex(of: express.expressOutputMode) ?? 0)
                rows.append(row([label("Output"), PopupAction(output) { [weak self] index in
                    do { try native.preferences.update { $0.expressOutputMode = OmniExpressOutputMode.allCases[index] } }
                    catch { self?.showError(error.localizedDescription) }
                }]))
                rows.append(label("Primary language always offers natural wording in the primary language. Switch between languages sends primary-language input to secondary; other input to primary."))
                let appearance = NSPopUpButton(); appearance.addItems(withTitles: ["System", "Light", "Dark"])
                appearance.selectItem(at: OmniAppearance.allCases.firstIndex(of: native.preferences.current.appearance) ?? 0)
                rows.append(row([label("Appearance"), PopupAction(appearance) { [weak self] index in
                    do { try native.preferences.update { $0.appearance = OmniAppearance.allCases[index] }; native.applyAppearance(OmniAppearance.allCases[index]) } catch { self?.showError(error.localizedDescription) }
                }]))
                rows.append(toggle("Use location for Weather", value: native.preferences.current.weatherUsesLocation) { [weak self] value in
                    do { try native.preferences.update { $0.weatherUsesLocation = value } } catch { self?.showError(error.localizedDescription) }
                })
                rows.append(label("Recall command sheet: " + (native.preferences.current.recallSheetPath ?? "Glacier built-in sheet")))
                rows.append(row([ActionButton("Choose Recall sheet…") { [weak self] in
                    let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
                    guard picker.runModal() == .OK, let url = picker.url else { return }
                    do { try native.preferences.update { $0.recallSheetPath = url.path }; self?.refresh() } catch { self?.showError(error.localizedDescription) }
                }, ActionButton("Use built-in Recall sheet") { [weak self] in
                    do { try native.preferences.update { $0.recallSheetPath = nil }; self?.refresh() } catch { self?.showError(error.localizedDescription) }
                }]))
                let units = NSPopUpButton(); units.addItems(withTitles: ["System units", "Metric", "Imperial"])
                units.selectItem(at: OmniWeatherUnits.allCases.firstIndex(of: native.preferences.current.weatherUnits) ?? 0)
                rows.append(row([label("Weather"), PopupAction(units) { [weak self] index in
                    do { try native.preferences.update { $0.weatherUnits = OmniWeatherUnits.allCases[index] } } catch { self?.showError(error.localizedDescription) }
                }]))
                let skin = NSPopUpButton(); skin.addItems(withTitles: OmniSkinTone.allCases.map { $0.rawValue })
                skin.selectItem(at: OmniSkinTone.allCases.firstIndex(of: native.preferences.current.skinTone) ?? 0)
                rows.append(row([label("Emoji skin tone"), PopupAction(skin) { [weak self] index in
                    do { try native.preferences.update { $0.skinTone = OmniSkinTone.allCases[index] } } catch { self?.showError(error.localizedDescription) }
                }]))
            }
            if let clipboard {
                rows.append(label("Clipboard history: \(clipboard.itemCount) items · retention \(clipboard.retentionHours) hours"))
                rows.append(ActionField(String(clipboard.retentionHours), placeholder: "Retention hours") { [weak self] value in self?.connectionTask {
                    guard let hours = Int(value), (1...720).contains(hours) else { throw GlacierRuntimeError.unavailable("Choose 1–720 hours") }
                    try await owner.setClipboardRetention(hours)
                } })
                rows.append(ActionButton("Clear Glacier clipboard history…") { [weak self] in
                    guard self?.confirm("Clear Glacier clipboard history?", detail: "This clears only this app's saved history.") == true else { return }
                    self?.connectionTask { try await owner.clearClipboardHistory() }
                })
            }
            if let pronunciation, let store = owner.pronunciationSettings {
                rows.append(label("Pronunciation", bold: true))
                let accent = NSPopUpButton(); accent.addItems(withTitles: ["Prefer US", "Prefer UK"]); accent.selectItem(at: pronunciation.accent == .uk ? 1 : 0)
                rows.append(PopupAction(accent) { [weak self] index in self?.connectionTask { try await store.updateAccent(index == 1 ? .uk : .us) } })
                rows.append(ActionField(pronunciation.voice ?? "", placeholder: "System voice (optional)") { [weak self] value in self?.connectionTask { try await store.updateVoice(value) } })
                rows.append(ActionField(pronunciation.ukVoice ?? "", placeholder: "UK system voice (optional)") { [weak self] value in self?.connectionTask { try await store.updateVoice(value, accent: .uk) } })
                rows.append(label("Optional Wikimedia contact is sent in dictionary request headers. Leave empty to use the other configured sources and local speech."))
                rows.append(ActionField(pronunciation.wikimediaContact ?? "", placeholder: "Wikimedia contact URL or email (optional)") { [weak self] value in self?.connectionTask { try await store.updateWikimediaContact(value) } })
                for provider in PronunciationKeyProvider.allCases {
                    let field = NSSecureTextField(); field.placeholderString = provider == .forvo ? "Forvo API key" : "Merriam-Webster API key"
                    rows.append(label("\(provider.rawValue): \(pronunciation.account(for: provider) == nil ? "No key" : "Key saved · untested")"))
                    rows.append(row([field, ActionButton("Save key") { [weak self] in
                        let key = field.stringValue; field.stringValue = ""
                        self?.connectionTask(invalidateModels: true) { try await store.saveKey(provider: provider, key: key) }
                    }, ActionButton("Remove") { [weak self] in self?.connectionTask(invalidateModels: true) { try await store.clearKey(provider: provider) } }]))
                }
            }
            self.replacePane("Tools & Data", views: rows)
        }
        if let selected, let item = tabs.tabViewItems.first(where: { $0.identifier as? String == selected }) { tabs.selectTabViewItem(item) }
    }
    private func populateConnections(_ document: ConnectionsDocument) {
        guard let owner = desktop, let composition = owner.composition else { return }
        var views: [NSView] = [label("Online tools send their input to the selected provider. Keys are never exported. Saving credentials does not make a network request. After saving a key, choose a model below to enable its route.")]
        for profile in document.profiles {
            let key = NSSecureTextField(); key.placeholderString = "New API key"; key.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
            views.append(label(profile.provider.displayName, bold: true))
            views.append(toggle("Enabled", value: profile.enabled) { [weak self] value in self?.connectionTask(invalidateModels: true) { try await composition.connections.setEnabled(value, for: profile.id); try await owner.refreshConnections() } })
            views.append(ActionField(profile.endpoint.absoluteString, placeholder: "Provider endpoint") { [weak self] value in self?.connectionTask(invalidateModels: true) {
                guard let url = URL(string: value) else { throw ConnectionError.invalidEndpoint }
                try await composition.connections.setEndpoint(url, for: profile.id); try await owner.refreshConnections()
            } })
            views.append(label("Credential: \(profile.credentialSource?.displayKind ?? (profile.provider.requiresCredential ? "Not configured" : "Not required")) · destination \(profile.origin.description)"))
            if profile.provider.requiresCredential {
                views.append(row([key, ActionButton("Use key for this destination") { [weak self] in
                    let value = key.stringValue; key.stringValue = ""
                    self?.connectionTask(invalidateModels: true) { try await composition.connections.saveKey(value, for: profile.id); try await owner.refreshConnections() }
                }]))
                let path = NSTextField(); path.placeholderString = "Absolute dotenv path"
                let name = NSTextField(); name.placeholderString = "KEY_NAME"
                name.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
                path.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
                views.append(row([path, name, ActionButton("Use file reference") { [weak self] in
                    let file = path.stringValue, keyName = name.stringValue
                    self?.connectionTask(invalidateModels: true) { try await composition.connections.approveSource(.dotenvFile(path: file, key: keyName), for: profile.id); try await owner.refreshConnections() }
                }]))
                let variable = NSTextField(); variable.placeholderString = "Named environment variable (advanced)"
                views.append(row([variable, ActionButton("Use environment reference") { [weak self] in
                    let name = variable.stringValue
                    self?.connectionTask(invalidateModels: true) { try await composition.connections.approveSource(.processEnvironment(name: name), for: profile.id); try await owner.refreshConnections() }
                }]))
                views.append(ActionButton("Remove credential") { [weak self] in self?.connectionTask(invalidateModels: true) { try await composition.connections.clearCredential(for: profile.id); try await owner.refreshConnections() } })
            }
            views.append(ActionButton("Test connection — sends a small request") { [weak self] in
                self?.connectionTask {
                    let result = try await composition.connections.testConnection(profile.id, gate: { url in
                        if composition.snapshot.read().ai.offline && !["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host ?? "") { throw GlacierRuntimeError.unavailable("Turn off offline mode before testing a remote connection") }
                    })
                    await MainActor.run { self?.errorLabel.stringValue = "\(profile.provider.rawValue): HTTP \(result.statusCode); credential status \(result.credentialStatus.rawValue). This is not a model-quality test." }
                }
            })
            let profiles = ProviderRuntimeCatalog.profiles.filter { $0.connectionID == profile.id }
            for model in profiles {
                let selector = document.modelOverrides.first { $0.profileID == model.id }?.modelSelector ?? model.modelSelector
                views.append(label(model.displayName, bold: true))
                views.append(ActionField(selector, placeholder: "Provider model identifier") { [weak self] value in self?.connectionTask(invalidateModels: true) {
                    try await composition.connections.setModelSelector(profileID: model.id, modelSelector: value)
                    try await owner.refreshConnections()
                } })
                views.append(ActionButton("Use \(model.displayName) for AI tools") { [weak self] in self?.connectionTask(invalidateModels: true) { try await owner.selectModel(model.id) } })
            }
        }
        views.append(label("Per-tool models", bold: true))
        views.append(label("Choosing an API profile uses that configured connection and its billing. Unconfigured connections stay unavailable."))
        let availableProfiles = ProviderRuntimeCatalog.profiles.filter { ![ProviderRuntimeCatalog.chatGPTConnectionID, ProviderRuntimeCatalog.claudeConnectionID].contains($0.connectionID) }
        for command in ModelProviderPolicy.v6.commands where command.commandID != "find.indexed" {
            let choices = NSPopUpButton()
            choices.addItem(withTitle: "Choose a model…")
            choices.addItems(withTitles: availableProfiles.map { profile in
                let recommended = ["draft.email", "draft.message"].contains(command.commandID)
                    && profile.id == ProviderRuntimeCatalog.cerebrasDraftProfileID
                return profile.displayName + (recommended ? " (Recommended)" : "")
            })
            if let current = composition.snapshot.profile(command.commandID), let index = availableProfiles.firstIndex(where: { $0.id == current }) { choices.selectItem(at: index + 1) }
            views.append(row([label(command.commandID.replacingOccurrences(of: ".", with: " ").capitalized), PopupAction(choices) { [weak self] index in
                guard index > 0 else { return }
                self?.connectionTask(invalidateModels: true) { try await owner.selectModel(availableProfiles[index - 1].id, for: command.commandID) }
            }]))
        }
        replacePane("Connections", views: views)
    }
    private func exportPreferences() {
        guard let composition = desktop?.composition else { return }
        let picker = NSSavePanel(); picker.nameFieldStringValue = "glacier-preferences.json"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(composition.snapshot.read()).write(to: url, options: .atomic)
        } catch { showError(error.localizedDescription) }
    }
    private func importPreferences() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do {
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= 512_000 else { throw GlacierRuntimeError.unavailable("Preferences file is too large") }
            var imported = try JSONDecoder().decode(GlacierSettings.self, from: bytes)
            for key in Array(imported.shortcuts.keys) { imported.shortcuts[key]?.enabled = false }
            for key in Array(imported.modules.keys) { imported.modules[key]?.automaticRequests = false }
            imported.clipboard.captureEnabled = false
            imported.ai.paused = true; imported.ai.offline = true
            imported.roots.includeHome = false; imported.roots.jumpToRoot = nil
            imported.roots.captureDirectory = nil; imported.roots.linkDirectory = nil
            for index in imported.roots.sources.indices { imported.roots.sources[index].enabled = false; imported.roots.sources[index].bookmark = nil }
            let safe = imported
            desktop?.change { $0 = safe }
        } catch { showError(error.localizedDescription) }
    }
    private func confirm(_ title: String, detail: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "Clear"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    private var connectionChanges: Task<Void, Never>?
    private func connectionTask(invalidateModels: Bool = false, _ action: @escaping @MainActor () async throws -> Void) {
        let previous = connectionChanges
        connectionChanges = Task { [weak self] in
            await previous?.value
            if invalidateModels { await self?.desktop?.beginConnectionChange() }
            do {
                try await action()
                if invalidateModels { await self?.desktop?.endConnectionChange() }
                self?.refresh()
            } catch {
                if invalidateModels { await self?.desktop?.endConnectionChange() }
                self?.refresh(); self?.showNotice("Could not complete · " + error.localizedDescription)
            }
        }
    }
    private func addSources() {
        let picker = NSOpenPanel(); picker.canChooseFiles = true; picker.canChooseDirectories = true; picker.allowsMultipleSelection = true
        guard picker.runModal() == .OK else { return }
        let roots = picker.urls.map { url in GlacierSourceRoot(path: url.path, bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)) }
        desktop?.change { settings in settings.roots.sources += roots.filter { root in !settings.roots.sources.contains { $0.path == root.path } } }
    }
    private func pane(_ name: String, views: [NSView]) {
        let item = NSTabViewItem(identifier: name); item.label = name; item.view = scroll(views); tabs.addTabViewItem(item)
    }
    private func replacePane(_ name: String, views: [NSView]) { tabs.tabViewItems.first { $0.identifier as? String == name }?.view = scroll(views) }
    private func scroll(_ views: [NSView]) -> NSView {
        let stack = FlippedSettingsStack(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 18, bottom: 20, right: 18)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.documentView = stack; stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        for view in views {
            view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -36).isActive = true
            if view is NSStackView { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true }
        }
        return scroll
    }
    private func label(_ text: String, bold: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text); field.font = bold ? .boldSystemFont(ofSize: 14) : .systemFont(ofSize: 12)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); return field
    }
    private func row(_ views: [NSView]) -> NSStackView { let row = NSStackView(views: views); row.spacing = 10; row.alignment = .centerY; return row }
    private func toggle(_ title: String, value: Bool, changed: @escaping (Bool) -> Void) -> NSButton {
        let button = ActionButton(title, handler: {}); button.setButtonType(.switch); button.state = value ? .on : .off
        button.handler = { [weak button] in changed(button?.state == .on) }; return button
    }
}

@MainActor
final class PopupAction: NSView {
    let popup: NSPopUpButton
    let handler: (Int) -> Void
    init(_ popup: NSPopUpButton, handler: @escaping (Int) -> Void) {
        self.popup = popup; self.handler = handler; super.init(frame: .zero)
        addSubview(popup); popup.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([popup.leadingAnchor.constraint(equalTo: leadingAnchor), popup.trailingAnchor.constraint(equalTo: trailingAnchor), popup.topAnchor.constraint(equalTo: topAnchor), popup.bottomAnchor.constraint(equalTo: bottomAnchor)])
        popup.target = self; popup.action = #selector(changed)
    }
    @objc private func changed() { handler(popup.indexOfSelectedItem) }
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class ShortcutRecorder: NSButton {
    let changed: (GlacierShortcutChord) -> Void
    private var recording = false
    init(chord: GlacierShortcutChord?, changed: @escaping (GlacierShortcutChord) -> Void) {
        self.changed = changed; super.init(frame: .zero)
        title = chord.map { ShortcutLabelProjection().label($0) } ?? "Record shortcut…"
        bezelStyle = .rounded; target = self; action = #selector(begin)
    }
    override var acceptsFirstResponder: Bool { true }
    @objc private func begin() { recording = true; title = "Press shortcut (Esc cancels)"; window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; title = "Record shortcut…"; return }
        var modifiers: [GlacierShortcutModifier] = []
        if event.modifierFlags.contains(.command) { modifiers.append(.command) }
        if event.modifierFlags.contains(.option) { modifiers.append(.option) }
        if event.modifierFlags.contains(.control) { modifiers.append(.control) }
        if event.modifierFlags.contains(.shift) { modifiers.append(.shift) }
        guard let chord = try? GlacierShortcutChord(keyCode: event.keyCode, modifiers: modifiers) else { NSSound.beep(); return }
        recording = false; changed(chord)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }; keyDown(with: event); return true
    }
    required init?(coder: NSCoder) { fatalError() }
}
