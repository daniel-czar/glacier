import Foundation
import Testing
import GlacierConfiguration
import GlacierConnections
@testable import GlacierRuntime

@MainActor private final class OnboardingFakeActions: GlacierOnboardingActions {
    var state = GlacierOnboardingSnapshot(modelChoices: [
        .init(id: "cerebras-current", label: "Current Cerebras model", provider: .cerebras, modelSelector: "current")
    ], connectionEndpoints: [.cerebras: ConnectionProvider.cerebras.defaultEndpoint])
    var savedShortcuts = 0
    var connectionSaves = 0
    var connectionTests = 0
    var demoRuns = 0
    var failShortcut = false
    var failLogin = false
    var submittedKey: String?
    var demoContinuation: CheckedContinuation<String, Error>?
    var holdDemo = false
    var holdRoots = false
    var rootsContinuation: CheckedContinuation<Void, Never>?
    var clipboardWrites = 0
    var loginWrites = 0
    var pickerResults: [[GlacierSourceRoot]] = []
    var begunSessions = 0
    var endedSessions = 0

    func beginSession() { begunSessions += 1 }
    func endSession() { endedSessions += 1 }

    func snapshot() async throws -> GlacierOnboardingSnapshot { state }
    func saveShortcut(_ choice: GlacierOnboardingShortcutChoice) async throws {
        savedShortcuts += 1
        if failShortcut { throw TestFailure.conflict }
        state.shortcut = choice.chord
    }
    func openAccessibilitySettings() {}
    func checkAccessibility() async throws -> Bool {
        state.accessibilityTrusted = true
        return true
    }
    func saveConnection(provider: ConnectionProvider, modelProfileID: String,
                        expectedEndpoint: URL, apiKey: String?) async throws {
        connectionSaves += 1
        guard expectedEndpoint == state.connectionEndpoints[provider] else { throw TestFailure.conflict }
        submittedKey = apiKey
        state.connectionSavedProviders.insert(provider)
        state.selectedModelProfileID = modelProfileID
    }
    func testConnection(provider: ConnectionProvider) async throws -> String {
        connectionTests += 1
        return "Provider responded to the explicit GET."
    }
    func chooseSourceRoots() async throws -> [GlacierSourceRoot]? {
        pickerResults.isEmpty ? nil : pickerResults.removeFirst()
    }
    func saveSourceRoots(_ roots: [GlacierSourceRoot]) async throws {
        if holdRoots {
            await withCheckedContinuation { continuation in rootsContinuation = continuation }
        }
        state.sourceRoots = roots
    }
    func setClipboardEnabled(_ enabled: Bool) async throws {
        clipboardWrites += 1
        state.clipboardEnabled = enabled
    }
    func setLaunchAtLogin(_ enabled: Bool) async throws {
        loginWrites += 1
        if failLogin { throw TestFailure.login }
        state.launchAtLogin = enabled
    }
    func runDemo(_ demo: GlacierOnboardingDemo) async throws -> String {
        demoRuns += 1
        if holdDemo {
            return try await withCheckedThrowingContinuation { continuation in
                demoContinuation = continuation
            }
        }
        return "Real local result"
    }
}

private enum TestFailure: Error, LocalizedError {
    case conflict, login
    var errorDescription: String? {
        switch self {
        case .conflict: "Shortcut conflict"
        case .login: "Login item could not be enabled"
        }
    }
}

@Test @MainActor func onboardingQuickStartDoesNotConfigureOrInventResult() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-onboarding-model-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let actions = OnboardingFakeActions()
    let model = GlacierOnboardingModel(store: .init(supportDirectory: directory), actions: actions)
    await model.open()
    await model.tryFirst()
    #expect(model.step == .ready)
    #expect(!model.completed)
    #expect(model.demoResult == nil)
    #expect(actions.savedShortcuts == 0)
    #expect(actions.connectionSaves == 0)
    #expect(actions.demoRuns == 0)
    await model.finish()
    #expect(model.completed)
    #expect(actions.demoRuns == 0)
    #expect(try GlacierOnboardingStore(supportDirectory: directory).load()?.completed == true)
}

@Test @MainActor func onboardingShortcutConflictAndMenuSkipPreserveExistingChoice() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-onboarding-model-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let actions = OnboardingFakeActions()
    let old = try GlacierShortcutChord(keyCode: 2, modifiers: [.command])
    actions.state.shortcut = old
    let model = GlacierOnboardingModel(store: .init(supportDirectory: directory), actions: actions)
    await model.open()
    await model.next()
    model.shortcutChoice = .optionSpace
    actions.failShortcut = true
    await model.next()
    #expect(model.step == .shortcut)
    #expect(model.errorMessage == "Shortcut conflict")
    #expect(model.snapshot.shortcut == old)
    model.shortcutChoice = .menuBarOnly
    await model.next()
    #expect(model.step == .selectedText)
    #expect(actions.state.shortcut == old)
    #expect(actions.savedShortcuts == 1)
}

@Test @MainActor func onboardingProviderSaveAndCheckAreDistinctAndSecretIsTransient() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-onboarding-model-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let actions = OnboardingFakeActions()
    let model = GlacierOnboardingModel(store: .init(supportDirectory: directory), actions: actions)
    await model.open()
    await model.next()
    await model.skipCurrent()
    await model.checkAccessibility()
    #expect(model.snapshot.accessibilityTrusted)
    await model.next()
    #expect(model.step == .intelligence)
    actions.state.connectionEndpoints = [:]
    await model.refresh()
    model.apiKey = "no-destination"
    await model.saveConnection()
    #expect(actions.connectionSaves == 0)
    #expect(model.apiKey.isEmpty)
    #expect(model.errorMessage?.contains("destination") == true)
    actions.state.connectionEndpoints = [.cerebras: ConnectionProvider.cerebras.defaultEndpoint]
    await model.refresh()
    model.apiKey = "synthetic-test-secret"
    await model.saveConnection()
    #expect(model.apiKey.isEmpty)
    #expect(actions.submittedKey == "synthetic-test-secret")
    #expect(actions.connectionSaves == 1)
    #expect(actions.connectionTests == 0)
    #expect(model.connectionTestResult == nil)
    await model.testConnection()
    #expect(actions.connectionTests == 1)
    #expect(model.connectionTestResult == "Provider responded to the explicit GET.")
    model.apiKey = "discard-me"
    await model.next()
    #expect(model.apiKey.isEmpty)
    let text = try String(contentsOf: GlacierOnboardingStore(supportDirectory: directory).url, encoding: .utf8)
    #expect(!text.contains("synthetic-test-secret"))
}

@Test @MainActor func onboardingDataPartialFailureKeepsCommittedSnapshotVisible() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-onboarding-model-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let actions = OnboardingFakeActions()
    actions.failLogin = true
    let model = GlacierOnboardingModel(store: .init(supportDirectory: directory), actions: actions)
    await model.open()
    await model.next()
    await model.skipCurrent()
    await model.skipCurrent()
    await model.skipCurrent()
    #expect(model.step == .yourMac)
    model.selectedRoots = [.init(path: "/tmp/synthetic-onboarding-folder")]
    model.clipboardEnabled = true
    model.launchAtLogin = true
    await model.next()
    #expect(model.step == .yourMac)
    #expect(model.snapshot.sourceRoots == model.selectedRoots)
    #expect(model.snapshot.clipboardEnabled)
    #expect(!model.snapshot.launchAtLogin)
    #expect(model.errorMessage == "Login item could not be enabled")
    actions.failLogin = false
    await model.next()
    #expect(model.step == .ready)
    #expect(model.snapshot.launchAtLogin)
}

@Test @MainActor func onboardingCloseDropsInFlightDemoAndReopensFromState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-onboarding-model-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let actions = OnboardingFakeActions()
    actions.holdDemo = true
    let model = GlacierOnboardingModel(store: .init(supportDirectory: directory), actions: actions)
    await model.open()
    await model.tryFirst()
    let task = Task { await model.runDemo(.date) }
    for _ in 0..<100 where actions.demoContinuation == nil { await Task.yield() }
    #expect(actions.demoContinuation != nil)
    model.close()
    #expect(actions.endedSessions == 1)
    actions.demoContinuation?.resume(returning: "late result")
    await task.value
    #expect(model.demoResult == nil)
    await model.open()
    #expect(actions.begunSessions == 2)
    #expect(model.step == .ready)
    #expect(!model.completed)
}

@Test @MainActor func onboardingCloseStopsLaterSequentialDataWrites() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-onboarding-model-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let actions = OnboardingFakeActions()
    actions.holdRoots = true
    let model = GlacierOnboardingModel(store: .init(supportDirectory: directory), actions: actions)
    await model.open()
    await model.next()
    await model.skipCurrent()
    await model.skipCurrent()
    await model.skipCurrent()
    model.selectedRoots = [.init(path: "/tmp/synthetic-onboarding-folder")]
    model.clipboardEnabled = true
    model.launchAtLogin = true
    let task = Task { await model.next() }
    for _ in 0..<100 where actions.rootsContinuation == nil { await Task.yield() }
    #expect(actions.rootsContinuation != nil)
    model.close()
    actions.rootsContinuation?.resume()
    await task.value
    #expect(actions.clipboardWrites == 0)
    #expect(actions.loginWrites == 0)
    #expect(try GlacierOnboardingStore(supportDirectory: directory).load()?.currentStep == .yourMac)
}

@Test @MainActor func onboardingFolderPickerMergesSeparateVisitsBeforeSave() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-onboarding-model-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let actions = OnboardingFakeActions()
    let first = GlacierSourceRoot(path: "/tmp/synthetic-onboarding-A")
    let second = GlacierSourceRoot(path: "/tmp/synthetic-onboarding-B")
    actions.pickerResults = [[first], [second, first]]
    let model = GlacierOnboardingModel(store: .init(supportDirectory: directory), actions: actions)
    await model.open()
    await model.next()
    await model.skipCurrent()
    await model.skipCurrent()
    await model.skipCurrent()
    #expect(model.step == .yourMac)
    await model.chooseSourceRoots()
    #expect(model.selectedRoots == [first])
    await model.chooseSourceRoots()
    #expect(model.selectedRoots == [first, second])
    #expect(actions.state.sourceRoots.isEmpty)
    await model.next()
    #expect(model.step == .ready)
    #expect(actions.state.sourceRoots == [first, second])
}
