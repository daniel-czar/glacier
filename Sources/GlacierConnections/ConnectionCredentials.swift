import Foundation
import Security
import OmniCore
import OmniModels

public protocol SecretStore: Sendable {
    func insert(_ secret: String, account: UUID) throws
    func read(account: UUID) throws -> String
    func remove(account: UUID) throws
}

/// Exact-item access in Glacier's independent Keychain service. There is no
/// item enumeration, migration lookup, or access to Omni's service namespace.
public struct GlacierKeychainSecretStore: SecretStore {
    public static let service = "local.Glacier.Development"
    public init() {}

    private func query(_ account: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account.uuidString.lowercased()]
    }

    public func insert(_ secret: String, account: UUID) throws {
        guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConnectionError.missingCredential }
        var item = query(account)
        item[kSecValueData as String] = Data(secret.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ConnectionError.credentialUnavailable }
    }

    public func read(account: UUID) throws -> String {
        var item = query(account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let secret = String(data: data, encoding: .utf8)
        else { throw ConnectionError.credentialUnavailable }
        return secret
    }

    public func remove(account: UUID) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ConnectionError.credentialUnavailable }
    }
}

public struct GlacierCredentialResolver: ModelCredentialResolver {
    private let allowed: @Sendable () -> Set<ModelCredentialReference>
    private let secrets: any SecretStore
    private let referenceResolver: ModelReferenceCredentialResolver

    init(grants: ConnectionGrantBox, provider: ConnectionProvider, secrets: any SecretStore,
         environment: @escaping @Sendable (String) -> String?) {
        allowed = { grants.snapshot(for: provider) }
        self.secrets = secrets
        referenceResolver = ModelReferenceCredentialResolver(environment: environment)
    }

    public func resolve(_ reference: ModelCredentialReference) throws -> ModelResolvedSecret {
        guard allowed().contains(reference) else { throw ModelCredentialError.missingReference }
        switch reference {
        case .keychain(let service, let account):
            guard service == GlacierKeychainSecretStore.service,
                  let uuid = UUID(uuidString: account) else { throw ModelCredentialError.missingReference }
            do { return try ModelResolvedSecret(secrets.read(account: uuid)) }
            catch { throw ModelCredentialError.notFound("selected Glacier Keychain item") }
        case .dotenvFile, .environmentVariable:
            return try referenceResolver.resolve(reference)
        }
    }
}

/// Nonsecret grants shared by runtimes made before a settings edit. The
/// synchronous ModelCredentialResolver protocol cannot await an actor read.
final class ConnectionGrantBox: @unchecked Sendable {
    private let lock = NSLock()
    private var references: [ConnectionProvider: ModelCredentialReference]

    init(profiles: [ConnectionProfile]) {
        references = Self.references(for: profiles)
    }

    func update(profiles: [ConnectionProfile]) {
        lock.lock()
        references = Self.references(for: profiles)
        lock.unlock()
    }

    func snapshot(for provider: ConnectionProvider) -> Set<ModelCredentialReference> {
        lock.lock()
        defer { lock.unlock() }
        return references[provider].map { [$0] } ?? []
    }

    private static func references(for profiles: [ConnectionProfile]) -> [ConnectionProvider: ModelCredentialReference] {
        Dictionary(uniqueKeysWithValues: profiles.compactMap { profile -> (ConnectionProvider, ModelCredentialReference)? in
            guard profile.enabled && profile.isReadyForCredential,
                  let source = profile.credentialSource else { return nil }
            return (profile.provider, source.modelReference)
        })
    }
}

extension CredentialSource {
    var modelReference: ModelCredentialReference {
        switch self {
        case .keychain(let account): .keychain(service: GlacierKeychainSecretStore.service, account: account.uuidString.lowercased())
        case .dotenvFile(let path, let key): .dotenvFile(path: path, key: key)
        case .processEnvironment(let name): .environmentVariable(name: name)
        }
    }

    func validate() throws {
        switch self {
        case .keychain: return
        case .dotenvFile(let path, let key):
            guard path.hasPrefix("/") || path.hasPrefix("~/"),
                  !path.contains("\u{0}"), Self.validName(key) else { throw ConnectionError.invalidCredentialSource }
        case .processEnvironment(let name):
            guard Self.validName(name) else { throw ConnectionError.invalidCredentialSource }
        }
    }

    private static func validName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first) else { return false }
        return name.unicodeScalars.dropFirst().allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0)
        }
    }
}
