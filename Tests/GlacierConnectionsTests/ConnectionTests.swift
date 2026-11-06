import Foundation
import GlacierConnections
import OmniCore
import OmniModels
import Testing

private final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UUID: String] = [:]
    private var reads = 0
    private var inserts = 0

    func insert(_ secret: String, account: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        inserts += 1
        entries[account] = secret
    }

    func read(account: UUID) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        guard let value = entries[account] else { throw ConnectionError.credentialUnavailable }
        return value
    }

    var readCount: Int { lock.withLock { reads } }
    var insertCount: Int { lock.withLock { inserts } }

    func remove(account: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: account)
    }
}

private actor FakeNetwork: ConnectionNetworkTransport {
    private(set) var calls: [URLRequest] = []
    let status: Int
    init(status: Int = 200) { self.status = status }

    func exchange(_ request: URLRequest) async throws -> ModelHTTPExchange {
        calls.append(request)
        return ModelHTTPExchange(statusCode: status, body: Data())
    }

    func stream(_ request: URLRequest) async throws -> ModelHTTPByteStream {
        calls.append(request)
        return ModelHTTPByteStream(statusCode: status, chunks: AsyncThrowingStream { $0.finish() })
    }

    func callCount() -> Int { calls.count }
}

private final class RevocableConnectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    func revoke() { lock.withLock { allowed = false } }
    func check() throws {
        try lock.withLock { if !allowed { throw CancellationError() } }
    }
}

private actor PausedApprovedOrigins {
    private let approved: Set<ConnectionOrigin>
    private var continuation: CheckedContinuation<Set<ConnectionOrigin>, Never>?
    init(_ approved: Set<ConnectionOrigin>) { self.approved = approved }
    func read() async -> Set<ConnectionOrigin> {
        await withCheckedContinuation { continuation = $0 }
    }
    func isWaiting() -> Bool { continuation != nil }
    func resume() { continuation?.resume(returning: approved); continuation = nil }
}

@Test(arguments: [false, true])
func revokedGateDuringOriginLookupCannotDispatchExchangeOrStream(streaming: Bool) async throws {
    let url = URL(string: "https://fixture.invalid/v1")!
    let approved = try ConnectionOrigin(url: url, localService: false)
    let origins = PausedApprovedOrigins([approved])
    let gate = RevocableConnectionGate()
    let network = FakeNetwork()
    let transport = ApprovedOriginTransport(origins: { await origins.read() }, base: network,
                                             gate: { _ in try gate.check() })
    let pending = Task {
        if streaming { _ = try await transport.stream(URLRequest(url: url)) }
        else { _ = try await transport.exchange(URLRequest(url: url)) }
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await origins.isWaiting()), ContinuousClock.now < deadline { await Task.yield() }
    guard await origins.isWaiting() else {
        pending.cancel()
        await origins.resume()
        throw CancellationError()
    }
    gate.revoke()
    await origins.resume()
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(await network.callCount() == 0)
}

private func makeStore(_ secrets: any SecretStore = MemorySecrets()) throws -> ConnectionStore {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-connections-\(UUID().uuidString)", isDirectory: true)
    return try ConnectionStore(fileURL: folder.appendingPathComponent("connections.json"), secrets: secrets)
}

@Test func endpointValidationRejectsInsecureRemoteAndEmbeddedCredentials() throws {
    #expect(throws: ConnectionError.self) {
        _ = try ConnectionOrigin(url: URL(string: "http://api.example.test/v1")!, localService: false)
    }
    #expect(throws: ConnectionError.self) {
        _ = try ConnectionOrigin(url: URL(string: "http://example.test:11434")!, localService: true)
    }
    #expect(throws: ConnectionError.self) {
        _ = try ConnectionOrigin(url: URL(string: "https://user:password@example.test/v1")!, localService: false)
    }
    let origin = try ConnectionOrigin(url: URL(string: "http://127.0.0.1:11434")!, localService: true)
    #expect(origin.port == 11434)
}

@Test func keyIsOnlyInSelectedStoreAndLocalDocumentContainsReference() async throws {
    let secrets = MemorySecrets()
    let store = try makeStore(secrets)
    try await store.saveKey("synthetic-secret", for: ConnectionProvider.cerebras.connectionID)
    let item = try #require(await store.profile(ConnectionProvider.cerebras.connectionID))
    #expect(item.isReadyForCredential)
    guard case .keychain(let account)? = item.credentialSource else {
        Issue.record("expected Keychain reference")
        return
    }
    #expect(try secrets.read(account: account) == "synthetic-secret")
    let bytes = try Data(contentsOf: store.fileURL)
    #expect(!String(decoding: bytes, as: UTF8.self).contains("synthetic-secret"))
    let settings = await store.runtimeSettings()
    #expect(settings.connection(item.id)?.credentialReference == .keychain(service: GlacierKeychainSecretStore.service, account: account.uuidString.lowercased()))
    let resolver = await store.credentialResolver(for: .cerebras, environment: { _ in "ambient-should-not-be-used" })
    #expect(try resolver.resolve(.keychain(service: GlacierKeychainSecretStore.service, account: account.uuidString.lowercased())).byteCount == "synthetic-secret".utf8.count)
    #expect(settings.connection(ProviderRuntimeCatalog.chatGPTConnectionID)?.enabled == false)
    #expect(settings.connection(ProviderRuntimeCatalog.claudeConnectionID)?.enabled == false)
}

@Test func endpointChangeRevokesGrantAndImportCannotReuseSecret() async throws {
    let store = try makeStore()
    try await store.approveSource(.processEnvironment(name: "EXPLICIT_TEST_KEY"), for: ConnectionProvider.openAI.connectionID)
    try await store.setEnabled(true, for: ConnectionProvider.openAI.connectionID)
    let before = try #require(await store.profile(ConnectionProvider.openAI.connectionID))
    #expect(before.isReadyForCredential)
    try await store.setEndpoint(URL(string: "https://example.test/v1/chat/completions")!, for: before.id)
    let changed = try #require(await store.profile(before.id))
    #expect(changed.approvedOrigin == nil)
    #expect(await store.runtimeSettings().connection(before.id)?.credentialReference == nil)
    let network = FakeNetwork()
    let transport = ApprovedOriginTransport(store: store, provider: .openAI, base: network)
    var request = URLRequest(url: changed.endpoint)
    request.httpMethod = "POST"
    await #expect(throws: ConnectionError.self) { _ = try await transport.exchange(request) }
    #expect(await network.callCount() == 0)

    let importedBytes = try Data(contentsOf: store.fileURL)
    try await store.importConfiguration(importedBytes)
    let imported = try #require(await store.profile(before.id))
    #expect(imported.approvedOrigin == nil)
}

@Test func explicitEnvironmentDoesNotFallBackAndAmbientKeyIsIgnored() async throws {
    let store = try makeStore()
    let absent = await store.credentialResolver(for: .cerebras, environment: { _ in "ambient" })
    #expect(throws: ModelCredentialError.self) {
        _ = try absent.resolve(.environmentVariable(name: "AMBIENT_KEY"))
    }
    try await store.approveSource(.processEnvironment(name: "CHOSEN_KEY"), for: ConnectionProvider.cerebras.connectionID)
    let resolver = await store.credentialResolver(for: .cerebras, environment: { name in
        name == "OTHER_KEY" ? "wrong-value" : nil
    })
    #expect(throws: ModelCredentialError.self) {
        _ = try resolver.resolve(.environmentVariable(name: "CHOSEN_KEY"))
    }
    #expect(throws: ModelCredentialError.self) {
        _ = try resolver.resolve(.environmentVariable(name: "OTHER_KEY"))
    }

    let active = await store.credentialResolver(for: .cerebras, environment: { name in name == "CHOSEN_KEY" ? "chosen-value" : nil })
    #expect(try active.resolve(.environmentVariable(name: "CHOSEN_KEY")).byteCount == "chosen-value".utf8.count)
    try await store.setEnabled(false, for: ConnectionProvider.cerebras.connectionID)
    #expect(throws: ModelCredentialError.self) {
        _ = try active.resolve(.environmentVariable(name: "CHOSEN_KEY"))
    }
}

@Test func redirectIsRejectedForExchangeAndStream() async throws {
    let store = try makeStore()
    let profile = try #require(await store.profile(ConnectionProvider.ollama.connectionID))
    let network = FakeNetwork(status: 302)
    let transport = ApprovedOriginTransport(store: store, provider: .ollama, base: network)
    let request = URLRequest(url: profile.endpoint)
    await #expect(throws: ConnectionError.self) { _ = try await transport.exchange(request) }
    await #expect(throws: ConnectionError.self) { _ = try await transport.stream(request) }
    #expect(await network.callCount() == 2)
    let hostile = URLRequest(url: URL(string: "https://attacker.example/v1")!)
    await #expect(throws: ConnectionError.self) { _ = try await transport.exchange(hostile) }
    #expect(await network.callCount() == 2)
}

@Test func providerScopedOriginAndLiveGateRejectBeforeNetwork() async throws {
    let store = try makeStore()
    try await store.approveSource(.processEnvironment(name: "C_KEY"), for: ConnectionProvider.cerebras.connectionID)
    try await store.approveSource(.processEnvironment(name: "O_KEY"), for: ConnectionProvider.openAI.connectionID)
    try await store.setEnabled(true, for: ConnectionProvider.openAI.connectionID)
    let network = FakeNetwork()
    let cerebras = ApprovedOriginTransport(store: store, provider: .cerebras, base: network)
    let otherApproved = URLRequest(url: ConnectionProvider.openAI.defaultEndpoint)
    await #expect(throws: ConnectionError.self) { _ = try await cerebras.exchange(otherApproved) }
    #expect(await network.callCount() == 0)

    let paused = ApprovedOriginTransport(store: store, provider: .cerebras, base: network,
                                         gate: { _ in throw ConnectionError.unsafeDestination })
    let valid = URLRequest(url: ConnectionProvider.cerebras.defaultEndpoint)
    await #expect(throws: ConnectionError.self) { _ = try await paused.exchange(valid) }
    await #expect(throws: ConnectionError.self) { _ = try await paused.stream(valid) }
    #expect(await network.callCount() == 0)
}

@Test func sharedEnvironmentNameCannotCrossProviderGrant() async throws {
    let store = try makeStore()
    try await store.approveSource(.processEnvironment(name: "SHARED_KEY"), for: ConnectionProvider.cerebras.connectionID)
    try await store.approveSource(.processEnvironment(name: "SHARED_KEY"), for: ConnectionProvider.openAI.connectionID)
    try await store.setEnabled(true, for: ConnectionProvider.openAI.connectionID)
    let oldCerebras = await store.credentialResolver(for: .cerebras, environment: { _ in "synthetic" })
    #expect(try oldCerebras.resolve(.environmentVariable(name: "SHARED_KEY")).byteCount == 9)
    try await store.approveSource(.processEnvironment(name: "NEW_CEREBRAS_KEY"), for: ConnectionProvider.cerebras.connectionID)
    #expect(throws: ModelCredentialError.self) {
        _ = try oldCerebras.resolve(.environmentVariable(name: "SHARED_KEY"))
    }
    let openAI = await store.credentialResolver(for: .openAI, environment: { _ in "synthetic" })
    #expect(try openAI.resolve(.environmentVariable(name: "SHARED_KEY")).byteCount == 9)
}

@Test func keychainAccountCannotBeAttachedAcrossProvidersOrDeletedByOtherProfile() async throws {
    let secrets = MemorySecrets()
    let store = try makeStore(secrets)
    try await store.saveKey("cerebras-synthetic", for: ConnectionProvider.cerebras.connectionID)
    let cerebras = try #require(await store.profile(ConnectionProvider.cerebras.connectionID))
    guard case .keychain(let account)? = cerebras.credentialSource else {
        Issue.record("expected Keychain source")
        return
    }
    await #expect(throws: ConnectionError.self) {
        try await store.approveSource(.keychain(account: account), for: ConnectionProvider.openAI.connectionID)
    }
    try await store.clearCredential(for: ConnectionProvider.openAI.connectionID)
    #expect(try secrets.read(account: account) == "cerebras-synthetic")

    let duplicate = try ConnectionProfile(id: ConnectionProvider.openAI.connectionID,
                                          provider: .openAI, endpoint: ConnectionProvider.openAI.defaultEndpoint,
                                          credentialSource: .keychain(account: account))
    let profiles = (await store.snapshot()).profiles.map { $0.provider == .openAI ? duplicate : $0 }
    let data = try JSONEncoder().encode(ConnectionsDocument(profiles: profiles))
    await #expect(throws: ConnectionError.self) { try await store.importConfiguration(data) }
    #expect(try secrets.read(account: account) == "cerebras-synthetic")
}

@Test func connectionTestRequiresExplicitCallAndReportsUnverifiedCredential() async throws {
    let store = try makeStore()
    let network = FakeNetwork(status: 405)
    #expect(await network.callCount() == 0)
    let result = try await store.testConnection(ConnectionProvider.ollama.connectionID, network: network)
    #expect(result.provider == .ollama)
    #expect(result.statusCode == 405)
    #expect(result.credentialStatus == .notRequired)
    #expect(await network.callCount() == 1)
}

@Test func connectionTestGateRunsBeforeSecretResolutionAndNetwork() async throws {
    let secrets = MemorySecrets()
    let store = try makeStore(secrets)
    try await store.saveKey("synthetic", for: ConnectionProvider.cerebras.connectionID)
    let network = FakeNetwork()
    await #expect(throws: ConnectionError.self) {
        _ = try await store.testConnection(ConnectionProvider.cerebras.connectionID, network: network,
                                           gate: { _ in throw ConnectionError.unsafeDestination })
    }
    #expect(secrets.readCount == 0)
    #expect(await network.callCount() == 0)
}

@Test func existingConnectionFileAndDirectoryAreTightenedOnLoad() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-permissions-\(UUID().uuidString)")
    let folder = root.appendingPathComponent("Glacier", isDirectory: true)
    let file = folder.appendingPathComponent("connections.json")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try JSONEncoder().encode(ConnectionsDocument()).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: folder.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
    let store = try ConnectionStore(fileURL: file, secrets: MemorySecrets())
    #expect((await store.snapshot()).profiles.count == 5)
    let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
    let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    #expect(folderMode?.intValue == 0o700)
    #expect(fileMode?.intValue == 0o600)
}

@Test func connectionStoreRejectsFileAndDirectorySymlinksWithoutTouchingTarget() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-symlink-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("outside.json")
    try JSONEncoder().encode(ConnectionsDocument()).write(to: outside)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: outside.path)
    let ownedFolder = root.appendingPathComponent("owned", isDirectory: true)
    try FileManager.default.createDirectory(at: ownedFolder, withIntermediateDirectories: true)
    let link = ownedFolder.appendingPathComponent("connections.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    #expect(throws: ConnectionError.self) { _ = try ConnectionStore(fileURL: link, secrets: MemorySecrets()) }
    let outsideMode = try FileManager.default.attributesOfItem(atPath: outside.path)[.posixPermissions] as? NSNumber
    #expect(outsideMode?.intValue == 0o644)

    let linkedFolder = root.appendingPathComponent("linked", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: ownedFolder)
    #expect(throws: ConnectionError.self) {
        _ = try ConnectionStore(fileURL: linkedFolder.appendingPathComponent("connections.json"), secrets: MemorySecrets())
    }
}

@Test func exhaustedRevisionCountersRejectWithoutOverflow() async throws {
    let store = try makeStore()
    let baseline = try JSONEncoder().encode(ConnectionsDocument())
    let original = try #require(JSONSerialization.jsonObject(with: baseline) as? [String: Any])
    var object = original
    var profiles = try #require(object["profiles"] as? [[String: Any]])
    profiles[0]["revision"] = Int.max
    object["profiles"] = profiles
    let profileOverflow = try JSONSerialization.data(withJSONObject: object)
    await #expect(throws: ConnectionError.self) { try await store.importConfiguration(profileOverflow) }

    object = original
    object["revision"] = Int.max
    let documentOverflow = try JSONSerialization.data(withJSONObject: object)
    await #expect(throws: ConnectionError.self) { try await store.importConfiguration(documentOverflow) }

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-revision-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("connections.json")
    try documentOverflow.write(to: file)
    #expect(throws: ConnectionError.self) { _ = try ConnectionStore(fileURL: file, secrets: MemorySecrets()) }
}

@Test func modelSelectorOverridePersistsAndBridgesWithoutCredentialAccess() async throws {
    let secrets = MemorySecrets()
    let store = try makeStore(secrets)
    let profileID = ProviderRuntimeCatalog.openRouterGPTOSSProfileID
    let custom = "team/new-model:v2"
    try await store.setModelSelector(profileID: profileID, modelSelector: custom)
    #expect(await store.effectiveModelSelector(for: profileID) == custom)
    #expect(await store.modelOverrides().count == 1)
    #expect(await store.runtimeSettings().profile(profileID)?.modelSelector == custom)
    #expect(secrets.readCount == 0 && secrets.insertCount == 0)

    let reloaded = try ConnectionStore(fileURL: store.fileURL, secrets: secrets)
    #expect(await reloaded.effectiveModelSelector(for: profileID) == custom)
    #expect(await reloaded.runtimeSettings().profile(profileID)?.modelSelector == custom)
    #expect(secrets.readCount == 0 && secrets.insertCount == 0)
    try await reloaded.setModelSelector(profileID: profileID,
                                        modelSelector: try #require(ProviderRuntimeCatalog.profile(profileID)).modelSelector)
    #expect(await reloaded.modelOverrides().isEmpty)
    #expect(await reloaded.effectiveModelSelector(for: profileID) == ProviderRuntimeCatalog.profile(profileID)?.modelSelector)
}

@Test func oldConnectionsJSONWithoutModelOverridesStillLoads() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-old-connections-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("connections.json")
    let baseline = try JSONEncoder().encode(ConnectionsDocument())
    var object = try #require(JSONSerialization.jsonObject(with: baseline) as? [String: Any])
    object.removeValue(forKey: "modelOverrides")
    let oldBytes = try JSONSerialization.data(withJSONObject: object)
    try oldBytes.write(to: file)
    let store = try ConnectionStore(fileURL: file, secrets: MemorySecrets())
    #expect(await store.modelOverrides().isEmpty)
    try await store.setModelSelector(profileID: ProviderRuntimeCatalog.cerebrasFastProfileID,
                                     modelSelector: "custom-cerebras-model")
    #expect(await store.modelOverrides().count == 1)
    try await store.importConfiguration(oldBytes)
    #expect(await store.effectiveModelSelector(for: ProviderRuntimeCatalog.cerebrasFastProfileID) == "custom-cerebras-model")
    try await store.importConfiguration(try JSONEncoder().encode(ConnectionsDocument(modelOverrides: [])))
    #expect(await store.modelOverrides().isEmpty)
}

@Test func modelOverrideSurvivesConnectionEditsAndCredentialFreeImport() async throws {
    let secrets = MemorySecrets()
    let store = try makeStore(secrets)
    let profileID = ProviderRuntimeCatalog.cerebrasFastProfileID
    try await store.setModelSelector(profileID: profileID, modelSelector: "custom/model-v2")
    try await store.saveKey("synthetic", for: ConnectionProvider.cerebras.connectionID)
    try await store.setEndpoint(URL(string: "https://api.cerebras.ai/v2/chat/completions")!,
                                for: ConnectionProvider.cerebras.connectionID)
    #expect(await store.effectiveModelSelector(for: profileID) == "custom/model-v2")
    let exported = try Data(contentsOf: store.fileURL)
    let imported = try makeStore(MemorySecrets())
    try await imported.importConfiguration(exported)
    #expect(await imported.effectiveModelSelector(for: profileID) == "custom/model-v2")
    let connection = try #require(await imported.profile(ConnectionProvider.cerebras.connectionID))
    #expect(connection.credentialSource == nil && connection.approvedOrigin == nil)
    #expect(await imported.runtimeSettings().profile(profileID)?.modelSelector == "custom/model-v2")
}

@Test func modelSelectorRejectsUnknownUnsafeAndExhaustedOverrides() async throws {
    let store = try makeStore()
    let profileID = ProviderRuntimeCatalog.cerebrasFastProfileID
    for value in ["", "has space", "line\nfeed", "a\u{0000}b", String(repeating: "a", count: 201), "é"] {
        await #expect(throws: ConnectionError.self) {
            try await store.setModelSelector(profileID: profileID, modelSelector: value)
        }
    }
    await #expect(throws: ConnectionError.self) {
        try await store.setModelSelector(profileID: "unknown-profile", modelSelector: "valid-model")
    }
    #expect(await store.modelOverrides().isEmpty)

    let bad = ConnectionsDocument(modelOverrides: [ModelProfileSettings(
        profileID: profileID, modelSelector: "valid-model", revision: Int.max
    )])
    let data = try JSONEncoder().encode(bad)
    await #expect(throws: ConnectionError.self) { try await store.importConfiguration(data) }
    #expect(await store.modelOverrides().isEmpty)
}

@Test func importedKeylessRemoteOllamaRemainsDisabledUntilExplicitEnable() async throws {
    let source = try makeStore()
    let remote = URL(string: "https://ollama.example.test/api")!
    try await source.setEndpoint(remote, for: ConnectionProvider.ollama.connectionID)
    let importedBytes = try Data(contentsOf: source.fileURL)
    let target = try makeStore()
    try await target.importConfiguration(importedBytes)
    let ollama = try #require(await target.profile(ConnectionProvider.ollama.connectionID))
    #expect(ollama.endpoint == remote)
    #expect(!ollama.enabled && ollama.approvedOrigin == nil)
    #expect(!(await target.approvedOrigins()).contains(ollama.origin))
    #expect(await target.runtimeSettings().connection(ollama.id)?.enabled == false)
    try await target.setEnabled(true, for: ollama.id)
    #expect(await target.runtimeSettings().connection(ollama.id)?.enabled == true)
}
