import Foundation
import OmniCore

public enum ModelProviderRegistryError: Error, Sendable, Equatable, CustomStringConvertible {
    case duplicateIdentity(String)
    case unknownConnection(String)
    case unknownProfile(String)
    case unknownCommand(String)
    case missingDriver(ModelDriverID)
    case invalidSettings(String)

    public var description: String {
        switch self {
        case .duplicateIdentity(let id): "duplicate provider identity \(id)"
        case .unknownConnection(let id): "unknown connection \(id)"
        case .unknownProfile(let id): "unknown model profile \(id)"
        case .unknownCommand(let id): "\(id) has no policy 6.0.0 command"
        case .missingDriver(let id): "no driver registered for \(id.rawValue)"
        case .invalidSettings(let reason): "Invalid provider settings: \(reason)"
        }
    }
}

/// Immutable registration data: drivers, base connections, base profiles and
/// qualification evidence. Construction scans no credential and launches
/// nothing. Settings are applied per lookup so a saved change is visible after
/// restart without invoking a model.
public struct ModelProviderRegistry: Sendable {
    public let policy: ModelProviderPolicy
    public let connections: [ModelConnectionProfile]
    public let profiles: [ModelProfile]
    public private(set) var qualifications: [ModelQualification]
    public let drivers: [ModelDriverID: any ModelProviderDriver]
    /// Fixture registries bind every connection to a synthetic driver and mark
    /// each attempt as a fixture. They never claim live readiness.
    public let isFixture: Bool

    public init(
        policy: ModelProviderPolicy = .v6,
        connections: [ModelConnectionProfile] = ProviderRuntimeCatalog.connections,
        profiles: [ModelProfile] = ProviderRuntimeCatalog.profiles,
        qualifications: [ModelQualification] = [],
        drivers: [any ModelProviderDriver],
        isFixture: Bool = false
    ) throws {
        var seen: Set<String> = []
        for connection in connections {
            guard seen.insert("connection:\(connection.id)").inserted else { throw ModelProviderRegistryError.duplicateIdentity(connection.id) }
        }
        for profile in profiles {
            guard seen.insert("profile:\(profile.id)").inserted else { throw ModelProviderRegistryError.duplicateIdentity(profile.id) }
            guard connections.contains(where: { $0.id == profile.connectionID }) else {
                throw ModelProviderRegistryError.unknownConnection(profile.connectionID)
            }
        }
        var byDriver: [ModelDriverID: any ModelProviderDriver] = [:]
        for driver in drivers {
            guard byDriver[driver.driverID] == nil else { throw ModelProviderRegistryError.duplicateIdentity(driver.driverID.rawValue) }
            byDriver[driver.driverID] = driver
        }
        self.policy = policy
        self.connections = connections.sorted { $0.id < $1.id }
        self.profiles = profiles.sorted { $0.id < $1.id }
        self.qualifications = qualifications
        self.drivers = byDriver
        self.isFixture = isFixture
    }

    public func baseConnection(_ id: String) -> ModelConnectionProfile? { connections.first { $0.id == id } }
    public func baseProfile(_ id: String) -> ModelProfile? {
        profiles.first { $0.id == id }
            ?? profiles.first { $0.id == ProviderRuntimeCatalog.canonicalProfileID(id) }
    }
    public func driver(for connection: ModelConnectionProfile) -> (any ModelProviderDriver)? { drivers[connection.driverID] }

    /// Effective connection with saved settings applied. Absent settings mean
    /// the catalogue default.
    public func effectiveConnection(_ id: String, settings: ProviderRuntimeSettings) -> ModelConnectionProfile? {
        guard let base = baseConnection(id) else { return nil }
        guard let saved = settings.connection(id) else { return base }
        return base.with(
            enabled: saved.enabled,
            endpoint: saved.endpoint.map { Optional($0) } ?? nil,
            credentialReference: saved.credentialReference.map { Optional($0) } ?? nil,
            cliProfile: saved.cliProfile.map { Optional($0) } ?? nil,
            revision: saved.revision
        )
    }

    public func effectiveProfile(_ id: String, settings: ProviderRuntimeSettings) -> ModelProfile? {
        guard let base = baseProfile(id) else { return nil }
        guard let saved = settings.profile(id) else { return base }
        return base.with(modelSelector: saved.modelSelector, options: saved.options, revision: base.revision + saved.revision)
    }

    public func effectiveProfiles(settings: ProviderRuntimeSettings) -> [ModelProfile] {
        profiles.compactMap { effectiveProfile($0.id, settings: settings) }
    }

    public func effectiveConnections(settings: ProviderRuntimeSettings) -> [ModelConnectionProfile] {
        connections.compactMap { effectiveConnection($0.id, settings: settings) }
    }

    public func isQualified(commandID: String, profile: ModelProfile, outputShape: ModelOutputShape) -> Bool {
        qualification(commandID: commandID, profile: profile, outputShape: outputShape) != nil
    }

    public func qualification(commandID: String, profile: ModelProfile, outputShape: ModelOutputShape) -> ModelQualification? {
        qualifications.first { qualification in
            qualification.commandID == commandID
                && qualification.outputShape == outputShape
                && qualificationMatches(qualification, profile: profile)
        }
    }

    /// Same drivers, catalogue and policy with a different evidence set.
    public func replacingQualifications(_ qualifications: [ModelQualification]) -> ModelProviderRegistry {
        // Identities were validated at construction; only evidence changes.
        var copy = self
        copy.qualifications = qualifications
        return copy
    }

    public func qualifiedCommandIDs(for profile: ModelProfile) -> Set<String> {
        Set(qualifications.filter { qualificationMatches($0, profile: profile) }.map(\.commandID))
    }

    private func qualificationMatches(_ qualification: ModelQualification, profile: ModelProfile) -> Bool {
        if qualification.profileID == profile.id {
            return qualification.qualificationBinding == profile.qualificationBinding
        }
        // Existing local-capable evidence remains attached to its recorded ID.
        // Its selector/options were identical to local-fast, so it can cover the
        // merged profile without rewriting the qualification ledger.
        guard profile.id == ProviderRuntimeCatalog.localFastProfileID,
              qualification.profileID == ProviderRuntimeCatalog.localCapableProfileID else { return false }
        let legacyBinding = "\(ProviderRuntimeCatalog.localCapableProfileID)@\(profile.revision)|\(profile.modelSelector)|\(profile.options.stableDescription)"
        return qualification.qualificationBinding == legacyBinding
    }

    /// Selectors are written into owned CLI configuration files; they must not
    /// carry quoting, newlines or table syntax.
    public static func isValidSelector(_ selector: String) -> Bool {
        guard let first = selector.unicodeScalars.first, CharacterSet.alphanumerics.contains(first), selector.count <= 128 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:/-"))
        return selector.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Rejects unknown identities, stale policy versions and contradictory
    /// routes before a save. Display labels are never accepted here.
    public func validate(_ settings: ProviderRuntimeSettings) throws {
        guard settings.schemaVersion == ProviderRuntimeSettings.schemaVersion else {
            throw ModelProviderRegistryError.invalidSettings("schema version \(settings.schemaVersion) is not \(ProviderRuntimeSettings.schemaVersion)")
        }
        guard settings.policyVersion == policy.version else {
            throw ModelProviderRegistryError.invalidSettings("policy version \(settings.policyVersion) does not match \(policy.version)")
        }
        guard !settings.configurationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, settings.revision > 0 else {
            throw ModelProviderRegistryError.invalidSettings("configuration identity is required")
        }
        var seen: Set<String> = []
        for connection in settings.connections {
            guard baseConnection(connection.connectionID) != nil else { throw ModelProviderRegistryError.unknownConnection(connection.connectionID) }
            guard seen.insert("c:\(connection.connectionID)").inserted else { throw ModelProviderRegistryError.invalidSettings("duplicate connection \(connection.connectionID)") }
            guard connection.revision > 0 else { throw ModelProviderRegistryError.invalidSettings("connection revision must be positive") }
            if let endpoint = connection.endpoint {
                guard let scheme = endpoint.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                    throw ModelProviderRegistryError.invalidSettings("connection \(connection.connectionID) endpoint must be http(s)")
                }
            }
        }
        for profile in settings.profiles {
            guard baseProfile(profile.profileID) != nil else { throw ModelProviderRegistryError.unknownProfile(profile.profileID) }
            guard seen.insert("p:\(profile.profileID)").inserted else { throw ModelProviderRegistryError.invalidSettings("duplicate profile \(profile.profileID)") }
            if let selector = profile.modelSelector {
                guard Self.isValidSelector(selector) else {
                    throw ModelProviderRegistryError.invalidSettings("profile \(profile.profileID) model selector must match [A-Za-z0-9._:/-]")
                }
            }
            if let options = profile.options {
                if let tokens = options.maximumOutputTokens, tokens <= 0 { throw ModelProviderRegistryError.invalidSettings("profile \(profile.profileID) output limit must be positive") }
                if let temperature = options.temperature, !(0...2).contains(temperature) { throw ModelProviderRegistryError.invalidSettings("profile \(profile.profileID) temperature out of range") }
            }
        }
        var labels: Set<String> = []
        for profile in effectiveProfiles(settings: settings) {
            guard labels.insert(profile.displayName).inserted else {
                throw ModelProviderRegistryError.invalidSettings("model labels must be unique: \(profile.displayName)")
            }
        }
        for command in settings.commands {
            guard let commandPolicy = policy.command(named: command.commandID) else { throw ModelProviderRegistryError.unknownCommand(command.commandID) }
            guard seen.insert("cmd:\(command.commandID)").inserted else { throw ModelProviderRegistryError.invalidSettings("duplicate command \(command.commandID)") }
            let issue = settings.migrationIssue(for: command.commandID)
            if issue != nil, command.savedProfileID != nil || !command.savedFallbackProfileIDs.isEmpty || command.savedAPITransition != nil {
                throw ModelProviderRegistryError.invalidSettings("\(command.commandID) still carries a migration issue; resolve it by an explicit route save")
            }
            var routeProfiles: [String] = []
            if let saved = command.savedProfileID {
                guard let profile = effectiveProfile(saved, settings: settings) else { throw ModelProviderRegistryError.unknownProfile(saved) }
                guard commandPolicy.requiredCapabilities.isSubset(of: profile.capabilities) else {
                    throw ModelProviderRegistryError.invalidSettings("\(saved) lacks capabilities required by \(command.commandID)")
                }
                routeProfiles.append(profile.id)
            } else if !command.savedFallbackProfileIDs.isEmpty {
                throw ModelProviderRegistryError.invalidSettings("\(command.commandID) saves fallbacks without a saved main profile")
            }
            for fallback in command.savedFallbackProfileIDs {
                guard let profile = effectiveProfile(fallback, settings: settings) else { throw ModelProviderRegistryError.unknownProfile(fallback) }
                guard commandPolicy.requiredCapabilities.isSubset(of: profile.capabilities) else {
                    throw ModelProviderRegistryError.invalidSettings("\(fallback) lacks capabilities required by \(command.commandID)")
                }
                routeProfiles.append(profile.id)
            }
            guard Set(routeProfiles).count == routeProfiles.count else {
                throw ModelProviderRegistryError.invalidSettings("\(command.commandID) repeats a profile in its saved route")
            }
            if let permission = command.savedAPITransition {
                guard let connection = baseConnection(permission.connectionID) else { throw ModelProviderRegistryError.unknownConnection(permission.connectionID) }
                guard connection.authRoute.isOptionalAPIAlternative else {
                    throw ModelProviderRegistryError.invalidSettings("API transition permission may only name an optional API connection")
                }
                guard case .saved(let revision) = permission.scope, revision > 0 else {
                    throw ModelProviderRegistryError.invalidSettings("saved API transition must carry a saved settings revision")
                }
                let permittedProfiles = routeProfiles.compactMap { baseProfile($0) }.filter { $0.connectionID == permission.connectionID }
                guard !permittedProfiles.isEmpty else {
                    throw ModelProviderRegistryError.invalidSettings("API transition permission names a connection absent from \(command.commandID)'s saved route")
                }
            }
            // Any saved route onto an API alternative needs its explicit permission.
            for profileID in routeProfiles {
                guard let profile = baseProfile(profileID), let connection = baseConnection(profile.connectionID) else { continue }
                if connection.authRoute.isOptionalAPIAlternative, command.savedAPITransition?.connectionID != connection.id {
                    throw ModelProviderRegistryError.invalidSettings("\(profileID) requires an explicit API route permission for \(command.commandID)")
                }
            }
        }
        for issue in settings.migrationIssues {
            guard seen.insert("issue:\(issue.commandID)").inserted else { throw ModelProviderRegistryError.invalidSettings("duplicate migration issue \(issue.commandID)") }
        }
    }
}
