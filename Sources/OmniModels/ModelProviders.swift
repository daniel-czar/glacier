import Foundation
import OmniCore

public struct ModelHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// URLSession-compatible transport boundary. Tests inject fixtures here; this
/// package never loads credentials or performs a request merely by composing a
/// provider.
public protocol ModelHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ModelHTTPResponse
}

public struct URLSessionModelTransport: ModelHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> ModelHTTPResponse {
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelProviderTransportError.invalidResponse }
        return ModelHTTPResponse(statusCode: http.statusCode, body: body)
    }
}

public enum ModelProviderTransportError: Error, Sendable, Equatable {
    case unsupportedEndpoint
    case nonLocalOllamaEndpoint
    case invalidResponse
    case status(Int)
    case malformedPayload
}

public struct ModelProviderConfiguration: Sendable, Equatable {
    public let descriptor: ModelProviderDescriptor
    public let endpoint: URL
    public let model: String
    public let timeoutSeconds: TimeInterval
    public let maximumResponseBytes: Int

    public init(
        descriptor: ModelProviderDescriptor,
        endpoint: URL,
        model: String,
        timeoutSeconds: TimeInterval = 120,
        maximumResponseBytes: Int = 1_000_000
    ) throws {
        guard !descriptor.providerID.isEmpty,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let scheme = endpoint.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              timeoutSeconds > 0 && timeoutSeconds <= 120,
              maximumResponseBytes > 0 && maximumResponseBytes <= 1_000_000
        else { throw ModelProviderTransportError.unsupportedEndpoint }
        self.descriptor = descriptor
        self.endpoint = endpoint
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        self.maximumResponseBytes = maximumResponseBytes
    }
}

/// Historical policy 4.0.0 local adapter retained for the synthetic local
/// harness. Policy 6.0.0 composition uses `OllamaHTTPDriver`.
public struct OllamaModelProvider: ModelProvider {
    public let descriptor: ModelProviderDescriptor
    private let endpoint: URL
    private let model: String
    private let timeoutSeconds: TimeInterval
    private let maximumResponseBytes: Int
    private let transport: any ModelHTTPTransport

    public init(configuration: ModelProviderConfiguration, transport: any ModelHTTPTransport) throws {
        guard !configuration.descriptor.isRemote,
              (configuration.descriptor.providerClass == .localFast || configuration.descriptor.providerClass == .localCapable),
              Self.isLoopback(configuration.endpoint.host)
        else { throw ModelProviderTransportError.nonLocalOllamaEndpoint }
        descriptor = configuration.descriptor
        endpoint = configuration.endpoint.appendingPathComponent("api/generate")
        model = configuration.model
        timeoutSeconds = configuration.timeoutSeconds
        maximumResponseBytes = configuration.maximumResponseBytes
        self.transport = transport
    }

    public func generate(_ request: ModelGenerationRequest) async throws -> ModelProviderResponse {
        var http = URLRequest(url: endpoint)
        http.httpMethod = "POST"
        http.timeoutInterval = timeoutSeconds
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "prompt": request.prompt,
            "stream": false,
            "think": false,
            "options": ["num_predict": 2048, "num_ctx": 16384],
        ]
        if request.outputConstraint.shape.requestsJSONObject {
            body["format"] = "json"
        }
        http.httpBody = try JSONSerialization.data(withJSONObject: body)
        let response = try await transport.send(http)
        guard (200..<300).contains(response.statusCode) else { throw ModelProviderTransportError.status(response.statusCode) }
        guard response.body.count <= maximumResponseBytes else { throw ModelProviderTransportError.malformedPayload }
        guard let payload = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let text = payload["response"] as? String
        else { throw ModelProviderTransportError.malformedPayload }
        return ModelProviderResponse(
            text: text,
            usage: ModelUsage(
                inputTokens: payload["prompt_eval_count"] as? Int,
                outputTokens: payload["eval_count"] as? Int
            )
        )
    }

    private static func isLoopback(_ host: String?) -> Bool {
        switch host?.lowercased() {
        case "localhost", "127.0.0.1", "::1": true
        default: false
        }
    }
}
