import AppKit
import Foundation
import GlacierConfiguration
import GlacierModuleKit
import HyperKeyOverlay
import HyperOverlayCore
import HyperOverlayRuntime

public enum ShortcutControllerError: Error, LocalizedError {
    case previewDisabled
    case duplicateChord
    case registrationFailed(String)
    case rollbackFailed

    public var errorDescription: String? {
        switch self {
        case .previewDisabled: "Global shortcuts are disabled in safe preview."
        case .duplicateChord: "Two actions use the same shortcut."
        case .registrationFailed(let detail): "Shortcut registration failed: \(detail)"
        case .rollbackFailed: "Shortcut rollback failed; restart the app before trying again."
        }
    }
}

@MainActor
public protocol ShortcutRegistering: AnyObject {
    var bindings: [OverlayHotKeyBinding] { get }
    func replace(with bindings: [OverlayHotKeyBinding]) throws
    func stop() -> [String]
}

extension HotKeyCenter: ShortcutRegistering {}

/// Owns the staged registration -> local save -> published help sequence.
/// Construction never registers a global key. `safePreview` always refuses
/// activation, even if a loaded settings file says a shortcut is enabled.
@MainActor
public final class ShortcutController {
    private let registrar: any ShortcutRegistering
    private let safePreview: Bool
    private let availability: (@MainActor (String, GlacierSettings) -> Bool)?
    private var settings: GlacierSettings
    private var authorized = false
    public private(set) var registeredActionIDs: Set<String> = []

    public convenience init(settings: GlacierSettings, safePreview: Bool = false,
                            availability: (@MainActor (String, GlacierSettings) -> Bool)? = nil,
                            onTrigger: @escaping @MainActor (String) -> Void) {
        self.init(settings: settings, safePreview: safePreview, registrar: HotKeyCenter(onTrigger: onTrigger), availability: availability)
    }

    public init(settings: GlacierSettings, safePreview: Bool = false, registrar: any ShortcutRegistering,
                availability: (@MainActor (String, GlacierSettings) -> Bool)? = nil) {
        self.availability = availability
        self.settings = settings
        self.safePreview = safePreview
        self.registrar = registrar
    }

    /// Explicit user action to turn on registration for saved shortcuts.
    public func activate(registry: ModuleRegistry, unavailable: [String: String] = [:]) throws {
        guard !safePreview else { throw ShortcutControllerError.previewDisabled }
        let desired = try bindings(settings: settings, registry: registry, unavailable: unavailable)
        let previous = registrar.bindings
        do { try registrar.replace(with: desired) }
        catch {
            let failure = String(describing: error)
            try restore(previous)
            throw ShortcutControllerError.registrationFailed(failure)
        }
        authorized = true
        registeredActionIDs = Set(desired.map(\.overlayID))
    }

    /// Saves only after every requested chord was registered. If save fails,
    /// old registrations are restored and old help labels remain published.
    public func apply(_ candidate: GlacierSettings, registry: ModuleRegistry,
                      unavailable: [String: String] = [:],
                      activate: Bool = false,
                      save: @MainActor (GlacierSettings) async throws -> Void) async throws {
        guard !activate || !safePreview else { throw ShortcutControllerError.previewDisabled }
        try candidate.validate()
        let desired = try bindings(settings: candidate, registry: registry, unavailable: unavailable)
        let oldBindings = registrar.bindings
        let registers = authorized || activate
        if registers {
            do { try registrar.replace(with: desired) }
            catch {
                let failure = String(describing: error)
                try restore(oldBindings)
                throw ShortcutControllerError.registrationFailed(failure)
            }
        }
        do { try await save(candidate) }
        catch {
            if registers {
                try restore(oldBindings)
            }
            throw error
        }
        settings = candidate
        if activate { authorized = true }
        registeredActionIDs = authorized ? Set(desired.map(\.overlayID)) : []
    }

    private func restore(_ bindings: [OverlayHotKeyBinding]) throws {
        do { try registrar.replace(with: bindings) }
        catch {
            _ = registrar.stop()
            registeredActionIDs.removeAll()
            authorized = false
            throw ShortcutControllerError.rollbackFailed
        }
    }

    public func stop() -> [String] {
        authorized = false
        registeredActionIDs.removeAll()
        return registrar.stop()
    }

    public func helpEntries(registry: ModuleRegistry, unavailable: [String: String] = [:],
                            includeDisabled: Bool = false) -> [ModuleHelpEntry] {
        registry.helpEntries(settings: settings, registeredShortcuts: registeredActionIDs,
                             unavailable: unavailable, includeDisabled: includeDisabled)
    }

    public func overlayCatalog(registry: ModuleRegistry, layout: HyperKeyboardLayout) -> HyperBindingCatalog {
        let labels = Dictionary(uniqueKeysWithValues: registry.descriptors.map { ($0.id, $0.title) })
        return HyperBindingCatalog.build(registered: registrar.bindings, file: nil, layout: layout, labels: labels)
    }

    /// The modifier group for an explicitly registered hold-to-reveal action.
    /// The caller still decides whether to install a global event monitor.
    public func holdModifierFlags(for actionID: String = "help.pin") -> NSEvent.ModifierFlags? {
        guard registeredActionIDs.contains(actionID),
              let chord = settings.shortcuts[actionID]?.chord else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for modifier in chord.modifiers {
            switch modifier {
            case .command: flags.insert(.command)
            case .option: flags.insert(.option)
            case .control: flags.insert(.control)
            case .shift: flags.insert(.shift)
            }
        }
        return flags
    }

    public func makeHelpOverlay(registry: ModuleRegistry,
                                labels: ShortcutLabelProjection = .init(),
                                padFrame: @escaping @MainActor () -> NSRect? = { nil },
                                presentsInterface: Bool = true) -> HyperKeyOverlayController {
        let escapeClaim: any HyperEscapeClaim
        if safePreview { escapeClaim = InertEscapeClaim() }
        else { escapeClaim = TransientHotKey() }
        let overlay = HyperKeyOverlayController(
            layout: labels.keyboardLayout(),
            holdModifiers: holdModifierFlags() ?? [],
            registered: { [weak self] in self?.registrar.bindings ?? [] },
            bindingsURL: nil, padFrame: padFrame,
            presentsInterface: presentsInterface,
            escapeClaim: escapeClaim
        )
        let names = Dictionary(uniqueKeysWithValues: registry.descriptors.map { ($0.id, $0.title) })
        overlay.labelOverrides = { names }
        return overlay
    }

    private func bindings(settings: GlacierSettings, registry: ModuleRegistry,
                                 unavailable: [String: String]) throws -> [OverlayHotKeyBinding] {
        guard registry.shortcutConflicts(settings: settings, unavailable: unavailable).isEmpty else { throw ShortcutControllerError.duplicateChord }
        let values: [OverlayHotKeyBinding] = registry.descriptors.compactMap { descriptor in
            guard descriptor.hasShortcut,
                  (availability?(descriptor.id, settings) ?? (registry.resolveAction(descriptor.id, settings: settings, unavailable: unavailable).status == .available)),
                  let shortcut = settings.shortcuts[descriptor.id], shortcut.enabled,
                  let chord = shortcut.chord else { return nil }
            return OverlayHotKeyBinding(overlayID: descriptor.id,
                                        chord: HotKeyChord(keyCode: UInt32(chord.keyCode),
                                                           modifiers: chord.modifiers.map { HotKeyModifier(rawValue: $0.rawValue)! }))
        }
        guard Set(values.map(\.chord)).count == values.count else { throw ShortcutControllerError.duplicateChord }
        return values
    }
}

@MainActor
private final class InertEscapeClaim: HyperEscapeClaim {
    func claim(handler: @escaping @MainActor () -> Void) -> Bool { false }
    func release() {}
}
