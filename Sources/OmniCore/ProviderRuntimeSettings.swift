import Foundation

// MARK: - Policy 6.0.0 settings document and v5 migration

public struct ModelConnectionSettings: Codable, Sendable, Equatable, Hashable {
    public let connectionID: String
    public let enabled: Bool
    public let credentialReference: ModelCredentialReference?
    public let cliProfile: ModelCLIProfileReference?
    public let endpoint: URL?
    public let revision: Int

    public init(
        connectionID: String,
        enabled: Bool,
        credentialReference: ModelCredentialReference? = nil,
        cliProfile: ModelCLIProfileReference? = nil,
        endpoint: URL? = nil,
        revision: Int = 1
    ) {
        self.connectionID = connectionID
        self.enabled = enabled
        self.credentialReference = credentialReference
        self.cliProfile = cliProfile
        self.endpoint = endpoint
        self.revision = revision
    }
}

/// Optional overrides for a configurable profile's model/options. A changed
/// selector or option produces a new revision and invalidates prior evidence.
/// Raw IDs survive until the enclosing document can resolve Local collisions.
public struct ModelProfileSettings: Codable, Sendable, Equatable, Hashable {
    public let profileID: String
    public let modelSelector: String?
    public let options: ModelGenerationOptions?
    public let revision: Int

    public init(profileID: String, modelSelector: String? = nil, options: ModelGenerationOptions? = nil, revision: Int = 1) {
        self.profileID = profileID
        self.modelSelector = modelSelector
        self.options = options
        self.revision = revision
    }
}

/// Per-command saved routing. `savedProfileID` is an explicit opt-in that
/// replaces the policy primary; `savedFallbackProfileIDs` are the only
/// fallbacks used after it. Empty means "no configured fallback". Raw IDs are
/// normalized by the document so a legacy Local main/fallback pair can merge.
public struct ModelCommandRouteSettings: Codable, Sendable, Equatable, Hashable {
    public let commandID: String
    public let offlineDefault: Bool
    public let savedProfileID: String?
    public let savedFallbackProfileIDs: [String]
    public let savedAPITransition: ModelAPITransitionPermission?

    public init(
        commandID: String,
        offlineDefault: Bool = false,
        savedProfileID: String? = nil,
        savedFallbackProfileIDs: [String] = [],
        savedAPITransition: ModelAPITransitionPermission? = nil
    ) {
        self.commandID = commandID
        self.offlineDefault = offlineDefault
        self.savedProfileID = savedProfileID
        self.savedFallbackProfileIDs = savedFallbackProfileIDs
        self.savedAPITransition = savedAPITransition
    }

    public var isDefault: Bool {
        !offlineDefault && savedProfileID == nil && savedFallbackProfileIDs.isEmpty && savedAPITransition == nil
    }
}

/// A legacy per-command entry whose exact profile/billing identity could not
/// be established. Generation for that command returns needs-configuration
/// until an explicit settings save resolves it.
public struct ModelSettingsMigrationIssue: Codable, Sendable, Equatable, Hashable {
    public let commandID: String
    public let legacyValue: String
    public let reason: String

    public init(commandID: String, legacyValue: String, reason: String) {
        self.commandID = commandID
        self.legacyValue = legacyValue
        self.reason = reason
    }
}

public struct ModelSettingsMigrationOrigin: Codable, Sendable, Equatable, Hashable {
    public let legacyPolicyVersion: String
    public let legacyConfigurationID: String
    public let legacyConfigurationVersion: Int
    public let originalBytesSHA256: String
    public let preservedRelativePath: String
    public let migratedAt: Date

    public init(legacyPolicyVersion: String, legacyConfigurationID: String, legacyConfigurationVersion: Int, originalBytesSHA256: String, preservedRelativePath: String, migratedAt: Date) {
        self.legacyPolicyVersion = legacyPolicyVersion
        self.legacyConfigurationID = legacyConfigurationID
        self.legacyConfigurationVersion = legacyConfigurationVersion
        self.originalBytesSHA256 = originalBytesSHA256
        self.preservedRelativePath = preservedRelativePath
        self.migratedAt = migratedAt
    }
}

/// The one owned settings document under policy 6.0.0. Inert data; an explicit
/// owner operation persists it. Display labels are never stored.
public struct ProviderRuntimeSettings: Codable, Sendable, Equatable {
    public static let schemaVersion = 6

    public let schemaVersion: Int
    public let policyVersion: String
    public let configurationID: String
    public let revision: Int
    public let connections: [ModelConnectionSettings]
    public let profiles: [ModelProfileSettings]
    public let commands: [ModelCommandRouteSettings]
    public let migrationIssues: [ModelSettingsMigrationIssue]
    public let migratedFrom: ModelSettingsMigrationOrigin?

    public init(
        policyVersion: String = ModelProviderPolicy.v6.version,
        configurationID: String = "default",
        revision: Int = 1,
        connections: [ModelConnectionSettings] = [],
        profiles: [ModelProfileSettings] = [],
        commands: [ModelCommandRouteSettings] = [],
        migrationIssues: [ModelSettingsMigrationIssue] = [],
        migratedFrom: ModelSettingsMigrationOrigin? = nil
    ) {
        schemaVersion = Self.schemaVersion
        self.policyVersion = policyVersion
        self.configurationID = configurationID
        self.revision = revision
        self.connections = connections.sorted { $0.connectionID < $1.connectionID }
        self.profiles = Self.canonicalProfiles(profiles)
        self.commands = Self.canonicalCommands(commands)
        self.migrationIssues = migrationIssues.sorted { $0.commandID < $1.commandID }
        self.migratedFrom = migratedFrom
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, policyVersion, configurationID, revision, connections, profiles, commands, migrationIssues, migratedFrom
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        policyVersion = try values.decode(String.self, forKey: .policyVersion)
        configurationID = try values.decode(String.self, forKey: .configurationID)
        revision = try values.decode(Int.self, forKey: .revision)
        connections = try values.decode([ModelConnectionSettings].self, forKey: .connections).sorted { $0.connectionID < $1.connectionID }
        profiles = Self.canonicalProfiles(try values.decode([ModelProfileSettings].self, forKey: .profiles))
        commands = Self.canonicalCommands(try values.decode([ModelCommandRouteSettings].self, forKey: .commands))
        migrationIssues = try values.decode([ModelSettingsMigrationIssue].self, forKey: .migrationIssues).sorted { $0.commandID < $1.commandID }
        migratedFrom = try values.decodeIfPresent(ModelSettingsMigrationOrigin.self, forKey: .migratedFrom)
    }

    private static func canonicalProfiles(_ profiles: [ModelProfileSettings]) -> [ModelProfileSettings] {
        let legacyID = ProviderRuntimeCatalog.localCapableProfileID
        let survivorID = ProviderRuntimeCatalog.localFastProfileID
        let repairPair = profiles.filter { $0.profileID == legacyID }.count == 1
            && profiles.filter { $0.profileID == survivorID }.count == 1
        return profiles.compactMap { saved in
            guard saved.profileID == legacyID else { return saved }
            if repairPair { return nil } // Explicit survivor wins regardless of input order.
            return ModelProfileSettings(profileID: survivorID, modelSelector: saved.modelSelector, options: saved.options, revision: saved.revision)
        }.sorted { $0.profileID < $1.profileID }
    }

    private static func canonicalCommands(_ commands: [ModelCommandRouteSettings]) -> [ModelCommandRouteSettings] {
        commands.map { saved in
            var originalIDs: [String] = []
            if let main = saved.savedProfileID { originalIDs.append(main) }
            originalIDs += saved.savedFallbackProfileIDs
            var retained: [String] = []
            for original in originalIDs {
                if let earlier = retained.first(where: { ProviderRuntimeCatalog.canonicalProfileID($0) == ProviderRuntimeCatalog.canonicalProfileID(original) }),
                   isLocalMergePair(earlier, original) {
                    continue
                }
                retained.append(original)
            }
            let main = saved.savedProfileID.map(ProviderRuntimeCatalog.canonicalProfileID)
            let fallbacks = retained.dropFirst(saved.savedProfileID == nil ? 0 : 1).map(ProviderRuntimeCatalog.canonicalProfileID)
            return ModelCommandRouteSettings(
                commandID: saved.commandID,
                offlineDefault: saved.offlineDefault,
                savedProfileID: main,
                savedFallbackProfileIDs: fallbacks,
                savedAPITransition: saved.savedAPITransition
            )
        }.sorted { $0.commandID < $1.commandID }
    }

    private static func isLocalMergePair(_ first: String, _ second: String) -> Bool {
        Set([first, second]) == Set([ProviderRuntimeCatalog.localCapableProfileID, ProviderRuntimeCatalog.localFastProfileID])
    }

    public func connection(_ id: String) -> ModelConnectionSettings? { connections.first { $0.connectionID == id } }
    public func profile(_ id: String) -> ModelProfileSettings? {
        let canonicalID = ProviderRuntimeCatalog.canonicalProfileID(id)
        return profiles.first { $0.profileID == canonicalID }
            ?? profiles.first { ProviderRuntimeCatalog.canonicalProfileID($0.profileID) == canonicalID }
    }
    public func command(_ id: String) -> ModelCommandRouteSettings? { commands.first { $0.commandID == id } }
    public func migrationIssue(for commandID: String) -> ModelSettingsMigrationIssue? { migrationIssues.first { $0.commandID == commandID } }

    /// Fresh-install defaults: API alternatives are visibly disabled and no
    /// command carries a subscription or API opt-in.
    public static func freshDefaults(configurationID: String = "default") -> ProviderRuntimeSettings {
        ProviderRuntimeSettings(
            configurationID: configurationID,
            revision: 1,
            connections: ProviderRuntimeCatalog.connections.map {
                ModelConnectionSettings(connectionID: $0.id, enabled: $0.enabled, credentialReference: $0.credentialReference, cliProfile: $0.cliProfile, endpoint: $0.endpoint, revision: 1)
            },
            profiles: [],
            commands: ModelProviderPolicy.v6.commandIDs.map { ModelCommandRouteSettings(commandID: $0) }
        )
    }

    public func replacing(
        revision: Int? = nil,
        connections: [ModelConnectionSettings]? = nil,
        profiles: [ModelProfileSettings]? = nil,
        commands: [ModelCommandRouteSettings]? = nil,
        migrationIssues: [ModelSettingsMigrationIssue]? = nil
    ) -> ProviderRuntimeSettings {
        ProviderRuntimeSettings(
            policyVersion: policyVersion,
            configurationID: configurationID,
            revision: revision ?? self.revision,
            connections: connections ?? self.connections,
            profiles: profiles ?? self.profiles,
            commands: commands ?? self.commands,
            migrationIssues: migrationIssues ?? self.migrationIssues,
            migratedFrom: migratedFrom
        )
    }
}

// MARK: - Pure v4/v5 -> v6 migration

public enum ProviderRuntimeSettingsMigrationError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupportedLegacyPolicy(String)

    public var description: String {
        switch self {
        case .unsupportedLegacyPolicy(let version): "legacy model settings policy \(version) cannot be migrated to 6.0.0"
        }
    }
}

/// Deterministic, side-effect-free translation of a legacy class-ladder
/// settings value into the v6 document. Absent/default-only entries receive v6
/// defaults with no subscription or API opt-in. Only an exact profile and
/// billing identity is preserved; `capable-remote` is ambiguous between
/// ChatGPT, Claude and the API alternatives and becomes a migration issue.
public enum ProviderRuntimeSettingsMigration {
    /// Legacy v5 provider IDs whose exact v6 profile identity is known.
    static let exactLegacyProviderIDs: [String: String] = [
        "cerebras:gemma-4-31b:none": ProviderRuntimeCatalog.cerebrasFastProfileID,
        "ollama:qwen3:8b:local-fast": ProviderRuntimeCatalog.localFastProfileID,
        "ollama:qwen3:8b:local-capable": ProviderRuntimeCatalog.localFastProfileID,
    ]

    public static func migrate(
        legacy: ModelSettings,
        originalBytesSHA256: String,
        preservedRelativePath: String,
        now: Date
    ) throws -> ProviderRuntimeSettings {
        guard legacy.runtimePolicyVersion == ModelRuntimePolicy.phase4V1.version
            || legacy.runtimePolicyVersion == ModelRuntimePolicy.phase5V1.version
        else { throw ProviderRuntimeSettingsMigrationError.unsupportedLegacyPolicy(legacy.runtimePolicyVersion) }

        var commands: [ModelCommandRouteSettings] = []
        var issues: [ModelSettingsMigrationIssue] = []
        for commandID in ModelProviderPolicy.v6.commandIDs {
            guard let entry = legacy.settings(for: commandID) else {
                commands.append(.init(commandID: commandID))
                continue
            }
            let outcome = translate(entry, policyVersion: legacy.runtimePolicyVersion)
            switch outcome {
            case .route(let route):
                commands.append(route)
            case .issue(let issue):
                commands.append(.init(commandID: commandID, offlineDefault: entry.offlineDefault))
                issues.append(issue)
            }
        }
        // Legacy entries for commands without a v6 policy are recorded as
        // issues rather than dropped silently.
        for entry in legacy.commandSettings where ModelProviderPolicy.v6.command(named: entry.commandID) == nil {
            issues.append(.init(commandID: entry.commandID, legacyValue: describe(entry), reason: "no policy 6.0.0 command"))
        }
        let defaults = ProviderRuntimeSettings.freshDefaults(configurationID: legacy.configurationID)
        return ProviderRuntimeSettings(
            configurationID: legacy.configurationID,
            revision: max(1, legacy.configurationVersion) + 1,
            connections: defaults.connections,
            profiles: [],
            commands: commands,
            migrationIssues: issues,
            migratedFrom: .init(
                legacyPolicyVersion: legacy.runtimePolicyVersion,
                legacyConfigurationID: legacy.configurationID,
                legacyConfigurationVersion: legacy.configurationVersion,
                originalBytesSHA256: originalBytesSHA256,
                preservedRelativePath: preservedRelativePath,
                migratedAt: now
            )
        )
    }

    enum Translation: Equatable {
        case route(ModelCommandRouteSettings)
        case issue(ModelSettingsMigrationIssue)
    }

    static func translate(_ entry: ModelCommandSettings, policyVersion: String) -> Translation {
        let classes = [entry.mainProviderClass].compactMap { $0 } + entry.fallbackProviderClasses
        let defaultOnly = classes.isEmpty && entry.enabledProviderIDs.isEmpty
        if defaultOnly {
            return .route(.init(commandID: entry.commandID, offlineDefault: entry.offlineDefault))
        }
        let legacyValue = describe(entry)
        // Any capable-remote reference is ambiguous between ChatGPT, Claude and
        // the API alternatives; it must never be guessed into a billing route.
        if classes.contains(.capableRemote) {
            return .issue(.init(commandID: entry.commandID, legacyValue: legacyValue, reason: "capable-remote does not identify ChatGPT, Claude or an API connection; choose a profile explicitly"))
        }
        var unresolved: [String] = []
        for providerID in entry.enabledProviderIDs where !providerID.hasPrefix("fixture:") && exactLegacyProviderIDs[providerID] == nil {
            unresolved.append(providerID)
        }
        if !unresolved.isEmpty {
            return .issue(.init(commandID: entry.commandID, legacyValue: legacyValue, reason: "enabled provider IDs have no exact policy 6.0.0 profile: \(unresolved.sorted().joined(separator: ", "))"))
        }
        // Remaining classes map to exactly one profile each; fast-hosted was the
        // single evaluated Cerebras gemma/none candidate under 5.0.0.
        var mapped: [String] = []
        for providerClass in classes {
            switch providerClass {
            case .fastHosted:
                guard policyVersion == ModelRuntimePolicy.phase5V1.version else {
                    return .issue(.init(commandID: entry.commandID, legacyValue: legacyValue, reason: "fast-hosted under policy 4.0.0 names no exact connection"))
                }
                mapped.append(ProviderRuntimeCatalog.cerebrasFastProfileID)
            case .localFast: mapped.append(ProviderRuntimeCatalog.localFastProfileID)
            case .localCapable: mapped.append(ProviderRuntimeCatalog.localFastProfileID)
            case .capableRemote: break
            }
        }
        // The two legacy Local classes now name one profile. Preserve order
        // while collapsing a former main/fallback pair that became identical.
        var seenProfiles: Set<String> = []
        mapped = mapped.filter { seenProfiles.insert($0).inserted }
        guard let main = mapped.first else {
            return .route(.init(commandID: entry.commandID, offlineDefault: entry.offlineDefault))
        }
        guard let policy = ModelProviderPolicy.v6.command(named: entry.commandID),
              (policy.ladder(offline: false) + policy.offlineProfileIDs).contains(main)
        else {
            return .issue(.init(commandID: entry.commandID, legacyValue: legacyValue, reason: "mapped profile \(main) is not declared for this command under policy 6.0.0"))
        }
        // A saved main equal to the v6 default is not an opt-in. Legacy classes
        // could only name the profiles mapped above, so the fallback comparison
        // ignores v6 fallbacks the legacy vocabulary had no word for (OpenRouter).
        let legacyExpressible: Set<String> = [ProviderRuntimeCatalog.cerebrasFastProfileID, ProviderRuntimeCatalog.localFastProfileID]
        let expressibleDefaultFallbacks = policy.fallbackProfileIDs.filter(legacyExpressible.contains)
        if main == policy.primaryProfileIDs.first, Array(mapped.dropFirst()) == expressibleDefaultFallbacks || mapped.count == 1 {
            return .route(.init(commandID: entry.commandID, offlineDefault: entry.offlineDefault))
        }
        return .route(.init(
            commandID: entry.commandID,
            offlineDefault: entry.offlineDefault,
            savedProfileID: main,
            savedFallbackProfileIDs: Array(mapped.dropFirst())
        ))
    }

    static func describe(_ entry: ModelCommandSettings) -> String {
        let main = entry.mainProviderClass?.rawValue ?? "-"
        let fallback = entry.fallbackProviderClasses.map(\.rawValue).joined(separator: ",")
        let enabled = entry.enabledProviderIDs.joined(separator: ",")
        return "main=\(main);fallback=\(fallback);enabled=\(enabled);offlineDefault=\(entry.offlineDefault)"
    }
}
