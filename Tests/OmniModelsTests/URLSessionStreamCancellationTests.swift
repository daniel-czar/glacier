import Foundation
@testable import OmniModels
import Testing

/// Sends one SSE line and deliberately never finishes. A cancelled URLSession
/// task must call `stopLoading`; no socket or provider is involved.
private final class StalledSSEURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stopped = false

    static func reset() {
        lock.lock()
        stopped = false
        lock.unlock()
    }

    static var didStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "omni-stream-cancel.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"1. Hello\"}}]}\n".utf8))
    }

    override func stopLoading() {
        Self.lock.lock()
        Self.stopped = true
        Self.lock.unlock()
    }
}

@Test func sharedURLSessionStreamCancellationStopsUnderlyingLoad() async throws {
    StalledSSEURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StalledSSEURLProtocol.self]
    configuration.timeoutIntervalForRequest = 2
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let transport = SharedURLSessionTransport(session: session)
    var request = URLRequest(url: URL(string: "https://omni-stream-cancel.invalid/v1/chat/completions")!)
    request.timeoutInterval = 2
    let response = try await transport.stream(request)
    var iterator = response.chunks.makeAsyncIterator()
    let firstChunk = try await iterator.next()
    #expect(firstChunk != nil)

    response.cancel()
    for _ in 0..<200 where !StalledSSEURLProtocol.didStop {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(StalledSSEURLProtocol.didStop)
}
