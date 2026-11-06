import Foundation
import Observation
import GlacierConfiguration
import GlacierConnections

public enum GlacierOnboardingStep: String, Codable, CaseIterable, Sendable {
    case welcome, shortcut, selectedText, intelligence, yourMac, ready

    public var next: Self? {
        guard let index = Self.allCases.firstIndex(of: self), index + 1 < Self.allCases.count else { return nil }
        return Self.allCases[index + 1]
    }

    public var previous: Self? {
        guard let index = Self.allCases.firstIndex(of: self), index > 0 else { return nil }
        return Self.allCases[index - 1]
    }
}

public enum GlacierOnboardingShortcutChoice: Equatable, Sendable {
    case menuBarOnly
    case optionSpace
    case custom(GlacierShortcutChord)
    case hyper(GlacierShortcutChord)

    public static var optionSpaceChord: GlacierShortcutChord {
        // Carbon virtual key code 49 is Space.
        try! GlacierShortcutChord(keyCode: 49, modifiers: [.option])
    }

    public var chord: GlacierShortcutChord? {
        switch self {
        case .menuBarOnly: nil
        case .optionSpace: Self.optionSpaceChord
        case .custom(let chord), .hyper(let chord): chord
        }
    }
}

public enum GlacierOnboardingDemo: String, CaseIterable, Sendable {
    case date, calculation, symbol

    public var title: String {
        switch self {
        case .date: "A date"
        case .calculation: "A calculation"
        case .symbol: "A symbol"
        }
    }

    public var command: String {
        switch self {
        case .date: "/span 3 weeks after 2 November 2026"
        case .calculation: "48 * 1.2"
        case .symbol: "/char em dash"
        }
    }
}

public struct GlacierOnboardingModelChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let provider: ConnectionProvider
    public let modelSelector: String

    public init(id: String, label: String, provider: ConnectionProvider, modelSelector: String) {
        self.id = id
        self.label = label
        self.provider = provider
        self.modelSelector = modelSelector
    }
}

/// Read from production stores and current registry. Never a persisted onboarding preference.
public struct GlacierOnboardingSnapshot: Equatable, Sendable {
    public var isPreview: Bool
    public var shortcut: GlacierShortcutChord?
    public var accessibilityTrusted: Bool
    public var modelChoices: [GlacierOnboardingModelChoice]
    public var connectionEndpoints: [ConnectionProvider: URL]
    public var selectedModelProfileID: String?
    public var sourceRoots: [GlacierSourceRoot]
    public var clipboardEnabled: Bool
    public var launchAtLogin: Bool
    public var connectionSavedProviders: Set<ConnectionProvider>

    public init(isPreview: Bool = false, shortcut: GlacierShortcutChord? = nil,
                accessibilityTrusted: Bool = false, modelChoices: [GlacierOnboardingModelChoice] = [],
                connectionEndpoints: [ConnectionProvider: URL] = [:],
                selectedModelProfileID: String? = nil, sourceRoots: [GlacierSourceRoot] = [],
                clipboardEnabled: Bool = false, launchAtLogin: Bool = false,
                connectionSavedProviders: Set<ConnectionProvider> = []) {
        self.isPreview = isPreview
        self.shortcut = shortcut
        self.accessibilityTrusted = accessibilityTrusted
        self.modelChoices = modelChoices
        self.connectionEndpoints = connectionEndpoints
        self.selectedModelProfileID = selectedModelProfileID
        self.sourceRoots = sourceRoots
        self.clipboardEnabled = clipboardEnabled
        self.launchAtLogin = launchAtLogin
        self.connectionSavedProviders = connectionSavedProviders
    }
}

/// Effects stay with the host. A test GET and a local demo are explicit distinct actions.
@MainActor public protocol GlacierOnboardingActions {
    func beginSession()
    func endSession()
    func snapshot() async throws -> GlacierOnboardingSnapshot
    func saveShortcut(_ choice: GlacierOnboardingShortcutChoice) async throws
    func openAccessibilitySettings()
    func checkAccessibility() async throws -> Bool
    func saveConnection(provider: ConnectionProvider, modelProfileID: String,
                        expectedEndpoint: URL, apiKey: String?) async throws
    func testConnection(provider: ConnectionProvider) async throws -> String
    func chooseSourceRoots() async throws -> [GlacierSourceRoot]?
    func saveSourceRoots(_ roots: [GlacierSourceRoot]) async throws
    func setClipboardEnabled(_ enabled: Bool) async throws
    func setLaunchAtLogin(_ enabled: Bool) async throws
    func runDemo(_ demo: GlacierOnboardingDemo) async throws -> String
}

public extension GlacierOnboardingActions {
    func beginSession() {}
    func endSession() {}
}

public enum GlacierOnboardingModelError: Error, LocalizedError {
    case unavailableInPreview
    case chooseModel
    case endpointUnavailable
    case saveNotConfirmed

    public var errorDescription: String? {
        switch self {
        case .unavailableInPreview: "This choice is unavailable in preview mode."
        case .chooseModel: "Choose a model from the current connection list."
        case .endpointUnavailable: "The connection destination is unavailable. Review it in Settings before saving a key."
        case .saveNotConfirmed: "The change could not be confirmed in Glacier's settings."
        }
    }
}

@MainActor @Observable public final class GlacierOnboardingModel {
    public private(set) var step: GlacierOnboardingStep = .welcome
    public private(set) var completed = false
    public private(set) var isOpen = false
    public private(set) var isBusy = false
    public private(set) var snapshot = GlacierOnboardingSnapshot()
    public private(set) var errorMessage: String?
    public private(set) var demoResult: String?
    public private(set) var connectionTestResult: String?

    public var apiKey = ""
    public var shortcutChoice: GlacierOnboardingShortcutChoice = .menuBarOnly
    public var connectionProvider: ConnectionProvider = .cerebras {
        didSet {
            if connectionProvider != oldValue {
                modelProfileID = snapshot.modelChoices.first(where: { $0.provider == connectionProvider })?.id
                connectionTestResult = nil
                apiKey = ""
            }
        }
    }
    public var modelProfileID: String?
    public var selectedRoots: [GlacierSourceRoot] = []
    public var clipboardEnabled = false
    public var launchAtLogin = false

    private let store: GlacierOnboardingStore
    private let actions: any GlacierOnboardingActions
    private var generation = 0

    public init(store: GlacierOnboardingStore, actions: any GlacierOnboardingActions) {
        self.store = store
        self.actions = actions
    }

    public func open() async {
        generation += 1
        let token = generation
        actions.beginSession()
        isOpen = true
        isBusy = true
        errorMessage = nil
        apiKey = ""
        demoResult = nil
        connectionTestResult = nil
        do {
            let saved = try store.load() ?? GlacierOnboardingState()
            let fresh = try await actions.snapshot()
            guard active(token) else { return }
            try store.save(saved)
            step = saved.currentStep
            completed = saved.completed
            apply(fresh)
        } catch {
            if active(token) { errorMessage = error.localizedDescription }
        }
        if active(token) { isBusy = false }
    }

    public func close() {
        generation += 1
        actions.endSession()
        isOpen = false
        isBusy = false
        apiKey = ""
        demoResult = nil
        connectionTestResult = nil
    }

    public func refresh() async {
        guard let token = begin() else { return }
        do {
            let fresh = try await actions.snapshot()
            guard active(token) else { return }
            apply(fresh)
        } catch {
            if active(token) { errorMessage = error.localizedDescription }
        }
        end(token)
    }

    public func tryFirst() async {
        guard isOpen, !isBusy, step == .welcome else { return }
        move(to: .ready, completed: false)
    }

    public func back() async {
        guard isOpen, !isBusy, let previous = step.previous else { return }
        move(to: previous, completed: false)
    }

    public func skipCurrent() async {
        guard isOpen, !isBusy, let next = step.next else { return }
        move(to: next, completed: false)
    }

    public func next() async {
        guard isOpen, !isBusy, let next = step.next else { return }
        if step == .shortcut, let chord = shortcutChoice.chord {
            let choice = shortcutChoice
            guard !snapshot.isPreview, let token = begin() else {
                errorMessage = GlacierOnboardingModelError.unavailableInPreview.localizedDescription
                return
            }
            do {
                try await actions.saveShortcut(choice)
                guard active(token) else { return }
                let fresh = try await actions.snapshot()
                guard active(token) else { return }
                apply(fresh, preserveDrafts: true)
                guard fresh.shortcut == chord else { throw GlacierOnboardingModelError.saveNotConfirmed }
                try persist(step: next, completed: false)
            } catch {
                if active(token) { errorMessage = error.localizedDescription }
            }
            end(token)
            return
        }
        if step == .yourMac {
            await saveDataChoices(advanceTo: next)
            return
        }
        move(to: next, completed: false)
    }

    public func finish() async {
        guard isOpen, !isBusy, step == .ready else { return }
        errorMessage = nil
        move(to: .ready, completed: true)
    }

    public func openAccessibilitySettings() {
        guard isOpen else { return }
        guard !snapshot.isPreview else {
            errorMessage = GlacierOnboardingModelError.unavailableInPreview.localizedDescription
            return
        }
        actions.openAccessibilitySettings()
    }

    public func checkAccessibility() async {
        guard !snapshot.isPreview, let token = begin() else {
            errorMessage = GlacierOnboardingModelError.unavailableInPreview.localizedDescription
            return
        }
        do {
            let trusted = try await actions.checkAccessibility()
            guard active(token) else { return }
            snapshot.accessibilityTrusted = trusted
        } catch {
            if active(token) { errorMessage = error.localizedDescription }
        }
        end(token)
    }

    public func saveConnection() async {
        let submittedKey = apiKey.isEmpty ? nil : apiKey
        apiKey = ""
        let provider = connectionProvider
        guard !snapshot.isPreview, let token = begin() else {
            errorMessage = GlacierOnboardingModelError.unavailableInPreview.localizedDescription
            return
        }
        guard let id = modelProfileID,
              snapshot.modelChoices.contains(where: { $0.id == id && $0.provider == provider }) else {
            errorMessage = GlacierOnboardingModelError.chooseModel.localizedDescription
            end(token)
            return
        }
        guard let expectedEndpoint = snapshot.connectionEndpoints[provider] else {
            errorMessage = GlacierOnboardingModelError.endpointUnavailable.localizedDescription
            end(token)
            return
        }
        do {
            try await actions.saveConnection(provider: provider, modelProfileID: id,
                                             expectedEndpoint: expectedEndpoint, apiKey: submittedKey)
            guard active(token) else { return }
            let fresh = try await actions.snapshot()
            guard active(token) else { return }
            apply(fresh, preserveDrafts: true)
            guard fresh.connectionSavedProviders.contains(provider),
                  fresh.selectedModelProfileID == id else { throw GlacierOnboardingModelError.saveNotConfirmed }
            connectionTestResult = nil
        } catch {
            if active(token) {
                if let fresh = try? await actions.snapshot(), active(token) {
                    apply(fresh, preserveDrafts: true)
                }
                errorMessage = error.localizedDescription
            }
        }
        end(token)
    }

    public func testConnection() async {
        let provider = connectionProvider
        guard !snapshot.isPreview, let token = begin() else {
            errorMessage = GlacierOnboardingModelError.unavailableInPreview.localizedDescription
            return
        }
        connectionTestResult = nil
        do {
            let result = try await actions.testConnection(provider: provider)
            guard active(token) else { return }
            if connectionProvider == provider { connectionTestResult = result }
        } catch {
            if active(token) { errorMessage = error.localizedDescription }
        }
        end(token)
    }

    public func chooseSourceRoots() async {
        guard !snapshot.isPreview, let token = begin() else {
            errorMessage = GlacierOnboardingModelError.unavailableInPreview.localizedDescription
            return
        }
        do {
            let roots = try await actions.chooseSourceRoots()
            guard active(token) else { return }
            if let roots {
                var seen = Set(selectedRoots.map(Self.canonicalRootPath))
                for root in roots {
                    if seen.insert(Self.canonicalRootPath(root)).inserted {
                        selectedRoots.append(root)
                    }
                }
            }
        } catch {
            if active(token) { errorMessage = error.localizedDescription }
        }
        end(token)
    }

    public func saveDataChoices() async { await saveDataChoices(advanceTo: nil) }

    public func runDemo(_ demo: GlacierOnboardingDemo) async {
        guard let token = begin() else { return }
        demoResult = nil
        do {
            let result = try await actions.runDemo(demo)
            guard active(token) else { return }
            demoResult = result
        } catch {
            if active(token) { errorMessage = error.localizedDescription }
        }
        end(token)
    }

    private func saveDataChoices(advanceTo next: GlacierOnboardingStep?) async {
        guard let token = begin() else { return }
        let roots = selectedRoots
        let clipboard = clipboardEnabled
        let login = launchAtLogin
        do {
            if roots != snapshot.sourceRoots {
                guard !snapshot.isPreview else { throw GlacierOnboardingModelError.unavailableInPreview }
                try await actions.saveSourceRoots(roots)
                guard active(token) else { return }
            }
            if clipboard != snapshot.clipboardEnabled {
                guard !snapshot.isPreview else { throw GlacierOnboardingModelError.unavailableInPreview }
                try await actions.setClipboardEnabled(clipboard)
                guard active(token) else { return }
            }
            if login != snapshot.launchAtLogin {
                guard !snapshot.isPreview else { throw GlacierOnboardingModelError.unavailableInPreview }
                try await actions.setLaunchAtLogin(login)
                guard active(token) else { return }
            }
            let fresh = try await actions.snapshot()
            guard active(token) else { return }
            apply(fresh, preserveDrafts: true)
            guard fresh.sourceRoots == roots, fresh.clipboardEnabled == clipboard,
                  fresh.launchAtLogin == login else { throw GlacierOnboardingModelError.saveNotConfirmed }
            if let next { try persist(step: next, completed: false) }
        } catch {
            if active(token) {
                // Re-read after a partial save; the visible committed state stays truthful.
                if let fresh = try? await actions.snapshot(), active(token) {
                    apply(fresh, preserveDrafts: true)
                }
                errorMessage = error.localizedDescription
            }
        }
        end(token)
    }

    private func active(_ token: Int) -> Bool { isOpen && generation == token }

    private static func canonicalRootPath(_ root: GlacierSourceRoot) -> String {
        let url = URL(fileURLWithPath: root.path)
        return (try? GlacierPaths.canonicalFileURL(url).path) ?? url.standardizedFileURL.path
    }

    private func begin() -> Int? {
        guard isOpen, !isBusy else { return nil }
        errorMessage = nil
        isBusy = true
        return generation
    }

    private func end(_ token: Int) { if active(token) { isBusy = false } }

    private func move(to newStep: GlacierOnboardingStep, completed: Bool) {
        do { try persist(step: newStep, completed: completed) }
        catch { errorMessage = error.localizedDescription }
    }

    private func persist(step newStep: GlacierOnboardingStep, completed newCompleted: Bool) throws {
        try store.save(GlacierOnboardingState(currentStep: newStep, completed: newCompleted))
        if step == .intelligence && newStep != .intelligence { apiKey = "" }
        step = newStep
        completed = newCompleted
    }

    private func apply(_ fresh: GlacierOnboardingSnapshot, preserveDrafts: Bool = false) {
        snapshot = fresh
        if !preserveDrafts {
            if let chord = fresh.shortcut {
                shortcutChoice = chord == GlacierOnboardingShortcutChoice.optionSpaceChord ? .optionSpace : .custom(chord)
            } else {
                // This is a draft preset only. The binding is saved on Continue.
                shortcutChoice = fresh.isPreview ? .menuBarOnly : .optionSpace
            }
            selectedRoots = fresh.sourceRoots
            clipboardEnabled = fresh.clipboardEnabled
            launchAtLogin = fresh.launchAtLogin
            if let id = fresh.selectedModelProfileID,
               let choice = fresh.modelChoices.first(where: { $0.id == id }) {
                connectionProvider = choice.provider
                modelProfileID = id
            } else if let first = fresh.modelChoices.first {
                connectionProvider = first.provider
                modelProfileID = first.id
            } else {
                modelProfileID = nil
            }
        }
    }
}
