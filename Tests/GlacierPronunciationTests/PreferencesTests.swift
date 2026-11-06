import Foundation
import GlacierConnections
@testable import GlacierPronunciation
import OmniModels
import Testing

private final class PronunciationTestSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]
    private var reads = 0
    func insert(_ secret: String, account: UUID) throws { lock.withLock { values[account] = secret } }
    func read(account: UUID) throws -> String {
        try lock.withLock {
            reads += 1
            guard let value = values[account] else { throw PronunciationSettingsError.credentialUnavailable }
            return value
        }
    }
    func remove(account: UUID) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
    var readCount: Int { lock.withLock { reads } }
    var count: Int { lock.withLock { values.count } }
}

private final class PayloadProcess: CLIProcessHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var delivered = false
    func start() throws {}
    func write(_ data: Data) throws { lock.withLock { bytes.append(data) } }
    func closeStdin() {}
    func nextLine(until deadline: ContinuousClock.Instant) async throws -> Data? {
        lock.withLock {
            guard !delivered else { return nil }
            delivered = true
            return Data(#"{"version":1,"event":"complete","result":{"transcriptions":[],"audio":[],"errors":[],"exit_code":0}}"#.utf8)
        }
    }
    func terminate(graceful: Duration, interruptFirst: Bool) async {}
    func waitForExit(_ limit: Duration) async -> Bool { true }
    var terminationStatus: Int32? { 0 }
    func stderrTail() -> String { "" }
    var stdinData: Data { lock.withLock { bytes } }
}

@Test func pronunciationPreferencesPersistReferencesButNeverKeys() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-pron-settings-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = PronunciationTestSecrets()
    let store = try PronunciationSettingsStore(directory: directory, secrets: secrets)
    try await store.updateAccent(.uk)
    try await store.updateVoice("Samantha", accent: .us)
    try await store.updateWikimediaContact("person@example.test")
    try await store.saveKey(provider: .forvo, key: "forvo-private-test-key")
    try await store.saveKey(provider: .merriamWebster, key: "mw-private-test-key")

    let preferences = await store.preferences()
    #expect(preferences.accent == .uk)
    #expect(preferences.voice == "Samantha")
    #expect(preferences.forvoAccount != nil)
    #expect(preferences.merriamWebsterAccount != nil)
    #expect(preferences.forvoAccount != preferences.merriamWebsterAccount)
    let onDisk = try String(contentsOf: directory.appendingPathComponent("preferences.json"), encoding: .utf8)
    #expect(!onDisk.contains("private-test-key"))
    let online = try await store.requestPayload(term: "epitome", offline: false)
    let onlineJSON = try #require(JSONSerialization.jsonObject(with: online) as? [String: Any])
    #expect(onlineJSON["forvo_key"] as? String == "forvo-private-test-key")
    #expect(onlineJSON["mw_key"] as? String == "mw-private-test-key")
    #expect(onlineJSON["wikimedia_user_agent"] as? String == "Glacier/0.1 contact=person@example.test")
    #expect(onlineJSON["accent"] as? String == "uk")
    let readsBeforeOffline = secrets.readCount
    let offline = try await store.requestPayload(term: "epitome", offline: true)
    let offlineJSON = try #require(JSONSerialization.jsonObject(with: offline) as? [String: Any])
    #expect(offlineJSON["offline"] as? Bool == true)
    #expect(offlineJSON["forvo_key"] == nil)
    #expect(offlineJSON["mw_key"] == nil)
    #expect(offlineJSON["wikimedia_user_agent"] == nil)
    #expect(secrets.readCount == readsBeforeOffline)

    try await store.clearKey(provider: .forvo)
    #expect((await store.preferences()).forvoAccount == nil)
    #expect(secrets.count == 1)
}

@Test func pronunciationClientWritesOnlyBoundedJSONThroughStdin() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-pron-request-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try PronunciationSettingsStore(directory: directory, secrets: PronunciationTestSecrets())
    let process = PayloadProcess()
    let client = GlacierPronunciationClient(processFactory: { _ in process }, requestPayload: { term in
        try await store.requestPayload(term: term, offline: true)
    })
    _ = try await client.producer("hello /g literal") { _ in }
    let object = try #require(JSONSerialization.jsonObject(with: process.stdinData) as? [String: Any])
    #expect(object["term"] as? String == "hello /g literal")
    #expect(object["offline"] as? Bool == true)
    #expect(object["forvo_key"] == nil)
}

@Test func pronunciationPreferencesRejectHeaderInjection() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-pron-invalid-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try PronunciationSettingsStore(directory: directory, secrets: PronunciationTestSecrets())
    await #expect(throws: PronunciationSettingsError.self) {
        try await store.updateWikimediaContact("person@example.test\r\nX-Injected: yes")
    }
}

@Test func pronunciationPreferencesRejectCrossProviderAccountOnReload() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-pron-cross-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var preferences = PronunciationPreferences()
    let shared = UUID()
    preferences.forvoAccount = shared
    preferences.merriamWebsterAccount = shared
    try JSONEncoder().encode(preferences).write(to: directory.appendingPathComponent("preferences.json"))
    #expect(throws: PronunciationSettingsError.self) {
        _ = try PronunciationSettingsStore(directory: directory, secrets: PronunciationTestSecrets())
    }
}
