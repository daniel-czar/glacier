import CoreFoundation
import Foundation
import OmniCore

/// The two System One question shapes used by decision policies.
public enum TypeSafeQuestion: Sendable, Equatable, Codable {
    case choice(instructions: String, criteria: [String: String])
    case noul(instructions: String)

    private enum CodingKeys: String, CodingKey { case type, instructions, criteria }
    private enum Kind: String, Codable { case choice, noul }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .choice:
            self = .choice(
                instructions: try container.decode(String.self, forKey: .instructions),
                criteria: try container.decode([String: String].self, forKey: .criteria)
            )
        case .noul:
            self = .noul(instructions: try container.decode(String.self, forKey: .instructions))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .choice(let instructions, let criteria):
            try container.encode(Kind.choice, forKey: .type)
            try container.encode(instructions, forKey: .instructions)
            try container.encode(criteria, forKey: .criteria)
        case .noul(let instructions):
            try container.encode(Kind.noul, forKey: .type)
            try container.encode(instructions, forKey: .instructions)
        }
    }
}

public enum TypeSafeAnswer: Sendable, Equatable, Codable {
    case choice(value: String, probabilities: [String: Double], confidence: Double)
    case noul(Double)

    private enum CodingKeys: String, CodingKey { case type, choice, probabilities, confidence, noul }
    private enum Kind: String, Codable { case choice, noul }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .choice:
            self = .choice(
                value: try container.decode(String.self, forKey: .choice),
                probabilities: try container.decode([String: Double].self, forKey: .probabilities),
                confidence: try container.decode(Double.self, forKey: .confidence)
            )
        case .noul:
            self = .noul(try container.decode(Double.self, forKey: .noul))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .choice(let value, let probabilities, let confidence):
            try container.encode(Kind.choice, forKey: .type)
            try container.encode(value, forKey: .choice)
            try container.encode(probabilities, forKey: .probabilities)
            try container.encode(confidence, forKey: .confidence)
        case .noul(let value):
            try container.encode(Kind.noul, forKey: .type)
            try container.encode(value, forKey: .noul)
        }
    }
}

public struct TypeSafeDecisions: Sendable, Equatable, Codable {
    public let model: String
    public let answers: [String: TypeSafeAnswer]
    public let inputTokens: Int?

    public init(model: String, answers: [String: TypeSafeAnswer], inputTokens: Int? = nil) {
        self.model = model
        self.answers = answers
        self.inputTokens = inputTokens
    }
}

/// Safe failure categories. Neither underlying errors nor response bodies are exposed.
public enum TypeSafeDecisionError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidRequest
    case credentialUnavailable
    case networkFailure
    case httpStatus(Int)
    case malformedResponse

    public var description: String {
        switch self {
        case .invalidRequest: "invalid TypeSafe decision request"
        case .credentialUnavailable: "TypeSafe credential unavailable"
        case .networkFailure: "TypeSafe request failed"
        case .httpStatus(let status): "TypeSafe returned HTTP \(status)"
        case .malformedResponse: "invalid TypeSafe decision response"
        }
    }
}

/// Small, stateless System One client. Credential lookup occurs once per evaluation.
public struct TypeSafeDecisionClient: Sendable {
    public static let model = "jev-1.14.0"
    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    private let transport: any ModelHTTPExchangeTransport
    private let credentials: any ModelCredentialResolver
    private let credentialReference: ModelCredentialReference

    public init(
        transport: any ModelHTTPExchangeTransport = SharedURLSessionTransport(timeout: 8),
        credentials: any ModelCredentialResolver = ModelReferenceCredentialResolver(),
        credentialReference: ModelCredentialReference = .dotenvFile(
            path: "~/.config/daniel-tooling/ai/typesafe.env", key: "TYPESAFE_API_KEY"
        )
    ) {
        self.transport = transport
        self.credentials = credentials
        self.credentialReference = credentialReference
    }

    /// `state` must contain a JSON object. It is validated before resolving credentials.
    public func evaluate(state: Data, questions: [String: TypeSafeQuestion]) async throws -> TypeSafeDecisions {
        try Task.checkCancellation()
        guard let stateObject = try? JSONSerialization.jsonObject(with: state) as? [String: Any],
              !questions.isEmpty,
              questions.allSatisfy({ key, question in
                  guard !key.isEmpty else { return false }
                  switch question {
                  case .choice(let instructions, let criteria):
                      return !instructions.isEmpty && !criteria.isEmpty
                          && criteria.keys.allSatisfy { !$0.isEmpty }
                  case .noul(let instructions): return !instructions.isEmpty
                  }
              }) else {
            throw TypeSafeDecisionError.invalidRequest
        }

        let questionObject: [String: [String: Any]] = questions.mapValues { question in
            switch question {
            case .choice(let instructions, let criteria):
                return ["type": "choice", "instructions": instructions, "criteria": criteria]
            case .noul(let instructions):
                return ["type": "noul", "instructions": instructions]
            }
        }
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: [
                "model": Self.model, "state": stateObject, "questions": questionObject
            ], options: [.sortedKeys])
        } catch {
            throw TypeSafeDecisionError.invalidRequest
        }

        let secret: ModelResolvedSecret
        do {
            secret = try credentials.resolve(credentialReference)
        } catch {
            throw TypeSafeDecisionError.credentialUnavailable
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        secret.apply(to: &request, header: "Authorization", prefix: "Bearer ")
        try Task.checkCancellation()

        let response: ModelHTTPExchange
        do {
            response = try await transport.exchange(request)
        } catch {
            if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw TypeSafeDecisionError.networkFailure
        }
        try Task.checkCancellation()
        guard response.statusCode == 200 else {
            throw TypeSafeDecisionError.httpStatus(response.statusCode)
        }
        return try Self.parse(response.body, questions: questions)
    }

    private static func parse(_ data: Data, questions: [String: TypeSafeQuestion]) throws -> TypeSafeDecisions {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? String, !model.isEmpty,
              let rawAnswers = root["answers"] as? [String: Any],
              Set(rawAnswers.keys) == Set(questions.keys) else {
            throw TypeSafeDecisionError.malformedResponse
        }
        var answers: [String: TypeSafeAnswer] = [:]
        for (id, question) in questions {
            guard let raw = rawAnswers[id] as? [String: Any], let type = raw["type"] as? String else {
                throw TypeSafeDecisionError.malformedResponse
            }
            switch question {
            case .choice(_, let criteria):
                guard type == "choice", let selected = raw["choice"] as? String,
                      criteria[selected] != nil,
                      let rawProbabilities = raw["probabilities"] as? [String: Any],
                      Set(rawProbabilities.keys) == Set(criteria.keys),
                      let confidence = probability(raw["confidence"]) else {
                    throw TypeSafeDecisionError.malformedResponse
                }
                var probabilities: [String: Double] = [:]
                for (key, value) in rawProbabilities {
                    guard let parsed = probability(value) else { throw TypeSafeDecisionError.malformedResponse }
                    probabilities[key] = parsed
                }
                let total = probabilities.values.reduce(0, +)
                guard abs(total - 1) <= 0.01,
                      let selectedProbability = probabilities[selected],
                      selectedProbability >= (probabilities.values.max() ?? 0) - 0.000_001 else {
                    throw TypeSafeDecisionError.malformedResponse
                }
                answers[id] = .choice(value: selected, probabilities: probabilities, confidence: confidence)
            case .noul:
                guard type == "noul", let value = probability(raw["noul"]) else {
                    throw TypeSafeDecisionError.malformedResponse
                }
                answers[id] = .noul(value)
            }
        }
        var inputTokens: Int?
        if let usage = root["usage"] {
            guard let usage = usage as? [String: Any] else { throw TypeSafeDecisionError.malformedResponse }
            if let rawTokens = usage["input_tokens"] {
                guard let number = rawTokens as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite,
                      number.doubleValue >= 0,
                      number.doubleValue.rounded() == number.doubleValue,
                      number.doubleValue <= Double(Int.max) else {
                    throw TypeSafeDecisionError.malformedResponse
                }
                inputTokens = number.intValue
            }
        }
        return TypeSafeDecisions(model: model, answers: answers, inputTokens: inputTokens)
    }

    private static func probability(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite && (0...1).contains(value) ? value : nil
    }
}
