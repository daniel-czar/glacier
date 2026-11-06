import Foundation
import OmniCore

/// Parses the OpenAI-compatible SSE response without retaining raw frames or
/// provider error bodies. Only answer deltas cross the callback boundary.
enum CerebrasSSECompletion {
    static func consume(
        _ chunks: AsyncThrowingStream<Data, any Error>,
        request: ModelDriverRequest,
        onText: @escaping @Sendable (String) async -> Void
    ) async throws -> ModelDriverResponse {
        var line = Data()
        var dataLines: [String] = []
        var eventName: String?
        var answer = ""
        var resolvedModel: String?
        var nativeReference: String?
        var usage: ModelUsage?
        var finishReason: String?
        var finished = false
        var receivedBytes = 0

        func consumeEvent() async throws {
            defer { dataLines.removeAll(keepingCapacity: true); eventName = nil }
            guard !dataLines.isEmpty else { return }
            if eventName == "error" { throw ModelDriverFailure(.providerFailure, detail: "provider stream error") }
            let payloadText = dataLines.joined(separator: "\n")
            if payloadText == "[DONE]" { finished = true; return }
            guard let payload = try? JSONSerialization.jsonObject(with: Data(payloadText.utf8)) as? [String: Any] else {
                throw ModelDriverFailure(.invalidResponse, detail: "malformed stream event")
            }
            if payload["error"] != nil { throw ModelDriverFailure(.providerFailure, detail: "provider stream error") }
            if let model = payload["model"] as? String {
                guard ChatCompletionsAdapter.modelMatches(requested: request.profile.modelSelector, resolved: model) else {
                    throw ModelDriverFailure(.modelMismatch, detail: "stream model differs from requested model")
                }
                resolvedModel = model
            }
            if let identifier = payload["id"] as? String { nativeReference = String(identifier.prefix(48)) }
            if let counts = payload["usage"] as? [String: Any] {
                let details = counts["completion_tokens_details"] as? [String: Any]
                usage = ModelUsage(
                    inputTokens: counts["prompt_tokens"] as? Int,
                    outputTokens: counts["completion_tokens"] as? Int,
                    reasoningTokens: details?["reasoning_tokens"] as? Int
                )
            }
            guard let choices = payload["choices"] as? [[String: Any]], let first = choices.first else { return }
            if let reason = first["finish_reason"] as? String { finishReason = reason }
            guard let delta = first["delta"] as? [String: Any], let content = delta["content"] as? String, !content.isEmpty else { return }
            try Task.checkCancellation()
            answer += content
            guard answer.utf8.count <= request.maximumResponseBytes else {
                throw ModelDriverFailure(.contextOrOutputLimit, detail: "stream output exceeds response limit")
            }
            await onText(content)
            try Task.checkCancellation()
        }

        func consumeLine() async throws {
            if line.last == 0x0D { line.removeLast() }
            defer { line.removeAll(keepingCapacity: true) }
            guard !line.isEmpty else { try await consumeEvent(); return }
            guard let value = String(data: line, encoding: .utf8) else {
                throw ModelDriverFailure(.invalidResponse, detail: "stream line is not UTF-8")
            }
            if value.hasPrefix("data:") {
                var content = String(value.dropFirst(5))
                if content.first == " " { content.removeFirst() }
                dataLines.append(content)
            } else if value.hasPrefix("event:") {
                eventName = String(value.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            }
        }

        do {
            for try await chunk in chunks {
                try Task.checkCancellation()
                receivedBytes += chunk.count
                guard receivedBytes <= request.maximumResponseBytes else {
                    throw ModelDriverFailure(.contextOrOutputLimit, detail: "stream exceeds response limit")
                }
                for byte in chunk {
                    if byte == 0x0A {
                        try await consumeLine()
                    } else {
                        line.append(byte)
                    }
                    if finished { break }
                }
                if finished { break }
            }
        } catch let failure as ModelDriverFailure {
            throw failure
        } catch {
            throw ProviderHTTP.mapTransportError(error)
        }
        // A provider may close immediately after the terminal data line,
        // without a second blank line. Consume that final frame at EOF.
        if !finished, !line.isEmpty { try await consumeLine() }
        if !finished, !dataLines.isEmpty { try await consumeEvent() }
        try Task.checkCancellation()
        guard finished else { throw ModelDriverFailure(.invalidResponse, detail: "stream ended before completion") }
        if finishReason == "length" { throw ModelDriverFailure(.contextOrOutputLimit, detail: "completion truncated at output limit", usage: usage) }
        if finishReason == "content_filter" { throw ModelDriverFailure(.providerFailure, detail: "provider content filter", usage: usage) }
        guard finishReason == "stop" else { throw ModelDriverFailure(.invalidResponse, detail: "stream has no successful finish reason", usage: usage) }
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ModelDriverFailure(.invalidResponse, detail: "empty completion", usage: usage) }
        return ModelDriverResponse(
            text: text,
            usage: usage,
            observedAuthRoute: .cerebrasAPIKey,
            resolvedModel: resolvedModel,
            nativeReference: nativeReference
        )
    }
}
