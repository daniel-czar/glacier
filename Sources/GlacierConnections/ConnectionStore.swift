import Darwin
import Foundation
import GlacierConfiguration
import OmniCore

/// Local, versioned, nonsecret connection configuration. Constructing or
/// loading the store never resolves a credential or contacts a provider.
public actor ConnectionStore {
    public nonisolated let fileURL: URL
    private let secrets: any SecretStore
    private var document: ConnectionsDocument
    private let grants: ConnectionGrantBox

    public init(fileURL: URL, secrets: any SecretStore = GlacierKeychainSecretStore()) throws {
        guard fileURL.isFileURL else { throw ConnectionError.storageFailure }
        self.fileURL = fileURL
        self.secrets = secrets
        do {
            try GlacierFilePermissions.ensurePrivateDirectory(at: fileURL.deletingLastPathComponent())
            try Self.rejectFinalSymlink(at: fileURL)
        } catch { throw ConnectionError.storageFailure }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try GlacierFilePermissions.ensurePrivateFile(at: fileURL)
                let bytes = try Self.readNoFollow(at: fileURL)
                let loaded = try JSONDecoder().decode(ConnectionsDocument.self, from: bytes)
                try Self.validate(loaded)
                document = loaded
            } catch let error as ConnectionError { throw error }
            catch { throw ConnectionError.storageFailure }
        } else {
            document = ConnectionsDocument()
        }
        grants = ConnectionGrantBox(profiles: document.profiles)
    }

    public func snapshot() -> ConnectionsDocument { document }
    public func profile(_ id: String) -> ConnectionProfile? { document.profiles.first { $0.id == id } }
    public func modelOverrides() -> [ModelProfileSettings] { document.modelOverrides }

    public func effectiveModelSelector(for profileID: String) -> String? {
        guard let preset = ProviderRuntimeCatalog.profiles.first(where: { $0.id == profileID }) else { return nil }
        return document.modelOverrides.first(where: { $0.profileID == profileID })?.modelSelector ?? preset.modelSelector
    }

    /// A model identifier is data for a known preset, not a new provider or
    /// qualification claim. Saving it never resolves a credential or probes.
    public func setModelSelector(profileID: String, modelSelector: String) throws {
        guard let preset = ProviderRuntimeCatalog.profiles.first(where: { $0.id == profileID }) else {
            throw ConnectionError.invalidModelSelector
        }
        try Self.validateModelSelector(modelSelector)
        let previous = document.modelOverrides.first { $0.profileID == profileID }
        if previous?.modelSelector == modelSelector || (previous == nil && preset.modelSelector == modelSelector) {
            return
        }
        var overrides = document.modelOverrides.filter { $0.profileID != profileID }
        if modelSelector != preset.modelSelector {
            overrides.append(ModelProfileSettings(profileID: profileID, modelSelector: modelSelector,
                                                  revision: (previous?.revision ?? 0) + 1))
        }
        try persist(ConnectionsDocument(revision: document.revision + 1, profiles: document.profiles,
                                        modelOverrides: overrides))
    }

    /// An endpoint change preserves the selected source as visible data, but
    /// revokes its destination grant. Test/generation remain unavailable until
    /// an explicit source approval for the new origin.
    public func setEndpoint(_ endpoint: URL, for id: String) throws {
        guard let old = profile(id) else { throw ConnectionError.unsupportedProvider }
        let newOrigin = try ConnectionOrigin(url: endpoint, localService: old.provider == .ollama)
        let changed = newOrigin != old.origin
        let replacement = try ConnectionProfile(id: id, provider: old.provider, endpoint: endpoint,
                                                enabled: old.enabled, credentialSource: old.credentialSource,
                                                approvedOrigin: changed ? nil : old.approvedOrigin,
                                                revision: old.revision + 1)
        try replace(replacement)
    }

    public func setEnabled(_ enabled: Bool, for id: String, authorizeCommit: @Sendable () throws -> Void = {}) throws {
        guard let old = profile(id) else { throw ConnectionError.unsupportedProvider }
        let replacement = try ConnectionProfile(id: id, provider: old.provider, endpoint: old.endpoint,
                                                enabled: enabled, credentialSource: old.credentialSource,
                                                approvedOrigin: old.approvedOrigin, revision: old.revision + 1)
        try authorizeCommit()
        try replace(replacement)
    }

    /// Called only after the user chose a named source and saw its destination.
    /// A source change revokes the previous grant and creates a new one in the
    /// same local save; no hidden fallback source is retained.
    public func approveSource(_ source: CredentialSource, for id: String) throws {
        guard let old = profile(id), old.provider.requiresCredential else { throw ConnectionError.unsupportedProvider }
        if case .keychain = source { throw ConnectionError.invalidCredentialSource }
        try source.validate()
        let replacement = try ConnectionProfile(id: id, provider: old.provider, endpoint: old.endpoint,
                                                enabled: old.enabled, credentialSource: source,
                                                approvedOrigin: old.origin, revision: old.revision + 1)
        try replace(replacement)
        if case .keychain(let previous)? = old.credentialSource, old.credentialSource != source {
            try? secrets.remove(account: previous)
        }
    }

    /// Secure-field submit. The key is written only to the new Glacier service
    /// and a UUID reference is committed to connections.json. A failed config
    /// write removes the newly inserted item.
    public func saveKey(_ secret: String, for id: String, expectedEndpoint: URL? = nil,
                        authorizeCommit: @Sendable () throws -> Void = {}) throws {
        guard let old = profile(id), old.provider.requiresCredential else { throw ConnectionError.unsupportedProvider }
        if let expectedEndpoint, old.endpoint != expectedEndpoint { throw ConnectionError.originApprovalRequired }
        let account = UUID()
        try authorizeCommit()
        try secrets.insert(secret, account: account)
        do {
            let replacement = try ConnectionProfile(id: id, provider: old.provider, endpoint: old.endpoint,
                                                    enabled: old.enabled, credentialSource: .keychain(account: account),
                                                    approvedOrigin: old.origin, revision: old.revision + 1)
            try replace(replacement)
        } catch {
            try? secrets.remove(account: account)
            throw error
        }
        if case .keychain(let previous)? = old.credentialSource { try? secrets.remove(account: previous) }
    }

    public func clearCredential(for id: String) throws {
        guard let old = profile(id) else { throw ConnectionError.unsupportedProvider }
        let replacement = try ConnectionProfile(id: id, provider: old.provider, endpoint: old.endpoint,
                                                enabled: old.enabled, revision: old.revision + 1)
        try replace(replacement)
        if case .keychain(let previous)? = old.credentialSource { try? secrets.remove(account: previous) }
    }

    /// Imported documents are untrusted. They may supply endpoint/source
    /// suggestions but never carry an origin grant or reusable Keychain item.
    public func importConfiguration(_ bytes: Data) throws {
        guard bytes.count <= 1_000_000 else { throw ConnectionError.invalidProfile }
        let incoming: ConnectionsDocument
        do { incoming = try JSONDecoder().decode(ConnectionsDocument.self, from: bytes) }
        catch { throw ConnectionError.invalidProfile }
        try Self.validate(incoming)
        let fields = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        let importedOverrides = fields?.keys.contains("modelOverrides") == true
            ? incoming.modelOverrides : document.modelOverrides
        var imported: [ConnectionProfile] = []
        for item in incoming.profiles {
            let source: CredentialSource?
            if case .keychain = item.credentialSource { source = nil }
            else { source = item.credentialSource }
            imported.append(try ConnectionProfile(id: item.id, provider: item.provider,
                                                  endpoint: item.endpoint, enabled: false,
                                                  credentialSource: source,
                                                  approvedOrigin: nil,
                                                  revision: item.revision + 1))
        }
        try persist(ConnectionsDocument(revision: document.revision + 1, profiles: imported,
                                        modelOverrides: importedOverrides))
    }

    /// Safe bridge for both durable broker commands and ephemeral streaming.
    /// Only explicitly approved sources become runtime references.
    public func runtimeSettings(commands: [ModelCommandRouteSettings] = []) -> ProviderRuntimeSettings {
        var connections = document.profiles.map { item in
            ModelConnectionSettings(connectionID: item.id,
                                    enabled: item.enabled && item.isReadyForCredential,
                                    credentialReference: item.isReadyForCredential ? item.credentialSource?.modelReference : nil,
                                    endpoint: item.endpoint, revision: item.revision)
        }
        // Subscription CLIs are not implicitly selected or assumed installed.
        connections += [ProviderRuntimeCatalog.chatGPTConnectionID, ProviderRuntimeCatalog.claudeConnectionID].map {
            ModelConnectionSettings(connectionID: $0, enabled: false)
        }
        return ProviderRuntimeSettings(configurationID: "glacier", revision: document.revision,
                                       connections: connections, profiles: document.modelOverrides,
                                       commands: commands)
    }

    public func profileIDs(for provider: ConnectionProvider) -> [String] {
        ProviderRuntimeCatalog.profiles.filter { $0.connectionID == provider.connectionID }.map(\.id)
    }

    public func credentialResolver(for provider: ConnectionProvider,
                                   environment: @escaping @Sendable (String) -> String? = { ProcessInfo.processInfo.environment[$0] }) -> GlacierCredentialResolver {
        GlacierCredentialResolver(grants: grants, provider: provider, secrets: secrets, environment: environment)
    }

    public func approvedOrigins() -> Set<ConnectionOrigin> {
        Set(document.profiles.filter { $0.enabled && $0.isReadyForCredential }.map(\.origin))
    }

    public func approvedOrigin(for provider: ConnectionProvider) -> ConnectionOrigin? {
        guard let item = document.profiles.first(where: { $0.provider == provider }),
              item.enabled && item.isReadyForCredential else { return nil }
        return item.origin
    }

    private func replace(_ profile: ConnectionProfile) throws {
        let profiles = document.profiles.map { $0.id == profile.id ? profile : $0 }
        guard profiles.contains(where: { $0.id == profile.id }) else { throw ConnectionError.unsupportedProvider }
        try persist(ConnectionsDocument(revision: document.revision + 1, profiles: profiles,
                                        modelOverrides: document.modelOverrides))
    }

    private func persist(_ candidate: ConnectionsDocument) throws {
        try Self.validate(candidate)
        do {
            let folder = fileURL.deletingLastPathComponent()
            try GlacierFilePermissions.ensurePrivateDirectory(at: folder)
            try Self.rejectFinalSymlink(at: fileURL)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let bytes = try encoder.encode(candidate)
            try bytes.write(to: fileURL, options: .atomic)
            try GlacierFilePermissions.ensurePrivateFile(at: fileURL)
            document = candidate
            grants.update(profiles: candidate.profiles)
        } catch { throw ConnectionError.storageFailure }
    }

    /// Also catches dangling final symlinks, which `fileExists` misses. The
    /// shared permissions helper uses O_NOFOLLOW for the actual chmod/open.
    private static func rejectFinalSymlink(at url: URL) throws {
        var details = stat()
        let result = url.path.withCString { lstat($0, &details) }
        if result == 0 && (details.st_mode & S_IFMT) == S_IFLNK {
            throw ConnectionError.storageFailure
        }
        if result != 0 && errno != ENOENT { throw ConnectionError.storageFailure }
    }

    private static func readNoFollow(at url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ConnectionError.storageFailure }
        defer { _ = close(descriptor) }
        var details = stat()
        guard fstat(descriptor, &details) == 0,
              (details.st_mode & S_IFMT) == S_IFREG else { throw ConnectionError.storageFailure }
        var result = Data()
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = chunk.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            }
            guard count >= 0, result.count + count <= 1_000_000 else { throw ConnectionError.storageFailure }
            if count == 0 { return result }
            result.append(contentsOf: chunk.prefix(count))
        }
    }

    private static func validate(_ candidate: ConnectionsDocument) throws {
        guard candidate.schemaVersion == ConnectionsDocument.currentVersion else { throw ConnectionError.unsupportedVersion }
        guard candidate.revision > 0, candidate.revision < Int.max,
              candidate.profiles.count == ConnectionProvider.allCases.count,
              Set(candidate.profiles.map(\.id)).count == candidate.profiles.count else { throw ConnectionError.invalidProfile }
        var keychainAccounts: Set<UUID> = []
        for item in candidate.profiles {
            guard item.id == item.provider.connectionID,
                  item.revision > 0, item.revision < Int.max else { throw ConnectionError.invalidProfile }
            let origin = try ConnectionOrigin(url: item.endpoint, localService: item.provider == .ollama)
            guard item.approvedOrigin == nil || item.approvedOrigin == origin else { throw ConnectionError.invalidProfile }
            if item.provider == .ollama && item.credentialSource != nil { throw ConnectionError.invalidCredentialSource }
            try item.credentialSource?.validate()
            if case .keychain(let account)? = item.credentialSource,
               !keychainAccounts.insert(account).inserted {
                throw ConnectionError.invalidCredentialSource
            }
        }
        guard Set(candidate.modelOverrides.map(\.profileID)).count == candidate.modelOverrides.count else {
            throw ConnectionError.invalidModelSelector
        }
        for saved in candidate.modelOverrides {
            guard ProviderRuntimeCatalog.profiles.contains(where: { $0.id == saved.profileID }),
                  saved.options == nil, saved.revision > 0, saved.revision < Int.max,
                  let selector = saved.modelSelector else { throw ConnectionError.invalidModelSelector }
            try validateModelSelector(selector)
        }
    }

    private static func validateModelSelector(_ selector: String) throws {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:/-")
        guard !selector.isEmpty, selector.utf8.count <= 200,
              selector.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ConnectionError.invalidModelSelector
        }
    }
}
