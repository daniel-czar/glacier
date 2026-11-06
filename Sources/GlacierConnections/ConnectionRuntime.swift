import Foundation
import OmniCore
import OmniModels

public enum ConnectionCredentialTestStatus: String, Sendable, Equatable {
    case unknown
    case rejected
    case notRequired
}

/// A test establishes only that the selected endpoint responded. GET may not
/// be supported by a generation endpoint, so success never implies a model is
/// qualified or that generation will work.
public struct ConnectionTestResult: Sendable, Equatable {
    public let provider: ConnectionProvider
    public let origin: ConnectionOrigin
    public let statusCode: Int
    public let credentialStatus: ConnectionCredentialTestStatus
}

public extension ConnectionStore {
    /// One gateway is injected into both durable drivers and ephemeral stream
    /// paths. No historical private qualification ledger is fabricated.
    func makeRuntimeBrokerStore(
        commands: [ModelCommandRouteSettings] = [],
        network: any ConnectionNetworkTransport = NoRedirectURLSessionTransport(),
        gate: @escaping @Sendable (URL) throws -> Void = { _ in },
        environment: @escaping @Sendable (String) -> String? = { ProcessInfo.processInfo.environment[$0] }
    ) throws -> ProviderRuntimeBrokerStore {
        let cerebrasKey = credentialResolver(for: .cerebras, environment: environment)
        let openRouterKey = credentialResolver(for: .openRouter, environment: environment)
        let openAIKey = credentialResolver(for: .openAI, environment: environment)
        let anthropicKey = credentialResolver(for: .anthropic, environment: environment)
        let cerebras = ApprovedOriginTransport(store: self, provider: .cerebras, base: network, gate: gate)
        let openRouter = ApprovedOriginTransport(store: self, provider: .openRouter, base: network, gate: gate)
        let openAI = ApprovedOriginTransport(store: self, provider: .openAI, base: network, gate: gate)
        let anthropic = ApprovedOriginTransport(store: self, provider: .anthropic, base: network, gate: gate)
        let ollama = ApprovedOriginTransport(store: self, provider: .ollama, base: network, gate: gate)
        let drivers: [any ModelProviderDriver] = [
            CerebrasHTTPDriver(transport: cerebras, credentials: cerebrasKey, streamingTransport: cerebras),
            OpenRouterHTTPDriver(transport: openRouter, credentials: openRouterKey),
            OpenAIHTTPDriver(transport: openAI, credentials: openAIKey),
            AnthropicHTTPDriver(transport: anthropic, credentials: anthropicKey),
            OllamaHTTPDriver(transport: ollama),
        ]
        let registry = try ModelProviderRegistry(drivers: drivers)
        let broker = try ProviderRuntimeBroker(registry: registry, settings: runtimeSettings(commands: commands))
        return ProviderRuntimeBrokerStore(broker: broker)
    }

    /// Sends one small GET only after the user explicitly selects Test. The
    /// result names the provider and approved destination, never the key.
    func testConnection(
        _ id: String,
        network: any ConnectionNetworkTransport = NoRedirectURLSessionTransport(),
        environment: @escaping @Sendable (String) -> String? = { ProcessInfo.processInfo.environment[$0] },
        gate: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) async throws -> ConnectionTestResult {
        guard let item = profile(id), item.enabled else { throw ConnectionError.invalidProfile }
        guard item.isReadyForCredential else { throw ConnectionError.originApprovalRequired }
        var request = URLRequest(url: item.provider == .ollama
                                 ? item.endpoint.appendingPathComponent("api/tags") : item.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Glacier/0.1", forHTTPHeaderField: "User-Agent")
        // Offline/AI-pause decisions are checked before even reading a key.
        // The transport checks again immediately before any network activity.
        guard let destination = request.url else { throw ConnectionError.unsafeDestination }
        try gate(destination)
        if let source = item.credentialSource {
            let secret = try credentialResolver(for: item.provider, environment: environment).resolve(source.modelReference)
            switch item.provider {
            case .anthropic:
                secret.apply(to: &request, header: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            case .cerebras, .openRouter, .openAI:
                secret.apply(to: &request, header: "Authorization", prefix: "Bearer ")
            case .ollama: break
            }
        } else if item.provider.requiresCredential { throw ConnectionError.missingCredential }
        let transport = ApprovedOriginTransport(store: self, provider: item.provider, base: network, gate: gate)
        let response = try await transport.exchange(request)
        let status: ConnectionCredentialTestStatus = item.provider == .ollama ? .notRequired
            : ([401, 403].contains(response.statusCode) ? .rejected : .unknown)
        return ConnectionTestResult(provider: item.provider, origin: item.origin,
                                    statusCode: response.statusCode, credentialStatus: status)
    }
}
