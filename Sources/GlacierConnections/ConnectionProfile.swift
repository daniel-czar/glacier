import Foundation
import OmniCore

public enum ConnectionError: Error, Sendable, Equatable, LocalizedError {
    case invalidProfile
    case invalidEndpoint
    case unsupportedProvider
    case unsupportedVersion
    case originApprovalRequired
    case missingCredential
    case invalidCredentialSource
    case invalidModelSelector
    case credentialUnavailable
    case unsafeRedirect
    case unsafeDestination
    case storageFailure

    public var errorDescription: String? {
        switch self {
        case .invalidProfile: "Invalid connection profile."
        case .invalidEndpoint: "The endpoint must be HTTPS, or an explicitly selected loopback local service."
        case .unsupportedProvider: "Unsupported provider."
        case .unsupportedVersion: "Unsupported connections document version."
        case .originApprovalRequired: "Approve this connection destination before using a credential."
        case .missingCredential: "This connection has no selected credential."
        case .invalidCredentialSource: "Invalid credential source."
        case .invalidModelSelector: "Choose a supported model profile and a valid model identifier."
        case .credentialUnavailable: "The selected credential is unavailable."
        case .unsafeRedirect: "The provider redirected the request; no credential was sent to the new destination."
        case .unsafeDestination: "The request destination is not an approved connection origin."
        case .storageFailure: "The connection could not be saved."
        }
    }
}

public enum ConnectionProvider: String, Codable, CaseIterable, Sendable {
    case cerebras, openRouter, openAI, anthropic, ollama

    public var displayName: String {
        switch self {
        case .cerebras: "Cerebras"
        case .openRouter: "OpenRouter"
        case .openAI: "OpenAI API"
        case .anthropic: "Anthropic API"
        case .ollama: "Ollama"
        }
    }

    public var connectionID: String {
        switch self {
        case .cerebras: ProviderRuntimeCatalog.cerebrasConnectionID
        case .openRouter: ProviderRuntimeCatalog.openRouterConnectionID
        case .openAI: ProviderRuntimeCatalog.openAIAPIConnectionID
        case .anthropic: ProviderRuntimeCatalog.anthropicAPIConnectionID
        case .ollama: ProviderRuntimeCatalog.localConnectionID
        }
    }

    public var defaultEndpoint: URL {
        // The current runtime catalogue is the source for maintained presets.
        ProviderRuntimeCatalog.connection(connectionID)!.endpoint!
    }

    public var requiresCredential: Bool { self != .ollama }
}

/// An exact HTTP origin. Path, query, fragment and userinfo are never grants.
public struct ConnectionOrigin: Codable, Hashable, Sendable, CustomStringConvertible {
    public let scheme: String
    public let host: String
    public let port: Int

    public init(url: URL, localService: Bool) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawScheme = parts.scheme?.lowercased(), let rawHost = parts.host?.lowercased(),
              !rawHost.isEmpty, parts.user == nil, parts.password == nil,
              parts.fragment == nil, parts.query == nil,
              (parts.port == nil || (1...65535).contains(parts.port!)) else {
            throw ConnectionError.invalidEndpoint
        }
        let isLoopback = rawHost == "localhost" || rawHost == "127.0.0.1" || rawHost == "[::1]" || rawHost == "::1"
        guard rawScheme == "https" || (localService && rawScheme == "http" && isLoopback) else {
            throw ConnectionError.invalidEndpoint
        }
        if localService && rawScheme == "http" && !isLoopback { throw ConnectionError.invalidEndpoint }
        scheme = rawScheme
        host = rawHost
        port = parts.port ?? (rawScheme == "https" ? 443 : 80)
    }

    public var description: String { "\(scheme)://\(host):\(port)" }
}

/// Only one source is selected. No fallback or discovery order exists.
public enum CredentialSource: Codable, Hashable, Sendable {
    case keychain(account: UUID)
    case dotenvFile(path: String, key: String)
    case processEnvironment(name: String)

    public var displayKind: String {
        switch self {
        case .keychain: "Keychain"
        case .dotenvFile: "Explicit dotenv file"
        case .processEnvironment: "Named process environment variable"
        }
    }
}

/// Nonsecret, app-owned connection data. `approvedOrigin` binds its credential
/// grant to a destination and is cleared whenever the endpoint/source changes.
public struct ConnectionProfile: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let provider: ConnectionProvider
    public let endpoint: URL
    public let enabled: Bool
    public let credentialSource: CredentialSource?
    public let approvedOrigin: ConnectionOrigin?
    public let revision: Int

    public init(id: String, provider: ConnectionProvider, endpoint: URL, enabled: Bool = false,
                credentialSource: CredentialSource? = nil, approvedOrigin: ConnectionOrigin? = nil,
                revision: Int = 1) throws {
        guard !id.isEmpty, id == provider.connectionID,
              revision > 0, revision < Int.max else { throw ConnectionError.invalidProfile }
        let origin = try ConnectionOrigin(url: endpoint, localService: provider == .ollama)
        guard approvedOrigin == nil || approvedOrigin == origin else { throw ConnectionError.invalidProfile }
        if provider == .ollama && credentialSource != nil { throw ConnectionError.invalidCredentialSource }
        self.id = id
        self.provider = provider
        self.endpoint = endpoint
        self.enabled = enabled
        self.credentialSource = credentialSource
        self.approvedOrigin = approvedOrigin
        self.revision = revision
    }

    public static func preset(_ provider: ConnectionProvider) -> ConnectionProfile {
        try! .init(id: provider.connectionID, provider: provider, endpoint: provider.defaultEndpoint,
                   enabled: provider == .cerebras || provider == .openRouter || provider == .ollama,
                   approvedOrigin: provider == .ollama ? ConnectionOrigin(url: provider.defaultEndpoint, localService: true) : nil)
    }

    public var origin: ConnectionOrigin { try! ConnectionOrigin(url: endpoint, localService: provider == .ollama) }

    public var isReadyForCredential: Bool {
        !provider.requiresCredential || (credentialSource != nil && approvedOrigin == origin)
    }
}

public struct ConnectionsDocument: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public let schemaVersion: Int
    public let revision: Int
    public let profiles: [ConnectionProfile]
    /// App-owned selector overrides only. Missing in earlier schema-v1 JSON.
    public let modelOverrides: [ModelProfileSettings]

    public init(revision: Int = 1, profiles: [ConnectionProfile] = ConnectionProvider.allCases.map(ConnectionProfile.preset),
                modelOverrides: [ModelProfileSettings] = []) {
        schemaVersion = Self.currentVersion
        self.revision = revision
        self.profiles = profiles.sorted { $0.id < $1.id }
        self.modelOverrides = modelOverrides.sorted { $0.profileID < $1.profileID }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, revision, profiles, modelOverrides }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        revision = try values.decode(Int.self, forKey: .revision)
        profiles = try values.decode([ConnectionProfile].self, forKey: .profiles).sorted { $0.id < $1.id }
        modelOverrides = try values.decodeIfPresent([ModelProfileSettings].self, forKey: .modelOverrides)?
            .sorted { $0.profileID < $1.profileID } ?? []
    }
}
