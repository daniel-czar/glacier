import Foundation
import OmniModels

public protocol ConnectionNetworkTransport: ModelHTTPExchangeTransport, ModelHTTPStreamingTransport {}

/// URLSession does not follow redirects here. Cancelling a redirect in the
/// delegate happens before URLSession can resend an Authorization header.
public final class NoRedirectURLSessionTransport: NSObject, ConnectionNetworkTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let session: URLSession

    public init(timeout: TimeInterval = 180) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: RedirectBlocker.shared, delegateQueue: nil)
        super.init()
    }

    public func exchange(_ request: URLRequest) async throws -> ModelHTTPExchange {
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ConnectionError.unsafeDestination }
        return ModelHTTPExchange(statusCode: http.statusCode, headers: Self.headers(http), body: body)
    }

    public func stream(_ request: URLRequest) async throws -> ModelHTTPByteStream {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ConnectionError.unsafeDestination }
        let chunks = AsyncThrowingStream<Data, any Error>(bufferingPolicy: .bufferingOldest(64)) { continuation in
            let producer = Task {
                do {
                    var pending = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        pending.append(byte)
                        if byte == 0x0a || pending.count >= 4_096 {
                            if case .dropped = continuation.yield(pending) {
                                continuation.finish(throwing: ConnectionError.storageFailure)
                                return
                            }
                            pending.removeAll(keepingCapacity: true)
                        }
                    }
                    if !pending.isEmpty { _ = continuation.yield(pending) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
        return ModelHTTPByteStream(statusCode: http.statusCode, headers: Self.headers(http), chunks: chunks)
    }

    private static func headers(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { result[key] = value }
        }
        return result
    }
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RedirectBlocker()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// This is the common gateway for durable generation and ephemeral streams.
/// It checks the currently approved origin before invoking the transport, so
/// revoking or changing a profile blocks later requests without a fallback.
public struct ApprovedOriginTransport: ConnectionNetworkTransport {
    private let base: any ConnectionNetworkTransport
    private let origins: @Sendable () async -> Set<ConnectionOrigin>
    private let gate: @Sendable (URL) throws -> Void

    public init(store: ConnectionStore, provider: ConnectionProvider,
                base: any ConnectionNetworkTransport = NoRedirectURLSessionTransport(),
                gate: @escaping @Sendable (URL) throws -> Void = { _ in }) {
        self.base = base
        origins = { await store.approvedOrigin(for: provider).map { [$0] } ?? [] }
        self.gate = gate
    }

    public init(origins: @escaping @Sendable () async -> Set<ConnectionOrigin>, base: any ConnectionNetworkTransport,
                gate: @escaping @Sendable (URL) throws -> Void = { _ in }) {
        self.origins = origins
        self.base = base
        self.gate = gate
    }

    public func exchange(_ request: URLRequest) async throws -> ModelHTTPExchange {
        try await check(request)
        let response = try await base.exchange(request)
        guard !(300..<400).contains(response.statusCode) else { throw ConnectionError.unsafeRedirect }
        return response
    }

    public func stream(_ request: URLRequest) async throws -> ModelHTTPByteStream {
        try await check(request)
        let response = try await base.stream(request)
        guard !(300..<400).contains(response.statusCode) else {
            response.cancel()
            throw ConnectionError.unsafeRedirect
        }
        return response
    }

    private func check(_ request: URLRequest) async throws {
        guard let url = request.url else { throw ConnectionError.unsafeDestination }
        try gate(url)
        let origin = try ConnectionOrigin(url: url, localService: true)
        guard await origins().contains(origin) else { throw ConnectionError.unsafeDestination }
        // Origin lookup can suspend. Reauthorize at this transport's dispatch
        // boundary so an old queued request cannot revive a dismissed session.
        try gate(url)
    }
}
