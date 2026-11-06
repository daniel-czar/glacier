import AppKit
import ApplicationServices
import Foundation
import GlacierConfiguration
import GlacierConnections
import OmniCore
import OmniModels

/// Narrow host contract keeps setup on the same serialized settings/route owners
/// as Settings. Fixture hosts can exercise these adapters without OS effects.
@MainActor protocol GlacierOnboardingHost: AnyObject {
    var composition: GlacierComposition? { get }
    var preview: Bool { get }
    var onboardingIsActive: Bool { get }
    var launchAtLogin: Bool { get }
    func change(activateShortcuts: Bool, authorizeCommit: @escaping @Sendable () throws -> Void,
                _ transform: @escaping @Sendable (inout GlacierSettings) throws -> Void) -> Task<Bool, Never>
    func setLaunchAtLogin(_ enabled: Bool)
    func beginConnectionChange() async
    func endConnectionChange() async
    func refreshConnections() async throws
    func selectModel(_ id: String, for command: String?, authorizeCommit: @Sendable () throws -> Void) async throws
}

extension GlacierDesktop: GlacierOnboardingHost {}

/// Safe to check from the host's Sendable settings transform after its queue
/// yields. Closing and reopening the window never revives an older queued edit.
private final class GlacierOnboardingSessionEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var active = false
    var current: UInt64 { lock.withLock { revision } }
    func begin() { lock.withLock { revision &+= 1; active = true } }
    func end() { lock.withLock { revision &+= 1; active = false } }
    func check(_ expected: UInt64? = nil) throws {
        try lock.withLock {
            guard active, expected == nil || expected == revision else { throw CancellationError() }
        }
    }
}

@MainActor struct GlacierOnboardingPlatformEffects {
    var accessibilityTrusted: () -> Bool
    var openAccessibilitySettings: () -> Void
    var chooseRoots: () throws -> [GlacierSourceRoot]?

    static var live: Self {
        Self(accessibilityTrusted: { AXIsProcessTrusted() }, openAccessibilitySettings: {
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
            NSWorkspace.shared.open(url)
        }, chooseRoots: {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.prompt = "Add to search"
            panel.message = "Glacier searches only the folders you choose."
            guard panel.runModal() == .OK else { return nil }
            return try panel.urls.map { url in
                let canonical = try GlacierPaths.validateUserDirectory(url)
                return GlacierSourceRoot(path: canonical.path,
                    bookmark: try canonical.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
            }
        })
    }
}

@MainActor final class GlacierOnboardingLiveActions: GlacierOnboardingActions {
    private weak var host: (any GlacierOnboardingHost)?
    private let effects: GlacierOnboardingPlatformEffects
    private let network: any ConnectionNetworkTransport
    private let session = GlacierOnboardingSessionEpoch()

    init(host: any GlacierOnboardingHost, effects: GlacierOnboardingPlatformEffects? = nil,
         network: any ConnectionNetworkTransport = NoRedirectURLSessionTransport()) {
        self.host = host
        self.effects = effects ?? .live
        self.network = network
    }

    func beginSession() { session.begin() }
    func endSession() { session.end() }

    private func context(_ expectedRevision: UInt64? = nil) throws -> (any GlacierOnboardingHost, GlacierComposition) {
        try Task.checkCancellation()
        try session.check(expectedRevision)
        guard let host, host.onboardingIsActive, let composition = host.composition else {
            throw GlacierRuntimeError.unavailable("Glacier is no longer running.")
        }
        return (host, composition)
    }

    private func mutableContext() throws -> (any GlacierOnboardingHost, GlacierComposition) {
        let pair = try context()
        guard !pair.0.preview else { throw GlacierOnboardingModelError.unavailableInPreview }
        return pair
    }

    func snapshot() async throws -> GlacierOnboardingSnapshot {
        let revision = session.current
        let (host, composition) = try context()
        let settings = composition.snapshot.read()
        let document = await composition.connections.snapshot()
        _ = try context(revision)
        let choices = ProviderRuntimeCatalog.profiles.compactMap { profile -> GlacierOnboardingModelChoice? in
            guard let provider = ConnectionProvider.allCases.first(where: { $0.connectionID == profile.connectionID }) else { return nil }
            let selector = document.modelOverrides.first(where: { $0.profileID == profile.id })?.modelSelector ?? profile.modelSelector
            let label = ProviderRuntimeCatalog.displayLabel(profileID: profile.id,
                connectionID: profile.connectionID, modelSelector: selector, options: profile.options)
            return .init(id: profile.id, label: label, provider: provider, modelSelector: selector)
        }
        let configured = Set(document.profiles.filter { $0.enabled && $0.isReadyForCredential }.map(\.provider))
        let shortcut = settings.shortcuts["launcher.open"].flatMap { $0.enabled ? $0.chord : nil }
        let remembered = (host as? GlacierDesktop)?.native?.preferences.current.ephemeralProfileID
            ?? composition.snapshot.profile("answer.quick")
        let selected = choices.first(where: { $0.id == remembered && configured.contains($0.provider) })?.id
        return .init(isPreview: host.preview, shortcut: shortcut,
                     accessibilityTrusted: !host.preview && effects.accessibilityTrusted(),
                     modelChoices: choices,
                     connectionEndpoints: Dictionary(uniqueKeysWithValues: document.profiles.map { ($0.provider, $0.endpoint) }),
                     selectedModelProfileID: selected,
                     sourceRoots: settings.roots.sources, clipboardEnabled: settings.clipboard.captureEnabled,
                     launchAtLogin: host.launchAtLogin, connectionSavedProviders: configured)
    }

    func saveShortcut(_ choice: GlacierOnboardingShortcutChoice) async throws {
        let revision = session.current
        let (host, composition) = try mutableContext()
        guard composition.snapshot.permits("launcher.open") else {
            throw GlacierRuntimeError.unavailable("Enable Launcher in Settings before assigning its shortcut.")
        }
        let chord = choice.chord
        let session = self.session
        let saved = await host.change(activateShortcuts: chord != nil, authorizeCommit: { try session.check(revision) }) { settings in
            try session.check(revision)
            settings.shortcuts["launcher.open"] = .init(enabled: chord != nil, chord: chord)
        }.value
        _ = try context(revision)
        guard saved else {
            throw GlacierRuntimeError.unavailable("The shortcut could not be saved or activated. It may already be in use. Choose another chord and try again.")
        }
    }

    func openAccessibilitySettings() {
        guard (try? mutableContext()) != nil else { return }
        effects.openAccessibilitySettings()
    }

    func checkAccessibility() async throws -> Bool {
        _ = try mutableContext()
        return effects.accessibilityTrusted()
    }

    func saveConnection(provider: ConnectionProvider, modelProfileID: String, expectedEndpoint: URL, apiKey: String?) async throws {
        let revision = session.current
        let session = self.session
        let (host, composition) = try mutableContext()
        guard let profile = ProviderRuntimeCatalog.profiles.first(where: { $0.id == modelProfileID }),
              profile.connectionID == provider.connectionID else { throw GlacierOnboardingModelError.chooseModel }
        await host.beginConnectionChange()
        do {
            _ = try context(revision)
            if provider.requiresCredential {
                if let key = apiKey, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try await composition.connections.saveKey(key, for: provider.connectionID, expectedEndpoint: expectedEndpoint,
                                                             authorizeCommit: { try session.check(revision) })
                } else {
                    guard let current = await composition.connections.profile(provider.connectionID),
                          current.endpoint == expectedEndpoint, current.isReadyForCredential else {
                        throw ConnectionError.missingCredential
                    }
                }
            } else {
                guard let current = await composition.connections.profile(provider.connectionID), current.endpoint == expectedEndpoint else {
                    throw ConnectionError.originApprovalRequired
                }
            }
            _ = try context(revision)
            try await composition.connections.setEnabled(true, for: provider.connectionID,
                                                         authorizeCommit: { try session.check(revision) })
            _ = try context(revision)
            try await host.refreshConnections()
            _ = try context(revision)
            try await host.selectModel(modelProfileID, for: nil, authorizeCommit: { try session.check(revision) })
            _ = try context(revision)
            await host.endConnectionChange()
        } catch {
            await host.endConnectionChange()
            throw error
        }
    }

    func testConnection(provider: ConnectionProvider) async throws -> String {
        let revision = session.current
        let session = self.session
        let (_, composition) = try mutableContext()
        let result = try await composition.connections.testConnection(provider.connectionID, network: network, gate: { url in
            try session.check(revision)
            let policy = composition.snapshot.read().ai
            guard !policy.paused else { throw GlacierRuntimeError.unavailable("AI requests are paused in Settings.") }
            let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host ?? "")
            guard !policy.offline || local else { throw GlacierRuntimeError.unavailable("Turn off offline mode before checking a remote provider.") }
        })
        _ = try context(revision)
        if [401, 403].contains(result.statusCode) {
            throw GlacierRuntimeError.unavailable("The provider rejected this key. Check it in Settings.")
        }
        return "\(provider.displayName) responded · HTTP \(result.statusCode). This does not test a generated answer."
    }

    func chooseSourceRoots() async throws -> [GlacierSourceRoot]? {
        let revision = session.current
        _ = try mutableContext()
        guard let additions = try effects.chooseRoots() else { return nil }
        _ = try context(revision)
        return additions
    }

    func saveSourceRoots(_ roots: [GlacierSourceRoot]) async throws {
        let revision = session.current
        let (host, _) = try mutableContext()
        let session = self.session
        let saved = await host.change(activateShortcuts: false, authorizeCommit: { try session.check(revision) }) {
            try session.check(revision)
            $0.roots.sources = roots
        }.value
        _ = try context(revision)
        guard saved else { throw GlacierRuntimeError.unavailable("The search folders could not be saved. Try again in Settings.") }
    }

    func setClipboardEnabled(_ enabled: Bool) async throws {
        let revision = session.current
        let (host, composition) = try mutableContext()
        guard !enabled || composition.snapshot.permits("clipboard.history") else {
            throw GlacierRuntimeError.unavailable("Clipboard History is disabled in Settings.")
        }
        let session = self.session
        let saved = await host.change(activateShortcuts: false, authorizeCommit: { try session.check(revision) }) {
            try session.check(revision)
            $0.clipboard.captureEnabled = enabled
        }.value
        _ = try context(revision)
        guard saved else { throw GlacierRuntimeError.unavailable("The clipboard choice could not be applied.") }
    }

    func setLaunchAtLogin(_ enabled: Bool) async throws {
        let (host, _) = try mutableContext()
        host.setLaunchAtLogin(enabled)
        guard host.launchAtLogin == enabled else {
            throw GlacierRuntimeError.unavailable("The login choice is not enabled yet. Check Login Items in System Settings.")
        }
    }

    func runDemo(_ demo: GlacierOnboardingDemo) async throws -> String {
        let (_, composition) = try context()
        let action = demo == .date ? "command.span" : demo == .symbol ? "tool.characters" : "launcher.open"
        guard composition.snapshot.permits(action) else {
            throw GlacierRuntimeError.unavailable("This tool is disabled in Settings. You can still finish setup.")
        }
        return try Self.localResult(demo)
    }

    static func localResult(_ demo: GlacierOnboardingDemo) throws -> String {
        switch demo {
        case .date:
            guard let result = SpanCalculator.result(payload: SpanCalculator.payload(fromCommandText: demo.command)) else {
                throw GlacierRuntimeError.unavailable("The date example could not be calculated.")
            }
            return result.block
        case .calculation:
            guard case .result(let result) = BasicCalculator.classify(demo.command) else {
                throw GlacierRuntimeError.unavailable("The calculation could not be completed.")
            }
            return result
        case .symbol:
            let corpus = try CharacterCorpus.bundled()
            guard case .character(let entry)? = corpus.identify("U+2014") else {
                throw GlacierRuntimeError.unavailable("The symbol example is unavailable.")
            }
            return "\(entry.glyph)\n\(entry.name) · \(entry.codePoint)"
        }
    }
}
