import Foundation
import GlacierConfiguration

public enum ModuleKind: String, Codable, Sendable {
    case launcher, ephemeralTool, durableCommand, capture, clipboard, nativeUtility, settings
}

public enum ModuleNetworkRequirement: Sendable {
    case none, network, remoteAI
}

/// One stable action, independently routed from the factory that implements it.
/// Multiple actions may share a module ID, so disabling a module closes every route.
public struct ModuleDescriptor: Sendable, Equatable {
    public let id: String
    public let moduleID: String
    public let title: String
    public let kind: ModuleKind
    public let typedAliases: [String]
    public let slashTokens: [String]
    public let hasShortcut: Bool
    public let networkRequirement: ModuleNetworkRequirement
    public let modelCommandID: String?

    public init(id: String, moduleID: String, title: String, kind: ModuleKind,
                typedAliases: [String] = [], slashTokens: [String] = [],
                hasShortcut: Bool = false, networkRequirement: ModuleNetworkRequirement = .none, modelCommandID: String? = nil) {
        self.id = id
        self.moduleID = moduleID
        self.title = title
        self.kind = kind
        self.typedAliases = typedAliases
        self.slashTokens = slashTokens
        self.hasShortcut = hasShortcut
        self.networkRequirement = networkRequirement
        self.modelCommandID = modelCommandID
    }
}

public enum ModuleRegistryError: Error, Equatable, Sendable {
    case duplicateID(String)
    case duplicateTypedAlias(String)
    case duplicateSlashToken(String)
    case invalidDescriptor(String)
}

public enum ModuleRouteStatus: Equatable, Sendable {
    case available
    case disabledModule
    case unavailable(String)
    case unbound
    case disabledShortcut
    case unregisteredShortcut
    case conflictingShortcut
    case unknown
}

public struct ModuleResolution: Equatable, Sendable {
    public let actionID: String?
    public let status: ModuleRouteStatus

    public init(actionID: String?, status: ModuleRouteStatus) {
        self.actionID = actionID
        self.status = status
    }
}

public struct ModuleHelpEntry: Sendable, Equatable {
    public let descriptor: ModuleDescriptor
    public let status: ModuleRouteStatus
    /// Only a chord confirmed by the registration adapter is shown.
    public let registeredChord: GlacierShortcutChord?
}

public struct ModuleRegistry: Sendable {
    public let descriptors: [ModuleDescriptor]
    private let byID: [String: ModuleDescriptor]
    private let typed: [String: String]
    private let slash: [String: String]

    public init(descriptors: [ModuleDescriptor]) throws {
        var ids: [String: ModuleDescriptor] = [:]
        var typedRoutes: [String: String] = [:]
        var slashRoutes: [String: String] = [:]
        for descriptor in descriptors {
            guard !descriptor.id.isEmpty, !descriptor.moduleID.isEmpty,
                  !descriptor.title.isEmpty else {
                throw ModuleRegistryError.invalidDescriptor(descriptor.id)
            }
            guard ids.updateValue(descriptor, forKey: descriptor.id) == nil else {
                throw ModuleRegistryError.duplicateID(descriptor.id)
            }
            for alias in descriptor.typedAliases {
                let key = alias.lowercased()
                guard !key.isEmpty, key == alias, !key.contains(where: \.isWhitespace) else {
                    throw ModuleRegistryError.invalidDescriptor(descriptor.id)
                }
                guard typedRoutes.updateValue(descriptor.id, forKey: key) == nil else {
                    throw ModuleRegistryError.duplicateTypedAlias(key)
                }
            }
            for token in descriptor.slashTokens {
                let key = token.lowercased()
                guard key.hasPrefix("/"), key.count > 1, key == token,
                      !key.contains(where: \.isWhitespace) else {
                    throw ModuleRegistryError.invalidDescriptor(descriptor.id)
                }
                guard slashRoutes.updateValue(descriptor.id, forKey: key) == nil else {
                    throw ModuleRegistryError.duplicateSlashToken(key)
                }
            }
        }
        self.descriptors = descriptors
        self.byID = ids
        self.typed = typedRoutes
        self.slash = slashRoutes
    }

    public func descriptor(for actionID: String) -> ModuleDescriptor? { byID[actionID] }

    /// Exact whole-field Tab aliases only; the caller still owns Enter semantics.
    public func resolveTyped(_ text: String, settings: GlacierSettings,
                             unavailable: [String: String] = [:]) -> ModuleResolution {
        resolve(id: typed[text.lowercased()], settings: settings, unavailable: unavailable)
    }

    /// Accepts a slash atom, not its payload. Parsing the command line remains the pad's job.
    public func resolveSlash(_ token: String, settings: GlacierSettings,
                             unavailable: [String: String] = [:]) -> ModuleResolution {
        resolve(id: slash[token.lowercased()], settings: settings, unavailable: unavailable)
    }

    public func resolveAction(_ actionID: String, settings: GlacierSettings,
                              unavailable: [String: String] = [:]) -> ModuleResolution {
        resolve(id: actionID, settings: settings, unavailable: unavailable)
    }

    public func shortcutState(for actionID: String, settings: GlacierSettings,
                              registered: Set<String> = [], unavailable: [String: String] = [:]) -> ModuleResolution {
        guard let descriptor = byID[actionID] else { return .init(actionID: nil, status: .unknown) }
        let eligibility = resolve(id: actionID, settings: settings, unavailable: unavailable)
        guard eligibility.status == .available else { return eligibility }
        guard descriptor.hasShortcut else { return .init(actionID: actionID, status: .unbound) }
        let shortcut = settings.shortcuts[actionID] ?? GlacierShortcutSettings()
        guard shortcut.enabled else { return .init(actionID: actionID, status: .disabledShortcut) }
        guard let chord = shortcut.chord else { return .init(actionID: actionID, status: .unbound) }
        if shortcutConflicts(settings: settings, unavailable: unavailable)[chord] != nil {
            return .init(actionID: actionID, status: .conflictingShortcut)
        }
        guard registered.contains(actionID) else {
            return .init(actionID: actionID, status: .unregisteredShortcut)
        }
        return .init(actionID: actionID, status: .available)
    }

    public func resolveShortcut(_ chord: GlacierShortcutChord, settings: GlacierSettings,
                                registered: Set<String>, unavailable: [String: String] = [:]) -> ModuleResolution {
        let matches = descriptors.filter { $0.hasShortcut && settings.shortcuts[$0.id]?.enabled == true
            && settings.shortcuts[$0.id]?.chord == chord }
        guard !matches.isEmpty else { return .init(actionID: nil, status: .unbound) }
        let eligible = matches.filter {
            resolve(id: $0.id, settings: settings, unavailable: unavailable).status == .available
        }
        guard eligible.count <= 1 else { return .init(actionID: nil, status: .conflictingShortcut) }
        guard let selected = eligible.first ?? (matches.count == 1 ? matches[0] : nil) else {
            return .init(actionID: nil, status: .unbound)
        }
        return shortcutState(for: selected.id, settings: settings,
                             registered: registered, unavailable: unavailable)
    }

    /// Only effective actions conflict during registration. Inactive modules retain settings
    /// without reserving a global chord; enabling one may surface a new conflict.
    public func shortcutConflicts(settings: GlacierSettings,
                                  unavailable: [String: String] = [:]) -> [GlacierShortcutChord: [String]] {
        var grouped: [GlacierShortcutChord: [String]] = [:]
        for descriptor in descriptors where descriptor.hasShortcut {
            guard let shortcut = settings.shortcuts[descriptor.id], shortcut.enabled,
                  let chord = shortcut.chord,
                  resolve(id: descriptor.id, settings: settings, unavailable: unavailable).status == .available else { continue }
            grouped[chord, default: []].append(descriptor.id)
        }
        return grouped.filter { $0.value.count > 1 }
    }

    public func helpEntries(settings: GlacierSettings, registeredShortcuts: Set<String> = [],
                            unavailable: [String: String] = [:], includeDisabled: Bool = false) -> [ModuleHelpEntry] {
        descriptors.compactMap { descriptor in
            let route = resolve(id: descriptor.id, settings: settings, unavailable: unavailable)
            guard includeDisabled || route.status == .available else { return nil }
            let chord: GlacierShortcutChord?
            if shortcutState(for: descriptor.id, settings: settings,
                             registered: registeredShortcuts, unavailable: unavailable).status == .available {
                chord = settings.shortcuts[descriptor.id]?.chord
            } else {
                chord = nil
            }
            return ModuleHelpEntry(descriptor: descriptor, status: route.status, registeredChord: chord)
        }
    }

    private func resolve(id: String?, settings: GlacierSettings,
                         unavailable: [String: String]) -> ModuleResolution {
        guard let id, let descriptor = byID[id] else { return .init(actionID: nil, status: .unknown) }
        if settings.modules[descriptor.moduleID]?.enabled == false {
            return .init(actionID: id, status: .disabledModule)
        }
        if let reason = unavailable[id] ?? unavailable[descriptor.moduleID] {
            return .init(actionID: id, status: .unavailable(reason))
        }
        switch descriptor.networkRequirement {
        case .none: break
        case .network where settings.ai.offline:
            return .init(actionID: id, status: .unavailable("Offline mode"))
        case .remoteAI where settings.ai.paused:
            return .init(actionID: id, status: .unavailable("AI paused"))
        case .remoteAI where settings.ai.offline:
            return .init(actionID: id, status: .unavailable("Offline mode"))
        default: break
        }
        return .init(actionID: id, status: .available)
    }
}
