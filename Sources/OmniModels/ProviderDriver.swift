import Foundation
import OmniCore

// MARK: - Driver boundary shared by every provider protocol

/// An ephemeral transport input. It is not Codable, prints redacted, and is
/// never part of a descriptor, dispatch snapshot or receipt.
public struct ModelResolvedSecret: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let value: String

    public init(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ModelCredentialError.emptyCredential }
        self.value = trimmed
    }

    public var description: String { "<redacted-secret>" }
    public var debugDescription: String { "<redacted-secret>" }

    /// The only way a secret leaves this type: directly into a request header.
    public func apply(to request: inout URLRequest, header: String, prefix: String = "") {
        request.setValue(prefix + value, forHTTPHeaderField: header)
    }

    /// Length-only diagnostic for tests and receipts; never the value.
    public var byteCount: Int { value.utf8.count }
}

public enum ModelCredentialError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingReference
    case emptyCredential
    case unreadable(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .missingReference: "connection has no credential reference"
        case .emptyCredential: "resolved credential is empty"
        case .unreadable(let what): "credential source unreadable: \(what)"
        case .notFound(let what): "credential not found: \(what)"
        }
    }
}

/// Resolves credentials lazily for one permitted attempt or an explicit
/// connection test. Registry construction and settings display never call it.
public protocol ModelCredentialResolver: Sendable {
    func resolve(_ reference: ModelCredentialReference) throws -> ModelResolvedSecret
}

/// Reads a named variable from the process environment or from a dotenv-style
/// file. It reads only the referenced key and returns only that value.
public struct ModelReferenceCredentialResolver: ModelCredentialResolver {
    private let environment: @Sendable (String) -> String?

    public init(environment: @escaping @Sendable (String) -> String? = { ProcessInfo.processInfo.environment[$0] }) {
        self.environment = environment
    }

    public func resolve(_ reference: ModelCredentialReference) throws -> ModelResolvedSecret {
        switch reference {
        case .keychain:
            throw ModelCredentialError.unreadable("Keychain credentials require the app credential resolver")
        case .environmentVariable(let name):
            guard let value = environment(name) else { throw ModelCredentialError.notFound(reference.redactedDescription) }
            return try ModelResolvedSecret(value)
        case .dotenvFile(let path, let key):
            let expanded = OmniLayout.expandingCurrentUserTilde(path)
            guard FileManager.default.isReadableFile(atPath: expanded) else {
                throw ModelCredentialError.unreadable(reference.redactedDescription)
            }
            guard let contents = try? String(contentsOfFile: expanded, encoding: .utf8) else {
                throw ModelCredentialError.unreadable(reference.redactedDescription)
            }
            for rawLine in contents.split(whereSeparator: \.isNewline) {
                var line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
                guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
                let name = line[..<equals].trimmingCharacters(in: .whitespaces)
                guard name == key else { continue }
                var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if let first = value.first, first == "\"" || first == "'" {
                    // Quoted: take the content up to the closing quote; anything after is a comment.
                    let body = value.dropFirst()
                    if let close = body.firstIndex(of: first) { value = String(body[..<close]) } else { value = String(body) }
                } else if let comment = value.range(of: " #") {
                    value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
                }
                return try ModelResolvedSecret(value)
            }
            throw ModelCredentialError.notFound(reference.redactedDescription)
        }
    }
}

/// Bounded request handed to a driver after the broker resolved and reserved
/// the attempt. The driver cannot change profile, connection or billing route.
public struct ModelDriverRequest: Sendable {
    public let generation: ModelGenerationRequest
    public let profile: ModelProfile
    public let connection: ModelConnectionProfile
    public let generationID: String
    public let attemptID: String
    public let deadline: ContinuousClock.Instant
    public let maximumResponseBytes: Int

    public init(
        generation: ModelGenerationRequest,
        profile: ModelProfile,
        connection: ModelConnectionProfile,
        generationID: String,
        attemptID: String,
        deadline: ContinuousClock.Instant,
        maximumResponseBytes: Int = 1_000_000
    ) {
        self.generation = generation
        self.profile = profile
        self.connection = connection
        self.generationID = generationID
        self.attemptID = attemptID
        self.deadline = deadline
        self.maximumResponseBytes = maximumResponseBytes
    }

    public var wantsJSONObject: Bool { generation.outputConstraint.shape.requestsJSONObject }
}

public struct ModelDriverResponse: Sendable, Equatable {
    public let text: String
    public let usage: ModelUsage?
    public let observedAuthRoute: ModelAuthRoute?
    public let resolvedModel: String?
    public let nativeReference: String?
    public let reportedPlan: String?
    /// Upstream provider named by a routing connection, if any.
    public let servedBy: String?
    public let estimatedCostUSD: Double?
    public let isolation: ModelIsolationAttestation?

    public init(
        text: String,
        usage: ModelUsage? = nil,
        observedAuthRoute: ModelAuthRoute? = nil,
        resolvedModel: String? = nil,
        nativeReference: String? = nil,
        reportedPlan: String? = nil,
        servedBy: String? = nil,
        estimatedCostUSD: Double? = nil,
        isolation: ModelIsolationAttestation? = nil
    ) {
        self.text = text
        self.usage = usage
        self.observedAuthRoute = observedAuthRoute
        self.resolvedModel = resolvedModel
        self.nativeReference = nativeReference
        self.reportedPlan = reportedPlan
        self.servedBy = servedBy
        self.estimatedCostUSD = estimatedCostUSD
        self.isolation = isolation
    }
}

/// Normalized driver failure. `detail` is safe diagnostic text: never a
/// credential, raw environment, or full process stream.
public struct ModelDriverFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public let kind: ModelFailureKind
    public let detail: String?
    public let retryAfterSeconds: Double?
    public let observedAuthRoute: ModelAuthRoute?
    public let resolvedModel: String?
    public let nativeReference: String?
    public let isolation: ModelIsolationAttestation?
    public let usage: ModelUsage?

    public init(
        _ kind: ModelFailureKind,
        detail: String? = nil,
        retryAfterSeconds: Double? = nil,
        observedAuthRoute: ModelAuthRoute? = nil,
        resolvedModel: String? = nil,
        nativeReference: String? = nil,
        isolation: ModelIsolationAttestation? = nil,
        usage: ModelUsage? = nil
    ) {
        self.kind = kind
        self.detail = detail.map { String($0.prefix(400)) }
        self.retryAfterSeconds = retryAfterSeconds
        self.observedAuthRoute = observedAuthRoute
        self.resolvedModel = resolvedModel
        self.nativeReference = nativeReference
        self.isolation = isolation
        self.usage = usage
    }

    public var description: String { "\(kind.rawValue)\(detail.map { ": \($0)" } ?? "")" }
}

public struct ModelConnectionProbe: Sendable, Equatable {
    public let availability: ModelConnectionAvailability
    public let detail: String?
    /// Present only when a read-only provider probe enumerated installed models.
    /// Absence means model presence was not checked, not an empty installation.
    public let availableModelSelectors: Set<String>?
    public let observedAuthRoute: ModelAuthRoute?
    public let reportedPlan: String?
    public let checkedAt: Date

    public init(availability: ModelConnectionAvailability, detail: String? = nil, availableModelSelectors: Set<String>? = nil, observedAuthRoute: ModelAuthRoute? = nil, reportedPlan: String? = nil, checkedAt: Date = Date()) {
        self.availability = availability
        self.detail = detail
        self.availableModelSelectors = availableModelSelectors
        self.observedAuthRoute = observedAuthRoute
        self.reportedPlan = reportedPlan
        self.checkedAt = checkedAt
    }
}

/// One protocol adapter plus its connection/session ownership. It receives an
/// already-authorized attempt and returns a normalized result. It cannot pick
/// another provider, change the billing route, dispatch commands or touch
/// Omni run history.
public protocol ModelProviderDriver: Sendable {
    var driverID: ModelDriverID { get }
    var capabilities: Set<ModelCapability> { get }

    /// Static configuration check without network, process launch or
    /// credential resolution. Returns a failure kind when the connection cannot
    /// be dispatched as configured.
    func configurationIssue(for connection: ModelConnectionProfile) -> ModelFailureKind?

    /// Diagnostic readiness. It may verify auth routes through the owning
    /// client but must never invoke inference. Cached results are never
    /// dispatch permission; `generate` re-verifies every attempt.
    func probe(connection: ModelConnectionProfile) async -> ModelConnectionProbe

    func generate(_ request: ModelDriverRequest) async throws -> ModelDriverResponse
}

/// Optional live-text capability. The callback receives only newly produced
/// text; callers own the transient display and may cancel their task at any
/// point. No driver or transport writes a run or a draft.
public protocol ModelStreamingProviderDriver: ModelProviderDriver {
    func stream(_ request: ModelDriverRequest, onText: @escaping @Sendable (String) async -> Void) async throws -> ModelDriverResponse
}

public extension ModelProviderDriver {
    func configurationIssue(for connection: ModelConnectionProfile) -> ModelFailureKind? { nil }
}

// MARK: - Shared HTTP helpers

enum ProviderHTTP {
    static func retryAfterSeconds(from headers: [String: String]) -> Double? {
        for (key, value) in headers where key.lowercased() == "retry-after" {
            if let seconds = Double(value.trimmingCharacters(in: .whitespaces)) { return seconds }
        }
        return nil
    }

    static func classify(status: Int, body: Data, retryAfter: Double?) -> ModelDriverFailure {
        let message = errorMessage(from: body)
        switch status {
        case 401, 403: return ModelDriverFailure(.authRequired, detail: "HTTP \(status)\(message.map { ": \($0)" } ?? "")")
        case 402: return ModelDriverFailure(.quotaExhausted, detail: "HTTP 402\(message.map { ": \($0)" } ?? "")")
        case 408, 504: return ModelDriverFailure(.timeout, detail: "HTTP \(status)")
        case 413: return ModelDriverFailure(.contextOrOutputLimit, detail: "HTTP 413\(message.map { ": \($0)" } ?? "")")
        case 429:
            if let message, message.lowercased().contains("quota") || message.lowercased().contains("insufficient") || message.lowercased().contains("billing") {
                return ModelDriverFailure(.quotaExhausted, detail: "HTTP 429: \(message)", retryAfterSeconds: retryAfter)
            }
            return ModelDriverFailure(.rateLimited, detail: "HTTP 429\(message.map { ": \($0)" } ?? "")", retryAfterSeconds: retryAfter)
        case 400, 404, 422:
            if let message, message.lowercased().contains("context") || message.lowercased().contains("too long") || message.lowercased().contains("maximum") {
                return ModelDriverFailure(.contextOrOutputLimit, detail: "HTTP \(status): \(message)")
            }
            if let message, message.lowercased().contains("model") && (message.lowercased().contains("not found") || message.lowercased().contains("does not exist") || message.lowercased().contains("unknown")) {
                return ModelDriverFailure(.modelMismatch, detail: "HTTP \(status): \(message)")
            }
            if let message, message.lowercased().contains("reasoning") || message.lowercased().contains("unsupported") || message.lowercased().contains("not supported") {
                return ModelDriverFailure(.unsupportedCapability, detail: "HTTP \(status): \(message)")
            }
            return ModelDriverFailure(.providerFailure, detail: "HTTP \(status)\(message.map { ": \($0)" } ?? "")")
        case 500, 502, 503, 529:
            return ModelDriverFailure(status == 503 || status == 529 ? .rateLimited : .providerFailure, detail: "HTTP \(status)\(message.map { ": \($0)" } ?? "")", retryAfterSeconds: retryAfter)
        default:
            return ModelDriverFailure(.providerFailure, detail: "HTTP \(status)\(message.map { ": \($0)" } ?? "")", retryAfterSeconds: retryAfter)
        }
    }

    static func errorMessage(from body: Data) -> String? {
        guard !body.isEmpty, body.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        if let error = object["error"] as? [String: Any] {
            if let message = error["message"] as? String { return String(message.prefix(300)) }
            if let type = error["type"] as? String { return type }
        }
        if let message = object["message"] as? String { return String(message.prefix(300)) }
        if let error = object["error"] as? String { return String(error.prefix(300)) }
        return nil
    }

    static func mapTransportError(_ error: any Error) -> ModelDriverFailure {
        if error is CancellationError { return ModelDriverFailure(.cancelled) }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: return ModelDriverFailure(.timeout, detail: "request timed out")
            case NSURLErrorCancelled: return ModelDriverFailure(.cancelled)
            default: return ModelDriverFailure(.providerFailure, detail: "network error \(ns.code)")
            }
        }
        if let transport = error as? ModelProviderTransportError {
            switch transport {
            case .invalidResponse, .malformedPayload: return ModelDriverFailure(.invalidResponse, detail: String(describing: transport))
            case .status(let code): return ModelDriverFailure(.providerFailure, detail: "HTTP \(code)")
            default: return ModelDriverFailure(.providerFailure, detail: String(describing: transport))
            }
        }
        return ModelDriverFailure(.providerFailure, detail: String(describing: type(of: error)))
    }
}

/// Response wrapper that also exposes headers, needed for retry-after and
/// version diagnostics. `ModelHTTPTransport` implementations that cannot
/// supply headers return an empty dictionary.
public struct ModelHTTPExchange: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol ModelHTTPExchangeTransport: Sendable {
    func exchange(_ request: URLRequest) async throws -> ModelHTTPExchange
}

/// A response whose body arrives as bounded, in-memory chunks. The producer
/// is cancelled when iteration ends or its consuming task is cancelled.
public struct ModelHTTPByteStream: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let chunks: AsyncThrowingStream<Data, any Error>
    public let cancel: @Sendable () -> Void

    public init(statusCode: Int, headers: [String: String] = [:], chunks: AsyncThrowingStream<Data, any Error>, cancel: @escaping @Sendable () -> Void = {}) {
        self.statusCode = statusCode
        self.headers = headers
        self.chunks = chunks
        self.cancel = cancel
    }
}

private final class HTTPStreamTaskController: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let active = task
        lock.unlock()
        active?.cancel()
    }
}

public protocol ModelHTTPStreamingTransport: Sendable {
    func stream(_ request: URLRequest) async throws -> ModelHTTPByteStream
}

/// Long-lived URLSession client reused across requests and providers.
public final class SharedURLSessionTransport: ModelHTTPExchangeTransport, ModelHTTPStreamingTransport, @unchecked Sendable {
    private let session: URLSession

    public init(timeout: TimeInterval = 180) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    /// Package-internal seam for a locally instrumented URLSession in tests.
    /// Production composition always uses the ephemeral initializer above.
    init(session: URLSession) { self.session = session }

    public func exchange(_ request: URLRequest) async throws -> ModelHTTPExchange {
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelProviderTransportError.invalidResponse }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return ModelHTTPExchange(statusCode: http.statusCode, headers: headers, body: body)
    }

    public func stream(_ request: URLRequest) async throws -> ModelHTTPByteStream {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelProviderTransportError.invalidResponse }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        let controller = HTTPStreamTaskController()
        // A fast provider can outrun AppKit presentation briefly. The queue
        // remains finite while allowing a normal translation burst to drain.
        let chunks = AsyncThrowingStream<Data, any Error>(bufferingPolicy: .bufferingOldest(1_024)) { continuation in
            let producer = Task {
                do {
                    var pending = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        pending.append(byte)
                        if byte == 0x0A || pending.count >= 4_096 {
                            switch continuation.yield(pending) {
                            case .enqueued(_): break
                            case .dropped(_):
                                continuation.finish(throwing: ModelDriverFailure(.contextOrOutputLimit, detail: "stream consumer fell behind"))
                                return
                            case .terminated: return
                            @unknown default: return
                            }
                            pending.removeAll(keepingCapacity: true)
                        }
                    }
                    if !pending.isEmpty {
                        if case .dropped(_) = continuation.yield(pending) {
                            continuation.finish(throwing: ModelDriverFailure(.contextOrOutputLimit, detail: "stream consumer fell behind"))
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            controller.install(producer)
            continuation.onTermination = { @Sendable _ in controller.cancel() }
        }
        return ModelHTTPByteStream(statusCode: http.statusCode, headers: headers, chunks: chunks, cancel: { controller.cancel() })
    }
}

/// Adapts the historical header-less transport for fixture tests.
public struct LegacyExchangeTransport: ModelHTTPExchangeTransport {
    private let base: any ModelHTTPTransport
    public init(_ base: any ModelHTTPTransport) { self.base = base }
    public func exchange(_ request: URLRequest) async throws -> ModelHTTPExchange {
        let response = try await base.send(request)
        return ModelHTTPExchange(statusCode: response.statusCode, headers: [:], body: response.body)
    }
}
