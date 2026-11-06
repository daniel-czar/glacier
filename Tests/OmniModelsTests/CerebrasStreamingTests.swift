import Foundation
import OmniCore
import OmniModels
import Testing

private final class CancelMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.lock(); value += 1; lock.unlock() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private actor StreamCapture {
    private(set) var requests: [URLRequest] = []
    private let chunks: [Data]
    private let status: Int
    private let cancelMarker: CancelMarker?

    init(chunks: [Data], status: Int = 200, cancelMarker: CancelMarker? = nil) {
        self.chunks = chunks
        self.status = status
        self.cancelMarker = cancelMarker
    }

    func response(to request: URLRequest) -> ModelHTTPByteStream {
        requests.append(request)
        let chunks = chunks
        let status = status
        let marker = cancelMarker
        return ModelHTTPByteStream(statusCode: status, chunks: AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }, cancel: { marker?.record() })
    }

    var firstRequest: URLRequest? { requests.first }
    var requestCount: Int { requests.count }
}

private struct ScriptedStreamingTransport: ModelHTTPStreamingTransport {
    let capture: StreamCapture
    func stream(_ request: URLRequest) async throws -> ModelHTTPByteStream { await capture.response(to: request) }
}

private actor Deltas {
    private(set) var values: [String] = []
    private var firstWaiter: CheckedContinuation<Void, Never>?
    func append(_ value: String) {
        values.append(value)
        if values.count == 1 { firstWaiter?.resume(); firstWaiter = nil }
    }
    func waitForFirst() async {
        if !values.isEmpty { return }
        await withCheckedContinuation { firstWaiter = $0 }
    }
    var all: [String] { values }
}

private actor PausingStreamTransport: ModelHTTPStreamingTransport {
    private(set) var calls = 0

    func stream(_ request: URLRequest) -> ModelHTTPByteStream {
        calls += 1
        if calls == 1 {
            let first = Data("data: {\"model\":\"qwen-3.8-27b\",\"choices\":[{\"delta\":{\"content\":\"1. Partial\"},\"finish_reason\":null}]}\n\n".utf8)
            return ModelHTTPByteStream(statusCode: 200, chunks: AsyncThrowingStream { continuation in
                let producer = Task {
                    continuation.yield(first)
                    do { try await Task.sleep(for: .seconds(30)); continuation.finish() }
                    catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { @Sendable _ in producer.cancel() }
            })
        }
        return ModelHTTPByteStream(statusCode: 200, chunks: AsyncThrowingStream { continuation in
            continuation.yield(Data(completionSSE.utf8))
            continuation.finish()
        })
    }

    var requestCount: Int { calls }
}

private let completionSSE = """
data: {"id":"chatcmpl-stream","model":"qwen-3.8-27b","choices":[{"index":0,"delta":{"content":"1. Good"},"finish_reason":null}]}

data: {"choices":[{"index":0,"delta":{"content":" morning"},"finish_reason":null}]}

data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":8,"completion_tokens":4}}

data: [DONE]

"""

private func streamHarness(_ capture: StreamCapture) throws -> (ProviderRuntimeBrokerStore, RecordingCredentialResolver) {
    let credentials = RecordingCredentialResolver()
    let driver = CerebrasHTTPDriver(
        transport: CapturingExchangeTransport(json: "{}"),
        credentials: credentials,
        streamingTransport: ScriptedStreamingTransport(capture: capture)
    )
    let harness = try RoutingHarness(replacing: [driver])
    let settings = settingsDocument(connections: connectionsEnabling("cerebras", credential: .environmentVariable(name: "CEREBRAS_TEST_KEY")))
    return (ProviderRuntimeBrokerStore(broker: try harness.broker(settings: settings)), credentials)
}

private func liveTranslationRequest(offline: Bool = false) -> ModelGenerationRequest {
    generationRequest(
        "translate",
        prompt: "Translate the German source into English. Return one numbered translation. Source: Guten Morgen",
        offline: offline,
        selection: ModelInvocationSelection(profileID: ProviderRuntimeCatalog.cerebrasFastProfileID)
    )
}

@Test func cerebrasStreamParsesFragmentedSSEAndUsesConfiguredRoute() async throws {
    let bytes = Data(completionSSE.utf8)
    let chunks = stride(from: 0, to: bytes.count, by: 7).map { offset in
        bytes.subdata(in: offset..<min(offset + 7, bytes.count))
    }
    let cancellation = CancelMarker()
    let capture = StreamCapture(chunks: chunks, cancelMarker: cancellation)
    let (store, credentials) = try streamHarness(capture)
    let deltas = Deltas()
    let result = try await store.stream(liveTranslationRequest()) { text in await deltas.append(text) }

    #expect(result.response.text == "1. Good morning")
    #expect(result.response.usage == ModelUsage(inputTokens: 8, outputTokens: 4))
    #expect(await deltas.all == ["1. Good", " morning"])
    #expect(result.record.attempts.count == 1)
    #expect(result.record.attempts.first?.identity?.profileID == ProviderRuntimeCatalog.cerebrasFastProfileID)
    #expect(credentials.calls >= 1)
    let request = await capture.firstRequest
    #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
    #expect(request?.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    let body = try jsonBody(request)
    #expect(body["stream"] as? Bool == true)
    #expect(body["model"] as? String == "qwen-3.8-27b")
    #expect(body["reasoning_effort"] as? String == "none")
    #expect(cancellation.calls == 1)
}

@Test func cerebrasStreamHonorsOfflineAndDoesNotCallTransport() async throws {
    let capture = StreamCapture(chunks: [Data(completionSSE.utf8)])
    let (store, _) = try streamHarness(capture)
    let error = await brokerError { try await store.stream(liveTranslationRequest(offline: true)) { _ in } }
    guard case .unavailable(let record)? = error else {
        Issue.record("expected offline exclusion")
        return
    }
    #expect(record.attempts.first?.identity?.failure == .offlineExcludesRemote)
    #expect(await capture.requestCount == 0)
}

@Test func cerebrasStreamRequiresConfiguredCredentialBeforeDispatch() async throws {
    let capture = StreamCapture(chunks: [Data(completionSSE.utf8)])
    let driver = CerebrasHTTPDriver(
        transport: CapturingExchangeTransport(json: "{}"),
        credentials: RecordingCredentialResolver(),
        streamingTransport: ScriptedStreamingTransport(capture: capture)
    )
    let harness = try RoutingHarness(replacing: [driver])
    let store = ProviderRuntimeBrokerStore(broker: try harness.broker())
    let error = await brokerError { try await store.stream(liveTranslationRequest()) { _ in } }
    guard case .unavailable(let record)? = error else {
        Issue.record("expected configuration exclusion")
        return
    }
    #expect(record.attempts.first?.identity?.failure == .needsConfiguration)
    #expect(await capture.requestCount == 0)
}

@Test func cerebrasStreamRejectsTruncatedAndUnnumberedResults() async throws {
    let truncated = completionSSE.replacingOccurrences(of: "\"finish_reason\":\"stop\"", with: "\"finish_reason\":\"length\"")
    let first = StreamCapture(chunks: [Data(truncated.utf8)])
    let (firstStore, _) = try streamHarness(first)
    let firstError = await brokerError { try await firstStore.stream(liveTranslationRequest()) { _ in } }
    guard case .failed(let truncatedRecord)? = firstError else {
        Issue.record("expected truncated stream failure")
        return
    }
    #expect(truncatedRecord.attempts.first?.identity?.failure == .contextOrOutputLimit)

    let unnumbered = completionSSE.replacingOccurrences(of: "1. Good", with: "Good")
    let second = StreamCapture(chunks: [Data(unnumbered.utf8)])
    let (secondStore, _) = try streamHarness(second)
    let secondError = await brokerError { try await secondStore.stream(liveTranslationRequest()) { _ in } }
    guard case .failed(let invalidRecord)? = secondError else {
        Issue.record("expected output shape failure")
        return
    }
    #expect(invalidRecord.attempts.first?.identity?.failure == .invalidResponse)
}

@Test func cerebrasStreamStatusErrorDoesNotExposeProviderBody() async throws {
    let cancellation = CancelMarker()
    let capture = StreamCapture(chunks: [Data("secret source echoed by provider".utf8)], status: 429, cancelMarker: cancellation)
    let (store, _) = try streamHarness(capture)
    let error = await brokerError { try await store.stream(liveTranslationRequest()) { _ in } }
    guard case .failed(let record)? = error else {
        Issue.record("expected status failure")
        return
    }
    #expect(record.attempts.first?.identity?.failure == .rateLimited)
    #expect(record.attempts.first?.detail?.contains("secret source") == false)
    #expect(cancellation.calls == 1)
}

@Test func cerebrasStreamCancellationReleasesConnectionSlot() async throws {
    let transport = PausingStreamTransport()
    let driver = CerebrasHTTPDriver(
        transport: CapturingExchangeTransport(json: "{}"),
        credentials: RecordingCredentialResolver(),
        streamingTransport: transport
    )
    let harness = try RoutingHarness(replacing: [driver])
    let settings = settingsDocument(connections: connectionsEnabling("cerebras", credential: .environmentVariable(name: "CEREBRAS_TEST_KEY")))
    let store = ProviderRuntimeBrokerStore(broker: try harness.broker(
        settings: settings,
        bounds: ProviderRuntimeBounds(maximumConcurrentHTTPAttemptsPerConnection: 1)
    ))
    let deltas = Deltas()
    let first = Task { try await store.stream(liveTranslationRequest()) { text in await deltas.append(text) } }
    await deltas.waitForFirst()
    first.cancel()
    do {
        _ = try await first.value
        Issue.record("expected stream cancellation")
    } catch let error as ModelBrokerError {
        guard case .cancelled = error else { Issue.record("expected cancelled broker result"); return }
    }

    let second = try await store.stream(liveTranslationRequest()) { _ in }
    #expect(second.response.text == "1. Good morning")
    #expect(await transport.requestCount == 2)
}
