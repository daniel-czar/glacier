import AppKit
import Foundation
import GlacierConfiguration
import GlacierConnections
import GlacierModuleKit
import GlacierPlatform
import HyperOverlayCore
import OmniAdapters
import OmniCore
import OmniModels
import Testing
@testable import GlacierRuntime

private final class OnboardingTestSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]
    private var writes = 0
    func insert(_ secret: String, account: UUID) throws { lock.withLock { values[account] = secret; writes += 1 } }
    func read(account: UUID) throws -> String {
        try lock.withLock {
            guard let value = values[account] else { throw ConnectionError.missingCredential }
            return value
        }
    }
    func remove(account: UUID) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
    var insertions: Int { lock.withLock { writes } }
}

private actor OnboardingTestNetwork: ConnectionNetworkTransport {
    private(set) var calls: [URLRequest] = []
    var status = 200
    func exchange(_ request: URLRequest) async throws -> ModelHTTPExchange {
        calls.append(request)
        return .init(statusCode: status, body: Data())
    }
    func stream(_ request: URLRequest) async throws -> ModelHTTPByteStream {
        Issue.record("Onboarding must never generate model output")
        throw CancellationError()
    }
    func count() -> Int { calls.count }
    func lastMethod() -> String? { calls.last?.httpMethod }
}

@MainActor private final class OnboardingTestHost: GlacierOnboardingHost {
    var composition: GlacierComposition?
    var preview = false
    var onboardingIsActive = true
    var launchAtLogin = false
    var activateIntents: [Bool] = []
    var modelSelections: [String] = []
    var beforeConnectionChange: (() async -> Void)?
    var beforeSettingsChange: (() async -> Void)?
    var beforeSettingsCommit: (() async -> Void)?
    var beforeModelCommit: (() async -> Void)?

    init(composition: GlacierComposition) { self.composition = composition }
    func change(activateShortcuts: Bool, authorizeCommit: @escaping @Sendable () throws -> Void,
                _ transform: @escaping @Sendable (inout GlacierSettings) throws -> Void) -> Task<Bool, Never> {
        activateIntents.append(activateShortcuts)
        return Task {
            guard let composition else { return false }
            await beforeSettingsChange?()
            do {
                var candidate = composition.snapshot.read()
                try transform(&candidate)
                await beforeSettingsCommit?()
                let prepared = candidate
                let next = try await composition.settings.update(authorizeCommit: authorizeCommit) { $0 = prepared }
                await composition.applyRuntimePolicy(next)
                return true
            } catch { return false }
        }
    }
    func setLaunchAtLogin(_ enabled: Bool) { launchAtLogin = enabled }
    func beginConnectionChange() async { await beforeConnectionChange?() }
    func endConnectionChange() async {}
    func refreshConnections() async throws {}
    func selectModel(_ id: String, for command: String?, authorizeCommit: @Sendable () throws -> Void) async throws {
        await beforeModelCommit?()
        try authorizeCommit()
        modelSelections.append(id)
        composition?.snapshot.setProfiles([.init(commandID: "answer.quick", savedProfileID: id)])
    }
}

@MainActor private struct OnboardingFixture {
    let root: URL
    let host: OnboardingTestHost
    let secrets: OnboardingTestSecrets
    let network: OnboardingTestNetwork
    let actions: GlacierOnboardingLiveActions

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-onboarding-integration-" + UUID().uuidString).resolvingSymlinksInPath()
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let paths = try GlacierPaths(home: home, supportOverride: root.appendingPathComponent("Glacier"))
        let secrets = OnboardingTestSecrets()
        let network = OnboardingTestNetwork()
        let composition = try await GlacierComposition.make(paths: paths, home: home, hostActions: GlacierHostActions(), applicationRoots: [],
            network: network, secrets: secrets, platform: RecordingPlatformAdapter(),
            fileEffect: { _, _ in throw CancellationError() })
        let host = OnboardingTestHost(composition: composition)
        let effects = GlacierOnboardingPlatformEffects(accessibilityTrusted: { false },
            openAccessibilitySettings: { Issue.record("No real permission request in integration fixtures") },
            chooseRoots: { nil })
        let actions = GlacierOnboardingLiveActions(host: host, effects: effects, network: network)
        actions.beginSession()
        return .init(root: root, host: host, secrets: secrets, network: network, actions: actions)
    }

    func close() async {
        actions.endSession()
        if let composition = host.composition { _ = await composition.service.shutdown() }
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite(.serialized) struct OnboardingIntegrationTests {
    @Test @MainActor func savingAConnectionConfiguresItsExistingOwnersWithoutTestingIt() async throws {
        let f = try await OnboardingFixture.make()
        do {
            let initial = try await f.actions.snapshot()
            let id = ProviderRuntimeCatalog.cerebrasFastLowProfileID
            #expect(initial.modelChoices.contains { $0.id == id && $0.provider == .cerebras })
            let endpoint = try #require(initial.connectionEndpoints[.cerebras])
            try await f.actions.saveConnection(provider: .cerebras, modelProfileID: id,
                                               expectedEndpoint: endpoint, apiKey: "synthetic-onboarding-key")
            let saved = try await f.actions.snapshot()
            #expect(saved.connectionSavedProviders.contains(.cerebras))
            #expect(saved.selectedModelProfileID == id)
            #expect(f.host.modelSelections == [id])
            #expect(f.secrets.insertions == 1)
            #expect(await f.network.count() == 0)
            let composition = try #require(f.host.composition)
            try await composition.connections.setModelSelector(profileID: id, modelSelector: "fixture-model-v2")
            let withOverride = try await f.actions.snapshot()
            #expect(withOverride.modelChoices.first(where: { $0.id == id })?.label.contains("fixture-model-v2") == true)
            #expect(!composition.snapshot.automaticRequests("tool.express"))
            #expect(!String(decoding: try Data(contentsOf: composition.connections.fileURL), as: UTF8.self).contains("synthetic-onboarding-key"))

            let checked = try await f.actions.testConnection(provider: .cerebras)
            #expect(checked.contains("HTTP 200"))
            #expect(checked.contains("does not test a generated answer"))
            #expect(await f.network.count() == 1)
            #expect(await f.network.lastMethod() == "GET")
            try await composition.connections.setEnabled(false, for: ConnectionProvider.cerebras.connectionID)
            let disabled = try await f.actions.snapshot()
            #expect(disabled.selectedModelProfileID == nil)
            #expect(!disabled.connectionSavedProviders.contains(.cerebras))
        } catch { await f.close(); throw error }
        await f.close()
    }

    @Test @MainActor func aChangedDisclosedEndpointCannotReceiveANewKey() async throws {
        let f = try await OnboardingFixture.make()
        do {
            let seen = try await f.actions.snapshot()
            let endpoint = try #require(seen.connectionEndpoints[.cerebras])
            let composition = try #require(f.host.composition)
            try await composition.connections.setEndpoint(URL(string: "https://changed.example/v1")!, for: ConnectionProvider.cerebras.connectionID)
            await #expect(throws: ConnectionError.originApprovalRequired) {
                try await f.actions.saveConnection(provider: .cerebras,
                    modelProfileID: ProviderRuntimeCatalog.cerebrasFastLowProfileID,
                    expectedEndpoint: endpoint, apiKey: "synthetic-new-key")
            }
            #expect(f.secrets.insertions == 0)
            #expect(f.host.modelSelections.isEmpty)
            #expect(await f.network.count() == 0)
        } catch { await f.close(); throw error }
        await f.close()
    }

    @Test @MainActor func closingTheSessionStopsLaterConnectionStages() async throws {
        let f = try await OnboardingFixture.make()
        do {
            let initial = try await f.actions.snapshot()
            let endpoint = try #require(initial.connectionEndpoints[.cerebras])
            f.host.beforeConnectionChange = { f.actions.endSession() }
            await #expect(throws: (any Error).self) {
                try await f.actions.saveConnection(provider: .cerebras,
                    modelProfileID: ProviderRuntimeCatalog.cerebrasFastLowProfileID,
                    expectedEndpoint: endpoint, apiKey: "synthetic-cancelled-key")
            }
            #expect(f.secrets.insertions == 0)
            #expect(f.host.modelSelections.isEmpty)
            #expect(await f.network.count() == 0)
        } catch { await f.close(); throw error }
        await f.close()
    }

    @Test @MainActor func realLocalEnginesNeedNoConnectionAndHonorDisabledModules() async throws {
        let f = try await OnboardingFixture.make()
        do {
            #expect(try await f.actions.runDemo(.date).contains("23 Nov 2026"))
            #expect(try await f.actions.runDemo(.calculation) == "57.6")
            #expect(try await f.actions.runDemo(.symbol).contains("U+2014"))
            #expect(await f.network.count() == 0)
            #expect(f.secrets.insertions == 0)
            let composition = try #require(f.host.composition)
            let settings = try await composition.settings.update { $0.modules["span"] = .init(enabled: false) }
            await composition.applyRuntimePolicy(settings)
            await #expect(throws: (any Error).self) { try await f.actions.runDemo(.date) }
        } catch { await f.close(); throw error }
        await f.close()
    }

    @Test @MainActor func aQueuedOptInCannotCommitAfterClosingAndReopeningSetup() async throws {
        let f = try await OnboardingFixture.make()
        do {
            var resume: CheckedContinuation<Void, Never>?
            f.host.beforeSettingsCommit = { await withCheckedContinuation { resume = $0 } }
            let pending = Task { try await f.actions.setClipboardEnabled(true) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while resume == nil, ContinuousClock.now < deadline { await Task.yield() }
            guard resume != nil else {
                pending.cancel()
                throw CancellationError()
            }
            f.actions.endSession()
            f.actions.beginSession()
            resume?.resume()
            await #expect(throws: (any Error).self) { try await pending.value }
            let composition = try #require(f.host.composition)
            #expect(!composition.snapshot.read().clipboard.captureEnabled)
            #expect(!(await composition.settings.snapshot()).clipboard.captureEnabled)
        } catch { await f.close(); throw error }
        await f.close()
    }

    @Test @MainActor func previewRefusesPlatformAndCredentialWritesButKeepsLocalTools() async throws {
        let f = try await OnboardingFixture.make()
        do {
            f.host.preview = true
            #expect(try await f.actions.snapshot().isPreview)
            await #expect(throws: (any Error).self) { try await f.actions.saveShortcut(.optionSpace) }
            await #expect(throws: (any Error).self) { try await f.actions.setClipboardEnabled(true) }
            await #expect(throws: (any Error).self) { try await f.actions.setLaunchAtLogin(true) }
            await #expect(throws: (any Error).self) { try await f.actions.testConnection(provider: .cerebras) }
            #expect(f.host.activateIntents.isEmpty)
            #expect(!f.host.launchAtLogin)
            #expect(f.secrets.insertions == 0)
            #expect(await f.network.count() == 0)
            #expect(try await f.actions.runDemo(.calculation) == "57.6")
        } catch { await f.close(); throw error }
        await f.close()
    }

    @Test @MainActor func revokedAuthorizationAtActorCommitLeavesKeysAndSettingsUntouched() async throws {
        let f = try await OnboardingFixture.make()
        do {
            let composition = try #require(f.host.composition)
            let endpoint = try #require(try await f.actions.snapshot().connectionEndpoints[.cerebras])
            await #expect(throws: CancellationError.self) {
                try await composition.connections.saveKey("synthetic-revoked-key", for: ConnectionProvider.cerebras.connectionID,
                    expectedEndpoint: endpoint, authorizeCommit: { throw CancellationError() })
            }
            #expect(f.secrets.insertions == 0)
            let before = await composition.settings.snapshot()
            await #expect(throws: CancellationError.self) {
                try await composition.settings.update(authorizeCommit: { throw CancellationError() }) { $0.clipboard.captureEnabled = true }
            }
            #expect(await composition.settings.snapshot() == before)
            #expect(!FileManager.default.fileExists(atPath: composition.paths.settings.path))
            #expect(await f.network.count() == 0)
        } catch { await f.close(); throw error }
        await f.close()
    }

    @Test @MainActor func closingBeforeTheModelRouteCommitDoesNotSelectItsProfile() async throws {
        let f = try await OnboardingFixture.make()
        do {
            let endpoint = try #require(try await f.actions.snapshot().connectionEndpoints[.cerebras])
            var resume: CheckedContinuation<Void, Never>?
            f.host.beforeModelCommit = { await withCheckedContinuation { resume = $0 } }
            let pending = Task {
                try await f.actions.saveConnection(provider: .cerebras, modelProfileID: ProviderRuntimeCatalog.cerebrasFastLowProfileID,
                    expectedEndpoint: endpoint, apiKey: "synthetic-saved-before-close")
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while resume == nil, ContinuousClock.now < deadline { await Task.yield() }
            guard let resume else { pending.cancel(); throw CancellationError() }
            f.actions.endSession()
            resume.resume()
            await #expect(throws: (any Error).self) { try await pending.value }
            #expect(f.secrets.insertions == 1, "The earlier explicit atomic key save already committed")
            #expect(f.host.modelSelections.isEmpty)
            #expect(await f.network.count() == 0)
        } catch { await f.close(); throw error }
        await f.close()
    }
}

@MainActor private final class OnboardingRegistrar: ShortcutRegistering {
    var bindings: [OverlayHotKeyBinding] = []
    func replace(with bindings: [OverlayHotKeyBinding]) throws { self.bindings = bindings }
    func stop() -> [String] { bindings = []; return [] }
}

@MainActor @Test func onboardingShortcutActivationIsTransactionalFromTheFirstBinding() async throws {
    let registrar = OnboardingRegistrar()
    let controller = ShortcutController(settings: .init(), registrar: registrar)
    var candidate = GlacierSettings()
    candidate.shortcuts["launcher.open"] = .init(enabled: true, chord: GlacierOnboardingShortcutChoice.optionSpaceChord)
    struct WriteFailure: Error {}
    await #expect(throws: WriteFailure.self) {
        try await controller.apply(candidate, registry: .builtIn, activate: true) { _ in throw WriteFailure() }
    }
    #expect(registrar.bindings.isEmpty)
    #expect(controller.registeredActionIDs.isEmpty)
    try await controller.apply(candidate, registry: .builtIn, activate: true) { _ in }
    #expect(controller.registeredActionIDs == ["launcher.open"])
    #expect(registrar.bindings.first?.chord.keyCode == 49)

    let previewRegistrar = OnboardingRegistrar()
    let preview = ShortcutController(settings: .init(), safePreview: true, registrar: previewRegistrar)
    await #expect(throws: ShortcutControllerError.self) {
        try await preview.apply(candidate, registry: .builtIn, activate: true) { _ in Issue.record("Preview must not save an activation") }
    }
    #expect(previewRegistrar.bindings.isEmpty)
}
