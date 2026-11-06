import Foundation
import GlacierConfiguration
import GlacierConnections
import GlacierModuleKit
import OmniAdapters
import OmniModels

public struct GlacierSmokeReceipt: Codable, Sendable {
    public let application: String
    public let localCommandSucceeded: Bool
    public let supportRoot: String
    public let registeredGlobalShortcuts: Int
    public let configuredSecretReferences: Int
    public let networkRequests: Int
    public let availableModuleDefinitions: Int
}
public enum GlacierSmoke {
    /// Uses the real production factory, a synthetic root, and effects that fail closed.
    public static func check(root: URL) async throws -> GlacierSmokeReceipt {
        guard root.isFileURL else { throw GlacierRuntimeError.unavailable("An absolute test root is required") }
        let paths = try GlacierPaths(home: root.appendingPathComponent("home"), supportOverride: root.appendingPathComponent("Glacier"))
        let actions = await GlacierHostActions()
        let network = NoNetwork()
        let secrets = NoSecrets()
        let composition = try await GlacierComposition.make(paths: paths, home: root.appendingPathComponent("home"), hostActions: actions,
            applicationRoots: [], network: network, secrets: secrets, platform: RecordingPlatformAdapter(), fileEffect: { _, _ in throw GlacierRuntimeError.unavailable("OS actions are disabled in smoke checks") })
        let response = try await composition.service.submit("/span 1 October 2014 to 30 September 2016")
        guard let id = response.runID else { throw GlacierRuntimeError.unavailable("Local command did not start") }
        let result = try await composition.service.waitForTerminal(runID: id)
        let references = await composition.connections.snapshot().profiles.filter { $0.credentialSource != nil }.count
        _ = await composition.service.shutdown()
        return GlacierSmokeReceipt(application: "local.Glacier.Development", localCommandSucceeded: result.state == .succeeded && network.count == 0 && secrets.count == 0,
            supportRoot: paths.support.path, registeredGlobalShortcuts: 0, configuredSecretReferences: references, networkRequests: network.count,
            availableModuleDefinitions: GlacierModuleKit.ModuleRegistry.builtIn.descriptors.count)
    }
    private final class NoNetwork: ConnectionNetworkTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        var count: Int { lock.withLock { attempts } }
        private func mark() { lock.withLock { attempts += 1 } }
        func exchange(_ request: URLRequest) async throws -> ModelHTTPExchange { mark(); throw GlacierRuntimeError.unavailable("Network forbidden in smoke checks") }
        func stream(_ request: URLRequest) async throws -> ModelHTTPByteStream { mark(); throw GlacierRuntimeError.unavailable("Network forbidden in smoke checks") }
    }
    private final class NoSecrets: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        var count: Int { lock.withLock { attempts } }
        private func mark() { lock.withLock { attempts += 1 } }
        func insert(_ secret: String, account: UUID) throws { mark(); throw GlacierRuntimeError.unavailable("Keychain forbidden in smoke checks") }
        func read(account: UUID) throws -> String { mark(); throw GlacierRuntimeError.unavailable("Keychain forbidden in smoke checks") }
        func remove(account: UUID) throws { mark(); throw GlacierRuntimeError.unavailable("Keychain forbidden in smoke checks") }
    }
}
