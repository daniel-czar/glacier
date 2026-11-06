import Foundation
import OmniCore

public enum RegexModelError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidReply(String)

    public var description: String {
        switch self { case .invalidReply(let reason): reason }
    }
}

/// Produces an ICU pattern and examples. Diagramming and example judgments
/// belong to local code, not to the provider.
public enum RegexModelGenerator {
    public static let commandID = "regex.write"
    public static let maximumReplyCharacters = 6_000

    public static func request(intent: String, runID: String = UUID().uuidString.lowercased(),
                               profileID: String = ProviderRuntimeCatalog.cerebrasRegexHighProfileID) -> ModelGenerationRequest {
        let prompt = """
        Prefer a compact pattern; satisfy every explicit constraint in the user's request. Avoid extra domain validation beyond those constraints. Describe known limitations in note when relevant. Return exactly three brief shouldMatch examples and two brief shouldNotMatch examples.

        Write one regular expression in ICU syntax for the user's request. Return exactly one JSON object with required keys pattern, flavor, name, shouldMatch, shouldNotMatch and optional key note. No other keys, Markdown, code fence or prose.

        pattern: nonempty ICU regex string. flavor: exactly "icu". name: short human-readable name. shouldMatch: array of at least 3 different example strings expected to match. shouldNotMatch: array of at least 2 different example strings expected not to match. note: optional string of at most 12 words describing a known limitation. Examples should be realistic and challenging. Do not draw a diagram or state whether examples actually pass: the local ICU engine checks every one.

        User request: \(intent)
        """
        return ModelGenerationRequest(
            runID: runID,
            commandID: commandID,
            prompt: prompt,
            offline: false,
            // Keep high reasoning free of transport-level JSON constraints;
            // parse() validates the complete JSON contract locally, as Map does.
            outputConstraint: .plainText(maximumCharacters: maximumReplyCharacters),
            dispatch: .init(generationID: UUID().uuidString.lowercased(), selection: ModelInvocationSelection(profileID: profileID))
        )
    }

    public static func generate(intent: String, broker: ProviderRuntimeBrokerStore,
                                runID: String = UUID().uuidString.lowercased(),
                                profileID: String = ProviderRuntimeCatalog.cerebrasRegexHighProfileID) async throws -> RegexGeneratedPattern {
        let result = try await broker.executeOnce(request(intent: intent, runID: runID, profileID: profileID))
        try Task.checkCancellation()
        return try parse(result.response.text)
    }

    public static func parse(_ text: String) throws -> RegexGeneratedPattern {
        guard text.count <= maximumReplyCharacters else { throw RegexModelError.invalidReply("The regex reply is too long") }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw RegexModelError.invalidReply("The regex reply must be one JSON object")
        }
        let required: Set<String> = ["pattern", "flavor", "name", "shouldMatch", "shouldNotMatch"]
        let keys = Set(object.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(["note"])) else {
            throw RegexModelError.invalidReply("The regex reply has missing or unknown keys")
        }
        guard let pattern = object["pattern"] as? String,
              !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pattern.count <= 4_096 else {
            throw RegexModelError.invalidReply("The regex pattern is empty or missing")
        }
        guard let flavor = object["flavor"] as? String, flavor == "icu" else {
            throw RegexModelError.invalidReply("The regex flavor must be icu")
        }
        guard let name = object["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RegexModelError.invalidReply("The regex name is empty or missing")
        }
        guard let shouldMatch = object["shouldMatch"] as? [String], shouldMatch.count >= 3,
              let shouldNotMatch = object["shouldNotMatch"] as? [String], shouldNotMatch.count >= 2 else {
            throw RegexModelError.invalidReply("The regex reply needs at least 3 positive and 2 negative examples")
        }
        let note: String?
        if let supplied = object["note"] {
            guard let value = supplied as? String else { throw RegexModelError.invalidReply("The regex note must be a string") }
            guard value.split(whereSeparator: \.isWhitespace).count <= 12 else {
                throw RegexModelError.invalidReply("The regex note exceeds 12 words")
            }
            note = value
        } else {
            note = nil
        }
        return RegexGeneratedPattern(pattern: pattern, flavor: flavor, name: name,
                                     shouldMatch: shouldMatch, shouldNotMatch: shouldNotMatch, note: note)
    }
}
