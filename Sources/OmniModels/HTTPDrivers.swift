import Foundation
import OmniCore

// MARK: - Shared chat-completions adapter (Cerebras, OpenAI)

/// OpenAI-compatible `chat/completions` request/response translation. The
/// credential is resolved lazily per attempt through the injected resolver and
/// applied only to the outgoing request header.
struct ChatCompletionsAdapter: Sendable {
    let transport: any ModelHTTPExchangeTransport
    let credentials: any ModelCredentialResolver
    let userAgent: String

    /// OpenAI-style body: `reasoningKey` carries the profile's reasoning level
    /// (omitted when the provider has no literal for `none`).
    func generate(
        _ request: ModelDriverRequest,
        authRoute: ModelAuthRoute,
        reasoningKey: String?,
        allowsNoneReasoning: Bool
    ) async throws -> ModelDriverResponse {
        var body = try standardBody(request)
        if let reasoning = request.profile.options.reasoning {
            guard let reasoningKey else { throw ModelDriverFailure(.unsupportedCapability, detail: "reasoning level unsupported") }
            if reasoning == .none, !allowsNoneReasoning {
                // Omit rather than transmit an unsupported literal.
            } else {
                body[reasoningKey] = reasoning.rawValue
            }
        }
        let payload = try await send(body, for: request)
        return try completion(from: payload, request: request, authRoute: authRoute)
    }

    /// `model`, `messages`, output limit, temperature and JSON response format;
    /// reasoning is provider-specific and added by the caller.
    func standardBody(_ request: ModelDriverRequest) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": request.profile.modelSelector,
            "messages": [["role": "user", "content": request.generation.prompt]],
        ]
        if let tokens = request.profile.options.maximumOutputTokens { body["max_completion_tokens"] = tokens }
        if let temperature = request.profile.options.temperature { body["temperature"] = temperature }
        if request.wantsJSONObject { body["response_format"] = ["type": "json_object"] }
        return body
    }

    /// Resolves the credential per attempt, posts the body and returns the
    /// decoded JSON object. Transport and HTTP status failures are classified.
    func send(_ body: [String: Any], for request: ModelDriverRequest, headers: [String: String] = [:]) async throws -> [String: Any] {
        let http = try makeRequest(body, for: request, headers: headers)
        let exchange: ModelHTTPExchange
        do { exchange = try await transport.exchange(http) } catch { throw ProviderHTTP.mapTransportError(error) }
        try Task.checkCancellation()
        guard (200..<300).contains(exchange.statusCode) else {
            throw ProviderHTTP.classify(status: exchange.statusCode, body: exchange.body, retryAfter: ProviderHTTP.retryAfterSeconds(from: exchange.headers))
        }
        guard exchange.body.count <= request.maximumResponseBytes else {
            throw ModelDriverFailure(.contextOrOutputLimit, detail: "response exceeds \(request.maximumResponseBytes) bytes")
        }
        guard let payload = try? JSONSerialization.jsonObject(with: exchange.body) as? [String: Any] else {
            throw ModelDriverFailure(.invalidResponse, detail: "response is not a JSON object")
        }
        return payload
    }

    func makeRequest(_ body: [String: Any], for request: ModelDriverRequest, headers: [String: String] = [:], accept: String = "application/json") throws -> URLRequest {
        guard let endpoint = request.connection.endpoint, endpoint.scheme?.lowercased() == "https" else {
            throw ModelDriverFailure(.needsConfiguration, detail: "connection has no https endpoint")
        }
        guard let reference = request.connection.credentialReference else {
            throw ModelDriverFailure(.needsConfiguration, detail: "connection has no credential reference")
        }
        let secret: ModelResolvedSecret
        do { secret = try credentials.resolve(reference) } catch let error as ModelCredentialError {
            throw ModelDriverFailure(.authRequired, detail: error.description)
        }

        var http = URLRequest(url: endpoint)
        http.httpMethod = "POST"
        http.timeoutInterval = max(1, ContinuousClock().now.duration(to: request.deadline).seconds)
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue(accept, forHTTPHeaderField: "Accept")
        http.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (field, value) in headers { http.setValue(value, forHTTPHeaderField: field) }
        http.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        secret.apply(to: &http, header: "Authorization", prefix: "Bearer ")
        return http
    }

    /// First-choice text, usage, finish reason and model identity of a
    /// chat-completions payload. `requestedModel` defaults to the selector.
    func completion(from payload: [String: Any], request: ModelDriverRequest, authRoute: ModelAuthRoute, requestedModel: String? = nil) throws -> ModelDriverResponse {
        let resolvedModel = payload["model"] as? String
        guard let choices = payload["choices"] as? [[String: Any]], let first = choices.first else {
            throw ModelDriverFailure(.invalidResponse, detail: "response has no choices", resolvedModel: resolvedModel)
        }
        let usagePayload = payload["usage"] as? [String: Any]
        let details = usagePayload?["completion_tokens_details"] as? [String: Any]
        let usage = ModelUsage(
            inputTokens: usagePayload?["prompt_tokens"] as? Int,
            outputTokens: usagePayload?["completion_tokens"] as? Int,
            reasoningTokens: details?["reasoning_tokens"] as? Int
        )
        let finish = first["finish_reason"] as? String
        guard let message = first["message"] as? [String: Any] else {
            throw ModelDriverFailure(.invalidResponse, detail: "choice has no message", resolvedModel: resolvedModel, usage: usage)
        }
        // Reasoning-capable models (Qwen 3.8 on Cerebras, observed 2026-09-09)
        // prefix the answer with blank lines once their reasoning is stripped
        // server-side; the presentable text is the trimmed completion.
        let content = ((message["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if finish == "length" {
            throw ModelDriverFailure(.contextOrOutputLimit, detail: "completion truncated at the output limit", resolvedModel: resolvedModel, usage: usage)
        }
        if finish == "content_filter" {
            throw ModelDriverFailure(.providerFailure, detail: "provider content filter", resolvedModel: resolvedModel, usage: usage)
        }
        guard !content.isEmpty else {
            throw ModelDriverFailure(.invalidResponse, detail: "empty completion", resolvedModel: resolvedModel, usage: usage)
        }
        let requested = requestedModel ?? request.profile.modelSelector
        if let resolvedModel, !Self.modelMatches(requested: requested, resolved: resolvedModel) {
            throw ModelDriverFailure(.modelMismatch, detail: "requested \(request.profile.modelSelector) but provider answered with \(resolvedModel)", resolvedModel: resolvedModel, usage: usage)
        }
        return ModelDriverResponse(
            text: content,
            usage: usage,
            observedAuthRoute: authRoute,
            resolvedModel: resolvedModel,
            nativeReference: (payload["id"] as? String).map { String($0.prefix(48)) }
        )
    }

    /// Exact identity, or a dated/tagged snapshot of the requested selector.
    /// A shorter provider name never matches a more specific request.
    static func modelMatches(requested: String, resolved: String) -> Bool {
        let r = requested.lowercased(), a = resolved.lowercased()
        return a == r || a.hasPrefix(r + "-") || a.hasPrefix(r + ":")
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let (s, attos) = components
        return TimeInterval(s) + TimeInterval(attos) / 1e18
    }
}

// MARK: - Cerebras

public struct CerebrasHTTPDriver: ModelStreamingProviderDriver {
    public let driverID: ModelDriverID = .cerebrasHTTP
    public let capabilities: Set<ModelCapability> = [.plainText, .structuredJSONObject, .reasoningLevel, .outputTokenLimit, .temperature]
    private let adapter: ChatCompletionsAdapter
    private let streamingTransport: (any ModelHTTPStreamingTransport)?

    public init(transport: any ModelHTTPExchangeTransport, credentials: any ModelCredentialResolver, streamingTransport: (any ModelHTTPStreamingTransport)? = nil) {
        adapter = ChatCompletionsAdapter(transport: transport, credentials: credentials, userAgent: "Glacier/0.1")
        self.streamingTransport = streamingTransport ?? (transport as? any ModelHTTPStreamingTransport)
    }

    public func configurationIssue(for connection: ModelConnectionProfile) -> ModelFailureKind? {
        guard connection.driverID == driverID else { return .unconfigured }
        guard let endpoint = connection.endpoint, endpoint.scheme?.lowercased() == "https", endpoint.host?.lowercased().hasSuffix("cerebras.ai") == true else { return .needsConfiguration }
        guard connection.credentialReference != nil else { return .needsConfiguration }
        return nil
    }

    public func probe(connection: ModelConnectionProfile) async -> ModelConnectionProbe {
        // Credential presence only; no request is sent for a probe.
        guard let reference = connection.credentialReference else {
            return ModelConnectionProbe(availability: .needsConfiguration, detail: "no credential reference")
        }
        do {
            _ = try adapter.credentials.resolve(reference)
            return ModelConnectionProbe(availability: .unverified, detail: "credential reference resolvable; route verified per attempt")
        } catch {
            return ModelConnectionProbe(availability: .needsConfiguration, detail: String(describing: error))
        }
    }

    public func generate(_ request: ModelDriverRequest) async throws -> ModelDriverResponse {
        guard request.connection.authRoute == .cerebrasAPIKey else { throw ModelDriverFailure(.authMismatch, detail: "connection is not a Cerebras API-key route") }
        return try await adapter.generate(request, authRoute: .cerebrasAPIKey, reasoningKey: "reasoning_effort", allowsNoneReasoning: true)
    }

    public func stream(_ request: ModelDriverRequest, onText: @escaping @Sendable (String) async -> Void) async throws -> ModelDriverResponse {
        guard request.connection.authRoute == .cerebrasAPIKey else { throw ModelDriverFailure(.authMismatch, detail: "connection is not a Cerebras API-key route") }
        guard let streamingTransport else { throw ModelDriverFailure(.unsupportedCapability, detail: "streaming transport unavailable") }
        var body = try adapter.standardBody(request)
        if let reasoning = request.profile.options.reasoning { body["reasoning_effort"] = reasoning.rawValue }
        body["stream"] = true
        body["stream_options"] = ["include_usage": true]
        let http = try adapter.makeRequest(body, for: request, accept: "text/event-stream")
        let exchange: ModelHTTPByteStream
        do { exchange = try await streamingTransport.stream(http) } catch { throw ProviderHTTP.mapTransportError(error) }
        // Cancels the producer on DONE, parser failure, status rejection, or
        // task cancellation; the URLSession byte iterator then stops its task.
        defer { exchange.cancel() }
        try Task.checkCancellation()
        guard (200..<300).contains(exchange.statusCode) else {
            // An SSE error body can echo user content. Status alone is safe.
            throw ProviderHTTP.classify(status: exchange.statusCode, body: Data(), retryAfter: ProviderHTTP.retryAfterSeconds(from: exchange.headers))
        }
        return try await CerebrasSSECompletion.consume(exchange.chunks, request: request, onText: onText)
    }
}

// MARK: - OpenRouter

/// OpenRouter's chat API: the model selector is an OpenRouter model ID
/// (optionally with an OpenRouter variant suffix such as `:nitro`), reasoning
/// travels in OpenRouter's `reasoning` object, and provider preferences ask for
/// the lowest-latency upstream without data collection. The response names the
/// upstream that served the request (`servedBy`) and the billed cost.
public struct OpenRouterHTTPDriver: ModelProviderDriver {
    public let driverID: ModelDriverID = .openRouterHTTP
    public let capabilities: Set<ModelCapability> = [.plainText, .structuredJSONObject, .reasoningLevel, .outputTokenLimit, .temperature]
    private let adapter: ChatCompletionsAdapter
    /// Fixed routing preferences: a command bar wants the fastest available
    /// upstream, never one that retains prompts. `require_parameters` keeps the
    /// router from dropping the reasoning/format controls silently.
    public static var providerPreferences: [String: Any] { ["sort": "latency", "data_collection": "deny", "require_parameters": true] }
    public static let attributionHeaders = ["X-Title": "Glacier"]

    public init(transport: any ModelHTTPExchangeTransport, credentials: any ModelCredentialResolver) {
        adapter = ChatCompletionsAdapter(transport: transport, credentials: credentials, userAgent: "Glacier/0.1")
    }

    public func configurationIssue(for connection: ModelConnectionProfile) -> ModelFailureKind? {
        guard connection.driverID == driverID else { return .unconfigured }
        guard let endpoint = connection.endpoint, endpoint.scheme?.lowercased() == "https", endpoint.host?.lowercased() == "openrouter.ai" else { return .needsConfiguration }
        guard connection.credentialReference != nil else { return .needsConfiguration }
        return nil
    }

    public func probe(connection: ModelConnectionProfile) async -> ModelConnectionProbe {
        guard connection.enabled else { return ModelConnectionProbe(availability: .disabled) }
        guard let reference = connection.credentialReference else {
            return ModelConnectionProbe(availability: .needsConfiguration, detail: "no credential reference")
        }
        do {
            _ = try adapter.credentials.resolve(reference)
            return ModelConnectionProbe(availability: .unverified, detail: "credential reference resolvable; upstream verified per attempt")
        } catch {
            return ModelConnectionProbe(availability: .needsConfiguration, detail: String(describing: error))
        }
    }

    public func generate(_ request: ModelDriverRequest) async throws -> ModelDriverResponse {
        guard request.connection.authRoute == .openRouterAPIKey else { throw ModelDriverFailure(.authMismatch, detail: "connection is not an OpenRouter API-key route") }
        let body = try Self.body(for: request, standard: adapter.standardBody(request))
        let payload = try await adapter.send(body, for: request, headers: Self.attributionHeaders)
        let base = try adapter.completion(from: payload, request: request, authRoute: .openRouterAPIKey, requestedModel: Self.canonicalModelID(request.profile.modelSelector))
        let usagePayload = payload["usage"] as? [String: Any]
        return ModelDriverResponse(
            text: base.text,
            usage: base.usage,
            observedAuthRoute: .openRouterAPIKey,
            resolvedModel: base.resolvedModel,
            nativeReference: base.nativeReference,
            servedBy: payload["provider"] as? String,
            estimatedCostUSD: usagePayload?["cost"] as? Double
        )
    }

    /// OpenRouter body: OpenAI-style core plus the `reasoning` object,
    /// `max_tokens`, provider preferences and per-request cost accounting.
    static func body(for request: ModelDriverRequest, standard: [String: Any]) throws -> [String: Any] {
        var body = standard
        if let tokens = body.removeValue(forKey: "max_completion_tokens") { body["max_tokens"] = tokens }
        if let reasoning = request.profile.options.reasoning {
            body["reasoning"] = reasoning == .none ? ["enabled": false] : ["effort": reasoning.rawValue]
        }
        body["provider"] = providerPreferences
        body["usage"] = ["include": true]
        return body
    }

    /// OpenRouter echoes the canonical model ID without a requested variant
    /// suffix (`:nitro`, `:floor`, `:free`, `:online`), so matching uses the
    /// base ID.
    public static func canonicalModelID(_ selector: String) -> String {
        guard let slash = selector.firstIndex(of: "/"), let colon = selector[slash...].firstIndex(of: ":") else { return selector }
        return String(selector[..<colon])
    }
}

// MARK: - OpenAI API (optional alternative, disabled by default)

public struct OpenAIHTTPDriver: ModelProviderDriver {
    public let driverID: ModelDriverID = .openAIHTTP
    public let capabilities: Set<ModelCapability> = [.plainText, .structuredJSONObject, .reasoningLevel, .outputTokenLimit, .temperature]
    private let adapter: ChatCompletionsAdapter

    public init(transport: any ModelHTTPExchangeTransport, credentials: any ModelCredentialResolver) {
        adapter = ChatCompletionsAdapter(transport: transport, credentials: credentials, userAgent: "Glacier/0.1")
    }

    public func configurationIssue(for connection: ModelConnectionProfile) -> ModelFailureKind? {
        guard connection.driverID == driverID else { return .unconfigured }
        guard let endpoint = connection.endpoint, endpoint.scheme?.lowercased() == "https" else { return .needsConfiguration }
        guard connection.credentialReference != nil else { return .needsConfiguration }
        return nil
    }

    public func probe(connection: ModelConnectionProfile) async -> ModelConnectionProbe {
        guard connection.enabled else { return ModelConnectionProbe(availability: .disabled) }
        guard let reference = connection.credentialReference else { return ModelConnectionProbe(availability: .needsConfiguration, detail: "no credential reference") }
        do {
            _ = try adapter.credentials.resolve(reference)
            return ModelConnectionProbe(availability: .unverified, detail: "credential reference resolvable; explicit route permission still required")
        } catch {
            return ModelConnectionProbe(availability: .needsConfiguration, detail: String(describing: error))
        }
    }

    public func generate(_ request: ModelDriverRequest) async throws -> ModelDriverResponse {
        guard request.connection.authRoute == .openAIAPIKey else { throw ModelDriverFailure(.authMismatch, detail: "connection is not an OpenAI API-key route") }
        // OpenAI's Responses/Chat reasoning_effort has no "none" literal.
        return try await adapter.generate(request, authRoute: .openAIAPIKey, reasoningKey: "reasoning_effort", allowsNoneReasoning: false)
    }
}

// MARK: - Anthropic Messages API (optional alternative, disabled by default)

public struct AnthropicHTTPDriver: ModelProviderDriver {
    public let driverID: ModelDriverID = .anthropicHTTP
    public let capabilities: Set<ModelCapability> = [.plainText, .structuredJSONObject, .reasoningLevel, .outputTokenLimit, .temperature]
    private let transport: any ModelHTTPExchangeTransport
    private let credentials: any ModelCredentialResolver
    public static let apiVersion = "2023-06-01"

    public init(transport: any ModelHTTPExchangeTransport, credentials: any ModelCredentialResolver) {
        self.transport = transport
        self.credentials = credentials
    }

    public func configurationIssue(for connection: ModelConnectionProfile) -> ModelFailureKind? {
        guard connection.driverID == driverID else { return .unconfigured }
        guard let endpoint = connection.endpoint, endpoint.scheme?.lowercased() == "https" else { return .needsConfiguration }
        guard connection.credentialReference != nil else { return .needsConfiguration }
        return nil
    }

    public func probe(connection: ModelConnectionProfile) async -> ModelConnectionProbe {
        guard connection.enabled else { return ModelConnectionProbe(availability: .disabled) }
        guard let reference = connection.credentialReference else { return ModelConnectionProbe(availability: .needsConfiguration, detail: "no credential reference") }
        do {
            _ = try credentials.resolve(reference)
            return ModelConnectionProbe(availability: .unverified, detail: "credential reference resolvable; explicit route permission still required")
        } catch {
            return ModelConnectionProbe(availability: .needsConfiguration, detail: String(describing: error))
        }
    }

    public func generate(_ request: ModelDriverRequest) async throws -> ModelDriverResponse {
        guard request.connection.authRoute == .anthropicAPIKey else { throw ModelDriverFailure(.authMismatch, detail: "connection is not an Anthropic API-key route") }
        guard let endpoint = request.connection.endpoint, endpoint.scheme?.lowercased() == "https" else {
            throw ModelDriverFailure(.needsConfiguration, detail: "connection has no https endpoint")
        }
        guard let reference = request.connection.credentialReference else {
            throw ModelDriverFailure(.needsConfiguration, detail: "connection has no credential reference")
        }
        let secret: ModelResolvedSecret
        do { secret = try credentials.resolve(reference) } catch let error as ModelCredentialError {
            throw ModelDriverFailure(.authRequired, detail: error.description)
        }
        let maxTokens = request.profile.options.maximumOutputTokens ?? 2_048
        var body: [String: Any] = [
            "model": request.profile.modelSelector,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": request.generation.prompt]],
        ]
        if request.wantsJSONObject {
            body["system"] = "Return exactly one JSON object and nothing else."
        }
        if let reasoning = request.profile.options.reasoning, reasoning != .none {
            // Extended thinking: the budget must fit inside the configured output
            // limit, and Anthropic rejects temperature with thinking enabled.
            // Unsupported combinations are rejected, never silently altered.
            if request.profile.options.temperature != nil {
                throw ModelDriverFailure(.unsupportedCapability, detail: "temperature cannot be combined with extended thinking on this profile")
            }
            let budget: Int = switch reasoning {
            case .minimal, .low: 1_024
            case .medium: 2_048
            case .high, .xhigh: 4_096
            case .none: 0
            }
            guard maxTokens >= budget + 512 else {
                throw ModelDriverFailure(.unsupportedCapability, detail: "maximumOutputTokens \(maxTokens) is too small for a \(reasoning.rawValue) thinking budget of \(budget)")
            }
            body["thinking"] = ["type": "enabled", "budget_tokens": budget]
        } else if let temperature = request.profile.options.temperature {
            body["temperature"] = temperature
        }
        var http = URLRequest(url: endpoint)
        http.httpMethod = "POST"
        http.timeoutInterval = 180
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        http.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        http.setValue("Glacier/0.1", forHTTPHeaderField: "User-Agent")
        http.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        secret.apply(to: &http, header: "x-api-key")

        let exchange: ModelHTTPExchange
        do { exchange = try await transport.exchange(http) } catch { throw ProviderHTTP.mapTransportError(error) }
        try Task.checkCancellation()
        guard (200..<300).contains(exchange.statusCode) else {
            var failure = ProviderHTTP.classify(status: exchange.statusCode, body: exchange.body, retryAfter: ProviderHTTP.retryAfterSeconds(from: exchange.headers))
            if exchange.statusCode == 529 { failure = ModelDriverFailure(.rateLimited, detail: "HTTP 529 overloaded", retryAfterSeconds: failure.retryAfterSeconds) }
            throw failure
        }
        guard exchange.body.count <= request.maximumResponseBytes else {
            throw ModelDriverFailure(.contextOrOutputLimit, detail: "response exceeds \(request.maximumResponseBytes) bytes")
        }
        guard let payload = try? JSONSerialization.jsonObject(with: exchange.body) as? [String: Any] else {
            throw ModelDriverFailure(.invalidResponse, detail: "response is not a JSON object")
        }
        let resolvedModel = payload["model"] as? String
        let usagePayload = payload["usage"] as? [String: Any]
        let usage = ModelUsage(inputTokens: usagePayload?["input_tokens"] as? Int, outputTokens: usagePayload?["output_tokens"] as? Int)
        guard let content = payload["content"] as? [[String: Any]] else {
            throw ModelDriverFailure(.invalidResponse, detail: "response has no content", resolvedModel: resolvedModel, usage: usage)
        }
        let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        let stop = payload["stop_reason"] as? String
        if stop == "max_tokens" {
            throw ModelDriverFailure(.contextOrOutputLimit, detail: "completion truncated at max_tokens", resolvedModel: resolvedModel, usage: usage)
        }
        if stop == "refusal" {
            throw ModelDriverFailure(.providerFailure, detail: "provider refusal", resolvedModel: resolvedModel, usage: usage)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelDriverFailure(.invalidResponse, detail: "empty completion", resolvedModel: resolvedModel, usage: usage)
        }
        if let resolvedModel, !ChatCompletionsAdapter.modelMatches(requested: request.profile.modelSelector, resolved: resolvedModel) {
            throw ModelDriverFailure(.modelMismatch, detail: "requested \(request.profile.modelSelector) but provider answered with \(resolvedModel)", resolvedModel: resolvedModel, usage: usage)
        }
        return ModelDriverResponse(
            text: text,
            usage: usage,
            observedAuthRoute: .anthropicAPIKey,
            resolvedModel: resolvedModel,
            nativeReference: (payload["id"] as? String).map { String($0.prefix(48)) }
        )
    }
}

// MARK: - Local Ollama

public struct OllamaHTTPDriver: ModelProviderDriver {
    public let driverID: ModelDriverID = .ollamaHTTP
    public let capabilities: Set<ModelCapability> = [.plainText, .structuredJSONObject, .outputTokenLimit, .temperature]
    private let transport: any ModelHTTPExchangeTransport

    public init(transport: any ModelHTTPExchangeTransport) {
        self.transport = transport
    }

    public func configurationIssue(for connection: ModelConnectionProfile) -> ModelFailureKind? {
        guard connection.driverID == driverID, !connection.isRemote else { return .unconfigured }
        guard let endpoint = connection.endpoint, Self.isLoopback(endpoint.host) else { return .needsConfiguration }
        return nil
    }

    /// Checks service reachability and installed model names without loading or
    /// starting a model. It never installs or starts a local service.
    public func probe(connection: ModelConnectionProfile) async -> ModelConnectionProbe {
        guard let endpoint = connection.endpoint, Self.isLoopback(endpoint.host) else {
            return ModelConnectionProbe(availability: .needsConfiguration, detail: "local endpoint must be loopback")
        }
        var http = URLRequest(url: endpoint.appendingPathComponent("api/tags"))
        http.httpMethod = "GET"
        http.timeoutInterval = 2
        do {
            let exchange = try await transport.exchange(http)
            guard (200..<300).contains(exchange.statusCode) else {
                return ModelConnectionProbe(availability: .needsConfiguration, detail: "local model service HTTP \(exchange.statusCode)")
            }
            guard exchange.body.count <= 1_000_000,
                  let payload = try? JSONSerialization.jsonObject(with: exchange.body) as? [String: Any],
                  let models = payload["models"] as? [[String: Any]],
                  models.allSatisfy({ $0["model"] is String || $0["name"] is String })
            else { return ModelConnectionProbe(availability: .needsConfiguration, detail: "local model list unavailable") }
            let selectors = Set(models.compactMap { ($0["model"] as? String) ?? ($0["name"] as? String) })
            return ModelConnectionProbe(availability: .ready, detail: "local service reachable", availableModelSelectors: selectors, observedAuthRoute: .localService)
        } catch {
            return ModelConnectionProbe(availability: .needsConfiguration, detail: "local model service not running")
        }
    }

    public func generate(_ request: ModelDriverRequest) async throws -> ModelDriverResponse {
        guard let endpoint = request.connection.endpoint, Self.isLoopback(endpoint.host), !request.connection.isRemote else {
            throw ModelDriverFailure(.needsConfiguration, detail: "local endpoint must be loopback")
        }
        var http = URLRequest(url: endpoint.appendingPathComponent("api/generate"))
        http.httpMethod = "POST"
        http.timeoutInterval = 120
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var options: [String: Any] = ["num_ctx": 16_384]
        options["num_predict"] = request.profile.options.maximumOutputTokens ?? 2_048
        if let temperature = request.profile.options.temperature { options["temperature"] = temperature }
        var body: [String: Any] = [
            "model": request.profile.modelSelector,
            "prompt": request.generation.prompt,
            "stream": false,
            "think": false,
            "options": options,
        ]
        if request.wantsJSONObject { body["format"] = "json" }
        http.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let exchange: ModelHTTPExchange
        do { exchange = try await transport.exchange(http) } catch { throw ProviderHTTP.mapTransportError(error) }
        try Task.checkCancellation()
        guard (200..<300).contains(exchange.statusCode) else {
            if exchange.statusCode == 404 { throw ModelDriverFailure(.modelMismatch, detail: "local model \(request.profile.modelSelector) is not installed") }
            throw ProviderHTTP.classify(status: exchange.statusCode, body: exchange.body, retryAfter: nil)
        }
        guard exchange.body.count <= request.maximumResponseBytes else {
            throw ModelDriverFailure(.contextOrOutputLimit, detail: "response exceeds \(request.maximumResponseBytes) bytes")
        }
        guard let payload = try? JSONSerialization.jsonObject(with: exchange.body) as? [String: Any],
              let text = payload["response"] as? String
        else { throw ModelDriverFailure(.invalidResponse, detail: "malformed local response") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelDriverFailure(.invalidResponse, detail: "empty local completion")
        }
        if payload["done_reason"] as? String == "length" {
            throw ModelDriverFailure(.contextOrOutputLimit, detail: "local completion truncated")
        }
        return ModelDriverResponse(
            text: text,
            usage: ModelUsage(inputTokens: payload["prompt_eval_count"] as? Int, outputTokens: payload["eval_count"] as? Int),
            observedAuthRoute: .localService,
            resolvedModel: payload["model"] as? String
        )
    }

    static func isLoopback(_ host: String?) -> Bool {
        switch host?.lowercased() {
        case "localhost", "127.0.0.1", "::1": true
        default: false
        }
    }
}

// MARK: - Fixture driver

/// Binds every connection of a fixture registry to a synthetic generator.
/// Attempts are marked as fixtures and never verify a live auth route.
public struct FixtureProviderDriver: ModelProviderDriver {
    public let driverID: ModelDriverID
    public let capabilities: Set<ModelCapability> = Set(ModelCapability.allCases)
    private let generator: @Sendable (ModelGenerationRequest) async throws -> ModelProviderResponse

    public init(driverID: ModelDriverID, generator: @escaping @Sendable (ModelGenerationRequest) async throws -> ModelProviderResponse) {
        self.driverID = driverID
        self.generator = generator
    }

    public func configurationIssue(for connection: ModelConnectionProfile) -> ModelFailureKind? { nil }

    public func probe(connection: ModelConnectionProfile) async -> ModelConnectionProbe {
        ModelConnectionProbe(availability: .ready, detail: "synthetic fixture; no live route")
    }

    public func generate(_ request: ModelDriverRequest) async throws -> ModelDriverResponse {
        let response = try await generator(request.generation)
        return ModelDriverResponse(text: response.text, usage: response.usage, resolvedModel: request.profile.modelSelector)
    }
}

/// Fixture registry helper: real catalogue identities, fixture-bound drivers
/// and synthetic qualification for every policy command. Never live evidence.
public extension ModelProviderRegistry {
    static func fixture(
        policy: ModelProviderPolicy = .v6,
        generator: @escaping @Sendable (ModelGenerationRequest) async throws -> ModelProviderResponse,
        now: Date = Date()
    ) throws -> ModelProviderRegistry {
        let drivers = ModelDriverID.allCases.map { FixtureProviderDriver(driverID: $0, generator: generator) }
        var qualifications: [ModelQualification] = []
        for profile in ProviderRuntimeCatalog.profiles {
            for command in policy.commands where profile.eligibleCommandIDs.contains(command.commandID) {
                qualifications.append(.init(
                    commandID: command.commandID,
                    profileID: profile.id,
                    qualificationBinding: profile.qualificationBinding,
                    outputShape: command.outputShape,
                    evidenceReference: "fixture:synthetic-no-quality-claim",
                    recordedAt: now
                ))
            }
        }
        return try ModelProviderRegistry(policy: policy, qualifications: qualifications, drivers: drivers, isFixture: true)
    }
}
