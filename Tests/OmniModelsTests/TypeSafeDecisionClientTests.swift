import Foundation
import OmniCore
import OmniModels
import Testing

private actor DecisionTransport: ModelHTTPExchangeTransport {
    private var requests: [URLRequest] = []
    private let result: Result<ModelHTTPExchange, any Error>

    init(status: Int = 200, body: String) {
        result = .success(ModelHTTPExchange(statusCode: status, body: Data(body.utf8)))
    }

    init(error: any Error) { result = .failure(error) }

    func exchange(_ request: URLRequest) async throws -> ModelHTTPExchange {
        requests.append(request)
        return try result.get()
    }

    func captured() -> [URLRequest] { requests }
}

private final class DecisionCredentials: ModelCredentialResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var references: [ModelCredentialReference] = []
    private let secret: String

    init(secret: String = "test-secret") { self.secret = secret }

    func resolve(_ reference: ModelCredentialReference) throws -> ModelResolvedSecret {
        lock.lock()
        references.append(reference)
        lock.unlock()
        return try ModelResolvedSecret(secret)
    }

    func captured() -> [ModelCredentialReference] {
        lock.lock()
        defer { lock.unlock() }
        return references
    }
}

private let decisionQuestions: [String: TypeSafeQuestion] = [
    "route": .choice(instructions: "Where?", criteria: ["a": "Alpha", "b": "Beta"]),
    "ready": .noul(instructions: "Ready?")
]

private let validDecisionBody = """
{"model":"jev-1.14.0","answers":{"route":{"type":"choice","choice":"a","probabilities":{"a":0.8,"b":0.2},"confidence":0.6},"ready":{"type":"noul","noul":0.9}},"usage":{"input_tokens":23,"output_tokens":5}}
"""

@Test func typeSafeDecisionRequestAndLazyCredentials() async throws {
    let transport = DecisionTransport(body: validDecisionBody)
    let credentials = DecisionCredentials()
    let client = TypeSafeDecisionClient(transport: transport, credentials: credentials)
    #expect(credentials.captured().isEmpty)

    let decisions = try await client.evaluate(state: Data(#"{"query":"sample","count":2}"#.utf8), questions: decisionQuestions)
    #expect(decisions.model == "jev-1.14.0")
    #expect(decisions.inputTokens == 23)
    #expect(decisions.answers["route"] == .choice(value: "a", probabilities: ["a": 0.8, "b": 0.2], confidence: 0.6))
    #expect(decisions.answers["ready"] == .noul(0.9))

    let references = credentials.captured()
    #expect(references == [.dotenvFile(path: "~/.config/daniel-tooling/ai/typesafe.env", key: "TYPESAFE_API_KEY")])
    let request = try #require(await transport.captured().first)
    #expect(request.url == TypeSafeDecisionClient.endpoint)
    #expect(request.httpMethod == "POST")
    #expect(request.timeoutInterval == 8)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let requestBody = try #require(request.httpBody)
    let payload = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
    #expect(payload["model"] as? String == "jev-1.14.0")
    #expect((payload["state"] as? [String: Any])?["query"] as? String == "sample")
    let questions = try #require(payload["questions"] as? [String: [String: Any]])
    #expect(questions["route"]?["type"] as? String == "choice")
    #expect((questions["route"]?["criteria"] as? [String: String]) == ["a": "Alpha", "b": "Beta"])
    #expect(questions["ready"]?["type"] as? String == "noul")
    #expect(questions["ready"]?["criteria"] == nil)

    _ = try await client.evaluate(state: Data("{}".utf8), questions: decisionQuestions)
    #expect(credentials.captured().count == 2)
    #expect(await transport.captured().count == 2)
}

@Test func typeSafeDecisionRejectsInvalidStateBeforeCredentialLookup() async {
    let transport = DecisionTransport(body: validDecisionBody)
    let credentials = DecisionCredentials()
    let client = TypeSafeDecisionClient(transport: transport, credentials: credentials)
    do {
        _ = try await client.evaluate(state: Data("[]".utf8), questions: decisionQuestions)
        Issue.record("Expected invalid request")
    } catch let error as TypeSafeDecisionError {
        #expect(error == .invalidRequest)
    } catch {
        Issue.record("Unexpected error type")
    }
    #expect(credentials.captured().isEmpty)
    #expect(await transport.captured().isEmpty)
}

@Test(arguments: [
    #"{"model":"m","answers":{"route":{"type":"choice","choice":"a","probabilities":{"a":true,"b":0},"confidence":0.5},"ready":{"type":"noul","noul":0.9}}}"#,
    #"{"model":"m","answers":{"route":{"type":"choice","choice":"a","probabilities":{"a":0.4,"b":0.6},"confidence":0.5},"ready":{"type":"noul","noul":0.9}}}"#,
    #"{"model":"m","answers":{"route":{"type":"choice","choice":"a","probabilities":{"a":0.8,"b":0.2},"confidence":0.5}}}"#,
    #"{"model":"m","answers":{"route":{"type":"choice","choice":"a","probabilities":{"a":0.8,"b":0.2},"confidence":1.5},"ready":{"type":"noul","noul":0.9}}}"#,
    #"{"model":"m","answers":{"route":{"type":"choice","choice":"a","probabilities":{"a":0.8,"b":0.2},"confidence":0.5},"ready":{"type":"noul","noul":false}}}"#
]) func typeSafeDecisionRejectsMalformedAnswers(body: String) async {
    let client = TypeSafeDecisionClient(transport: DecisionTransport(body: body), credentials: DecisionCredentials())
    do {
        _ = try await client.evaluate(state: Data("{}".utf8), questions: decisionQuestions)
        Issue.record("Expected malformed response")
    } catch let error as TypeSafeDecisionError {
        #expect(error == .malformedResponse)
    } catch {
        Issue.record("Unexpected error type")
    }
}

@Test func typeSafeDecisionHTTPFailureDoesNotExposeBody() async {
    let transport = DecisionTransport(status: 401, body: "private body and token test-secret")
    let client = TypeSafeDecisionClient(transport: transport, credentials: DecisionCredentials())
    do {
        _ = try await client.evaluate(state: Data("{}".utf8), questions: decisionQuestions)
        Issue.record("Expected HTTP failure")
    } catch let error as TypeSafeDecisionError {
        #expect(error == .httpStatus(401))
        #expect(!error.description.contains("private"))
        #expect(!error.description.contains("test-secret"))
    } catch {
        Issue.record("Unexpected error type")
    }
}

@Test func typeSafeDecisionMapsURLCancellation() async {
    let transport = DecisionTransport(error: URLError(.cancelled))
    let client = TypeSafeDecisionClient(transport: transport, credentials: DecisionCredentials())
    do {
        _ = try await client.evaluate(state: Data("{}".utf8), questions: decisionQuestions)
        Issue.record("Expected cancellation")
    } catch is CancellationError {
        // Expected.
    } catch {
        Issue.record("Unexpected error type")
    }
}

@Test func typeSafeDecisionPropagatesExplicitCancellation() async {
    let transport = DecisionTransport(error: CancellationError())
    let client = TypeSafeDecisionClient(transport: transport, credentials: DecisionCredentials())
    do {
        _ = try await client.evaluate(state: Data("{}".utf8), questions: decisionQuestions)
        Issue.record("Expected cancellation")
    } catch is CancellationError {} catch { Issue.record("Unexpected error type") }
}

@Test func typeSafeDecisionCancellationDuringCredentialLookupDoesNotDispatchHTTP() async {
    struct CancellingCredentials: ModelCredentialResolver {
        func resolve(_ reference: ModelCredentialReference) throws -> ModelResolvedSecret {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ModelResolvedSecret("fixture")
        }
    }
    let transport = DecisionTransport(body: validDecisionBody)
    let client = TypeSafeDecisionClient(transport: transport, credentials: CancellingCredentials())
    let task = Task { try await client.evaluate(state: Data("{}".utf8), questions: decisionQuestions) }
    do { _ = try await task.value; Issue.record("Expected cancellation") }
    catch is CancellationError {} catch { Issue.record("Unexpected error type") }
    #expect(await transport.captured().isEmpty)
}

@Test func typeSafeDecisionHidesTransportErrorDetails() async {
    struct SensitiveFailure: Error, CustomStringConvertible {
        var description: String { "test-secret and private request body" }
    }
    let transport = DecisionTransport(error: SensitiveFailure())
    let client = TypeSafeDecisionClient(transport: transport, credentials: DecisionCredentials())
    do {
        _ = try await client.evaluate(state: Data("{}".utf8), questions: decisionQuestions)
        Issue.record("Expected transport failure")
    } catch let error as TypeSafeDecisionError {
        #expect(error == .networkFailure)
        #expect(!error.description.contains("test-secret"))
        #expect(!error.description.contains("private"))
    } catch {
        Issue.record("Unexpected error type")
    }
}
