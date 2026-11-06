import AppKit
import Observation
import OmniCore

// The Settings window's state (H20, C111–C116). Each pane reads a small
// observable model; every change is applied as it is made, through the
// closure its owner installs, and a failed write shows in place as
// `Not saved · retry` (C113). Facts are plain values (C114).

public enum OmniSettingsPane: String, CaseIterable, Sendable {
    case general
    case models
    case clipboard
    case tools
    case shortcuts

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .models: "cpu"
        case .clipboard: "list.clipboard"
        case .tools: "wrench.and.screwdriver"
        case .shortcuts: "keyboard"
        }
    }
}

/// A popup entry. `value == nil` is the row's Default or None.
public struct OmniSettingsChoice: Hashable, Sendable, Identifiable {
    public let value: String?
    public let label: String
    /// Asked in place before the change applies (a billed API route).
    public let confirmation: String?

    public init(value: String?, label: String, confirmation: String? = nil) {
        self.value = value
        self.label = label
        self.confirmation = confirmation
    }

    public var id: String { value ?? "" }
}

public enum OmniSettingsWrite: Equatable, Sendable {
    case idle
    case saving
    case failed
}

/// Runs writes one at a time, in order, so a quick second change never races
/// the first to the store.
@MainActor final class OmniSettingsWriteQueue {
    private var tail: Task<Void, Never>?

    func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    func drain() async { await tail?.value }
}

// MARK: General

@MainActor @Observable
public final class OmniGeneralSettings {
    /// The host is a launch agent; this is a fact, not a switch.
    public var openAtLogin: String
    public var notifications: String
    public var notificationsOff: Bool
    public private(set) var appearance: OmniAppearance
    public private(set) var appearanceWrite: OmniSettingsWrite = .idle
    @ObservationIgnored public var onAppearance: ((OmniAppearance) throws -> Void)?
    @ObservationIgnored public var onOpenNotificationSettings: (() -> Void)?

    public init(openAtLogin: String, notifications: String, notificationsOff: Bool, appearance: OmniAppearance) {
        self.openAtLogin = openAtLogin
        self.notifications = notifications
        self.notificationsOff = notificationsOff
        self.appearance = appearance
    }

    public func setAppearance(_ value: OmniAppearance) {
        appearance = value
        do {
            try onAppearance?(value)
            appearanceWrite = .idle
        } catch {
            appearanceWrite = .failed
        }
    }

    public func openNotificationSettings() { onOpenNotificationSettings?() }
}

// MARK: Models

public struct OmniModelRow: Identifiable, Equatable, Sendable {
    public let token: String
    /// nil follows the policy default.
    public var model: String?
    /// Only meaningful with a model: a saved fallback needs a saved main.
    public var fallback: String?
    /// What Default resolves to, for the row's tooltip.
    public let defaultDetail: String
    public let models: [OmniSettingsChoice]
    public let fallbacks: [OmniSettingsChoice]
    public var write: OmniSettingsWrite

    public init(token: String, model: String?, fallback: String?, defaultDetail: String,
                models: [OmniSettingsChoice], fallbacks: [OmniSettingsChoice], write: OmniSettingsWrite = .idle) {
        self.token = token
        self.model = model
        self.fallback = fallback
        self.defaultDetail = defaultDetail
        self.models = models
        self.fallbacks = fallbacks
        self.write = write
    }

    public var id: String { token }
}

@MainActor @Observable
public final class OmniModelSettings {
    /// Shown instead of the groups when no provider runtime is configured.
    public var notice: String?
    public var defaultModel: String
    public var defaultFallback: String
    /// Commands whose policy default differs from the common one (`/stance`).
    public var defaultExceptions: String?
    public private(set) var rows: [OmniModelRow]
    public var deterministicTokens: [String]
    public var ephemeralChoices: [OmniSettingsChoice]
    public private(set) var ephemeralModel: String?
    public private(set) var ephemeralWrite: OmniSettingsWrite = .idle
    /// Writes one command's route; throws when it was not saved.
    @ObservationIgnored public var onRouteChange: ((_ token: String, _ model: String?, _ fallback: String?) async throws -> Void)?
    @ObservationIgnored public var onEphemeralChange: ((String?) throws -> Void)?
    @ObservationIgnored private let queue = OmniSettingsWriteQueue()

    public init(notice: String? = nil, defaultModel: String = "", defaultFallback: String = "", defaultExceptions: String? = nil,
                rows: [OmniModelRow] = [], deterministicTokens: [String] = [],
                ephemeralChoices: [OmniSettingsChoice] = [], ephemeralModel: String? = nil) {
        self.notice = notice
        self.defaultModel = defaultModel
        self.defaultFallback = defaultFallback
        self.defaultExceptions = defaultExceptions
        self.rows = rows
        self.deterministicTokens = deterministicTokens
        self.ephemeralChoices = ephemeralChoices
        self.ephemeralModel = ephemeralModel
    }

    public func row(_ token: String) -> OmniModelRow? { rows.first { $0.token == token } }

    /// Choosing Default clears the fallback too: none is saved without a main.
    public func setModel(_ model: String?, for token: String) {
        guard let current = row(token) else { return }
        apply(token, model: model, fallback: model == nil ? nil : current.fallback)
    }

    public func setFallback(_ fallback: String?, for token: String) {
        guard let current = row(token), current.model != nil else { return }
        apply(token, model: current.model, fallback: fallback)
    }

    public func retry(_ token: String) {
        guard let current = row(token) else { return }
        apply(token, model: current.model, fallback: current.fallback)
    }

    public func setEphemeralModel(_ model: String?) {
        ephemeralModel = model
        do {
            try onEphemeralChange?(model)
            ephemeralWrite = .idle
        } catch {
            ephemeralWrite = .failed
        }
    }

    /// Shows the stored choice without writing it again.
    public func setEphemeralSelection(_ model: String?) { ephemeralModel = model }

    /// Replaces the rows after a reload. A row still saving or not saved
    /// keeps what the user chose, so a retry or a queued write sends that,
    /// never the stored value it replaced.
    public func replaceRows(_ next: [OmniModelRow]) {
        let pending = Dictionary(rows.filter { $0.write != .idle }.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
        rows = next.map { row in
            guard let local = pending[row.token] else { return row }
            var row = row
            row.model = local.model
            row.fallback = local.fallback
            row.write = local.write
            return row
        }
    }

    /// Completes once every queued write has finished (tests, close).
    public func drainWrites() async { await queue.drain() }

    private func apply(_ token: String, model: String?, fallback: String?) {
        mutate(token) {
            $0.model = model
            $0.fallback = fallback
            $0.write = .saving
        }
        // Strong on purpose: closing the window must not drop a queued write.
        queue.enqueue { [self] in
            do {
                try await onRouteChange?(token, model, fallback)
                // A newer choice for the row is queued behind this one.
                if row(token)?.model == model, row(token)?.fallback == fallback { mutate(token) { $0.write = .idle } }
            } catch {
                mutate(token) { $0.write = .failed }
            }
        }
    }

    private func mutate(_ token: String, _ change: (inout OmniModelRow) -> Void) {
        guard let index = rows.firstIndex(where: { $0.token == token }) else { return }
        change(&rows[index])
    }
}

// MARK: Clipboard

public enum OmniClipboardSetting: Hashable, Sendable {
    case capture
    case keepFor
    case clearHistory
    case clearCollected
    case pasteMode
    case batchSeparator
}

/// What the clipboard history service reports; nil fields are unavailable.
public struct OmniClipboardHistoryState: Equatable, Sendable {
    public var capture: Bool
    public var retentionHours: Int
    public var itemCount: Int
    public var usedBytes: Int?

    public init(capture: Bool, retentionHours: Int, itemCount: Int, usedBytes: Int?) {
        self.capture = capture
        self.retentionHours = retentionHours
        self.itemCount = itemCount
        self.usedBytes = usedBytes
    }
}

/// The host's clipboard services, injected so this module never links them.
public struct OmniClipboardSettingsHost {
    public var retentionChoices: [Int]
    public var state: @MainActor () async -> OmniClipboardHistoryState?
    public var setCapture: @MainActor (Bool) async throws -> Void
    public var setRetention: @MainActor (Int) async throws -> Void
    public var clearHistory: @MainActor () async throws -> Void
    public var collectedCount: @MainActor () -> Int?
    public var clearCollected: @MainActor () async -> Void
    /// Applies a paste preference the host consumes (Clipboard history, Collect).
    public var applyPreferences: @MainActor (OmniPreferences) -> Void

    public init(retentionChoices: [Int], state: @escaping @MainActor () async -> OmniClipboardHistoryState?,
                setCapture: @escaping @MainActor (Bool) async throws -> Void, setRetention: @escaping @MainActor (Int) async throws -> Void,
                clearHistory: @escaping @MainActor () async throws -> Void, collectedCount: @escaping @MainActor () -> Int?,
                clearCollected: @escaping @MainActor () async -> Void, applyPreferences: @escaping @MainActor (OmniPreferences) -> Void) {
        self.retentionChoices = retentionChoices
        self.state = state
        self.setCapture = setCapture
        self.setRetention = setRetention
        self.clearHistory = clearHistory
        self.collectedCount = collectedCount
        self.clearCollected = clearCollected
        self.applyPreferences = applyPreferences
    }
}

@MainActor @Observable
public final class OmniClipboardSettings {
    /// Shown in History when the history service is not running here.
    public var historyNotice: String?
    public private(set) var capture: Bool
    public private(set) var keepForHours: Int
    public var keepChoices: [Int]
    public private(set) var itemCount: Int
    public private(set) var usedBytes: Int?
    public var stashDepth: Int
    /// nil when Collect is not running here.
    public private(set) var collectedCount: Int?
    public private(set) var pasteMode: OmniPasteMode
    public private(set) var batchSeparator: OmniBatchSeparator
    public private(set) var failed: Set<OmniClipboardSetting> = []
    @ObservationIgnored public var host: OmniClipboardSettingsHost?
    @ObservationIgnored public var onPreferences: (((inout OmniPreferences) -> Void) throws -> Void)?
    @ObservationIgnored private let queue = OmniSettingsWriteQueue()

    public init(history: OmniClipboardHistoryState?, keepChoices: [Int], stashDepth: Int, collectedCount: Int?,
                pasteMode: OmniPasteMode, batchSeparator: OmniBatchSeparator) {
        historyNotice = history == nil ? "Clipboard history runs in the installed host." : nil
        capture = history?.capture ?? false
        keepForHours = history?.retentionHours ?? 36
        itemCount = history?.itemCount ?? 0
        usedBytes = history?.usedBytes
        self.keepChoices = keepChoices
        self.stashDepth = stashDepth
        self.collectedCount = collectedCount
        self.pasteMode = pasteMode
        self.batchSeparator = batchSeparator
    }

    /// `12 · 1.4 MB`.
    public var itemsKept: String {
        guard let usedBytes else { return "\(itemCount)" }
        return "\(itemCount) · " + ByteCountFormatter.string(fromByteCount: Int64(usedBytes), countStyle: .file)
    }

    public static func keepLabel(_ hours: Int) -> String {
        if hours % 24 == 0 { return hours == 24 ? "1 day" : "\(hours / 24) days" }
        return "\(hours) hours"
    }

    public func setCapture(_ on: Bool) {
        capture = on
        run(.capture) { host in try await host.setCapture(on) }
    }

    public func setKeepFor(_ hours: Int) {
        keepForHours = hours
        run(.keepFor) { host in try await host.setRetention(hours) }
    }

    public func clearHistory() {
        run(.clearHistory) { host in try await host.clearHistory() }
    }

    public func clearCollected() {
        run(.clearCollected) { host in await host.clearCollected() }
    }

    public func setPasteMode(_ mode: OmniPasteMode) {
        pasteMode = mode
        savePreference(.pasteMode) { $0.pasteMode = mode }
    }

    public func setBatchSeparator(_ separator: OmniBatchSeparator) {
        batchSeparator = separator
        savePreference(.batchSeparator) { $0.batchSeparator = separator }
    }

    /// Re-reads the services (after a write, and when the pane opens).
    public func refresh() async {
        guard let host else { return }
        if let state = await host.state() {
            historyNotice = nil
            capture = state.capture
            keepForHours = state.retentionHours
            itemCount = state.itemCount
            usedBytes = state.usedBytes
        }
        collectedCount = host.collectedCount()
    }

    public func drainWrites() async { await queue.drain() }

    private func run(_ setting: OmniClipboardSetting, _ work: @escaping @MainActor (OmniClipboardSettingsHost) async throws -> Void) {
        guard let host else { return }
        queue.enqueue { [weak self] in
            do {
                try await work(host)
                self?.failed.remove(setting)
            } catch {
                self?.failed.insert(setting)
            }
            await self?.refresh()
        }
    }

    private func savePreference(_ setting: OmniClipboardSetting, _ change: @escaping (inout OmniPreferences) -> Void) {
        do {
            try onPreferences?(change)
            failed.remove(setting)
        } catch {
            failed.insert(setting)
        }
    }
}

// MARK: Tools

@MainActor @Observable
public final class OmniToolSettings {
    public private(set) var skinTone: OmniSkinTone
    public private(set) var skinToneWrite: OmniSettingsWrite = .idle
    public private(set) var weatherUnits: OmniWeatherUnits
    public private(set) var weatherUnitsWrite: OmniSettingsWrite = .idle
    public private(set) var recallSheetPath: String
    public private(set) var recallWrite: OmniSettingsWrite = .idle
    /// `Set`, `Not set`, or `Unknown` when pron could not be asked.
    public var forvoKey: String
    public var merriamWebsterKey: String
    public var pronConfigPath: String
    @ObservationIgnored public var onSkinTone: ((OmniSkinTone) throws -> Void)?
    @ObservationIgnored public var onWeatherUnits: ((OmniWeatherUnits) throws -> Void)?
    /// Asks for a sheet and saves it; returns the chosen path.
    @ObservationIgnored public var onChooseRecallSheet: (() throws -> String?)?
    @ObservationIgnored public var onOpenPronConfig: (() -> Void)?

    public init(skinTone: OmniSkinTone, recallSheetPath: String, forvoKey: String, merriamWebsterKey: String,
                pronConfigPath: String, weatherUnits: OmniWeatherUnits = .followSystem) {
        self.skinTone = skinTone
        self.weatherUnits = weatherUnits
        self.recallSheetPath = recallSheetPath
        self.forvoKey = forvoKey
        self.merriamWebsterKey = merriamWebsterKey
        self.pronConfigPath = pronConfigPath
    }

    public func setSkinTone(_ tone: OmniSkinTone) {
        skinTone = tone
        do {
            try onSkinTone?(tone)
            skinToneWrite = .idle
        } catch {
            skinToneWrite = .failed
        }
    }

    public func setWeatherUnits(_ units: OmniWeatherUnits) {
        weatherUnits = units
        do {
            try onWeatherUnits?(units)
            weatherUnitsWrite = .idle
        } catch {
            weatherUnitsWrite = .failed
        }
    }

    public func chooseRecallSheet() {
        do {
            guard let path = try onChooseRecallSheet?() else { return }
            recallSheetPath = path
            recallWrite = .idle
        } catch {
            recallWrite = .failed
        }
    }

    public func openPronConfig() { onOpenPronConfig?() }
}

// MARK: Shortcuts

@MainActor @Observable
public final class OmniShortcutSettings {
    public var manifestPath: String?
    /// The Hyper overlay's own view, pinned and read-only, at its natural size.
    @ObservationIgnored public var makeOverlayView: (() -> NSView)?
    /// That view's natural size, so the form can size the picture before drawing it.
    public var overlaySize: NSSize
    @ObservationIgnored public var onEdit: (() -> Void)?

    public init(manifestPath: String?, overlaySize: NSSize = .zero, makeOverlayView: (() -> NSView)? = nil) {
        self.manifestPath = manifestPath
        self.overlaySize = overlaySize
        self.makeOverlayView = makeOverlayView
    }

    public func edit() { onEdit?() }
}

/// Every pane's model, built by the window's owner.
@MainActor
public struct OmniSettingsModel {
    public let general: OmniGeneralSettings
    public let models: OmniModelSettings
    public let clipboard: OmniClipboardSettings
    public let tools: OmniToolSettings
    public let shortcuts: OmniShortcutSettings

    public init(general: OmniGeneralSettings, models: OmniModelSettings, clipboard: OmniClipboardSettings,
                tools: OmniToolSettings, shortcuts: OmniShortcutSettings) {
        self.general = general
        self.models = models
        self.clipboard = clipboard
        self.tools = tools
        self.shortcuts = shortcuts
    }
}
