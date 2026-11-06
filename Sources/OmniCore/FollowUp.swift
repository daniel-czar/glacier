import Foundation

/// A result is immutable once recorded. The operation and selected source
/// make each rewrite legible without reconstructing hidden prompt history.
public struct OmniResultVersion: Codable, Sendable, Equatable, Identifiable {
    public let number: Int
    public let inputText: String
    public let resultText: String
    public let operation: OmniFollowUpOperation
    public let sourceVersion: Int?
    public let createdAt: Date
    /// Ranges refer to this version's `inputText` as displayed in the history.
    public let annotations: [OmniTextAnnotation]

    public var id: Int { number }

    public init(
        number: Int,
        inputText: String,
        resultText: String,
        operation: OmniFollowUpOperation,
        sourceVersion: Int? = nil,
        createdAt: Date = Date(),
        annotations: [OmniTextAnnotation] = []
    ) {
        self.number = number
        self.inputText = inputText
        self.resultText = resultText
        self.operation = operation
        self.sourceVersion = sourceVersion
        self.createdAt = createdAt
        self.annotations = annotations
    }

    private enum CodingKeys: String, CodingKey {
        case number, inputText, resultText, operation, sourceVersion, createdAt, annotations
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        number = try values.decode(Int.self, forKey: .number)
        inputText = try values.decode(String.self, forKey: .inputText)
        resultText = try values.decode(String.self, forKey: .resultText)
        operation = try values.decode(OmniFollowUpOperation.self, forKey: .operation)
        sourceVersion = try values.decodeIfPresent(Int.self, forKey: .sourceVersion)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        annotations = try values.decodeIfPresent([OmniTextAnnotation].self, forKey: .annotations) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(number, forKey: .number)
        try values.encode(inputText, forKey: .inputText)
        try values.encode(resultText, forKey: .resultText)
        try values.encode(operation, forKey: .operation)
        try values.encodeIfPresent(sourceVersion, forKey: .sourceVersion)
        try values.encode(createdAt, forKey: .createdAt)
        if !annotations.isEmpty { try values.encode(annotations, forKey: .annotations) }
    }
}

public enum OmniFollowUpOperation: String, Codable, Sendable, Equatable, CaseIterable {
    case initial
    case shorter
    case formal

    init?(token: Substring) {
        self.init(atom: SlashAtom.parse(String(token)))
    }

    init?(atom: SlashAtom?) {
        guard let atom else { return nil }
        switch atom.name.lowercased() {
        case "shorter": self = .shorter
        case "formal": self = .formal
        case "style" where atom.value == "formal": self = .formal
        default: return nil
        }
    }

    /// Parses Omni's single editable follow-up field. Exactly one supported
    /// command token may appear anywhere in the field; its removal leaves the
    /// edited source that is sent to the model. A selected result version is a
    /// history anchor only, never a hidden second prompt input.
    public static func parse(visibleText: String) throws -> OmniFollowUpInput {
        let tokens = visibleText.split(whereSeparator: \.isWhitespace)
        // A path such as `/usr/bin` remains edited prose. A bare slash token
        // is treated as an attempted follow-up operation and must be one of
        // the bounded set below. Valued tokens `/shorter:25%` and
        // `/style:formal` are slash atoms; inner slashes still mark paths.
        let commandTokens = tokens.filter { SlashAtom.parse(String($0)) != nil }
        let parsed = commandTokens.compactMap { token -> (Substring, OmniFollowUpOperation, LengthValue?)? in
            let atom = SlashAtom.parse(String(token))
            guard let operation = OmniFollowUpOperation(atom: atom) else { return nil }
            let length: LengthValue?
            if operation == .shorter, let raw = atom?.value {
                guard let parsedLength = LengthValue.parse(raw) else { return nil }
                length = parsedLength
            } else {
                length = nil
            }
            if operation == .formal, let value = atom?.value, value != "formal" {
                return nil
            }
            return (token, operation, length)
        }
        guard commandTokens.count == 1, parsed.count == 1, let match = parsed.first else {
            throw OmniFollowUpInputError.unsupportedOrAmbiguousOperation
        }
        var editedSourceText = visibleText
        let operationToken = match.0
        editedSourceText.removeSubrange(operationToken.startIndex..<operationToken.endIndex)
        editedSourceText = editedSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !editedSourceText.isEmpty else { throw OmniFollowUpInputError.emptyEditedSource }
        return OmniFollowUpInput(operation: match.1, editedSourceText: editedSourceText, length: match.2)
    }

    public var displayName: String {
        switch self {
        case .initial: "Initial"
        case .shorter: "Shorter"
        case .formal: "More formal"
        }
    }
}

public enum OmniFollowUpInputError: Error, Sendable, Equatable {
    case unsupportedOrAmbiguousOperation
    case emptyEditedSource
}

public struct OmniFollowUpInput: Sendable, Equatable {
    public let operation: OmniFollowUpOperation
    public let editedSourceText: String
    public let length: LengthValue?

    public init(operation: OmniFollowUpOperation, editedSourceText: String, length: LengthValue? = nil) {
        self.operation = operation
        self.editedSourceText = editedSourceText
        self.length = length
    }
}

public enum OmniFollowUpStateKind: String, Codable, Sendable, Equatable {
    case pending
    case cancelled
    case failed
}

/// Renderer-facing state for follow-up work. A successful request clears the
/// state because the appended immutable version is the visible completion.
public struct OmniFollowUpState: Codable, Sendable, Equatable {
    public let kind: OmniFollowUpStateKind
    public let requestID: String
    public let sourceVersion: Int
    public let visibleText: String
    public let updatedAt: Date
    public let message: String?
    /// Ranges refer to `visibleText`, including its operation token.
    public let annotations: [OmniTextAnnotation]
    public let annotationNotice: String?

    public init(
        kind: OmniFollowUpStateKind,
        requestID: String,
        sourceVersion: Int,
        visibleText: String,
        updatedAt: Date = Date(),
        message: String? = nil,
        annotations: [OmniTextAnnotation] = [],
        annotationNotice: String? = nil
    ) {
        self.kind = kind
        self.requestID = requestID
        self.sourceVersion = sourceVersion
        self.visibleText = visibleText
        self.updatedAt = updatedAt
        self.message = message
        self.annotations = annotations
        self.annotationNotice = annotationNotice
    }

    private enum CodingKeys: String, CodingKey {
        case kind, requestID, sourceVersion, visibleText, updatedAt, message, annotations, annotationNotice
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(OmniFollowUpStateKind.self, forKey: .kind)
        requestID = try values.decode(String.self, forKey: .requestID)
        sourceVersion = try values.decode(Int.self, forKey: .sourceVersion)
        visibleText = try values.decode(String.self, forKey: .visibleText)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        message = try values.decodeIfPresent(String.self, forKey: .message)
        annotations = try values.decodeIfPresent([OmniTextAnnotation].self, forKey: .annotations) ?? []
        annotationNotice = try values.decodeIfPresent(String.self, forKey: .annotationNotice)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encode(requestID, forKey: .requestID)
        try values.encode(sourceVersion, forKey: .sourceVersion)
        try values.encode(visibleText, forKey: .visibleText)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encodeIfPresent(message, forKey: .message)
        if !annotations.isEmpty { try values.encode(annotations, forKey: .annotations) }
        try values.encodeIfPresent(annotationNotice, forKey: .annotationNotice)
    }
}

public struct FollowUpGenerationRequest: Sendable, Equatable {
    public let runID: String
    public let modelCommandID: String
    public let sourceVersion: Int
    public let sourceText: String
    public let visibleText: String
    public let operation: OmniFollowUpOperation
    public let length: LengthValue?
    public let offline: Bool
    /// The application's follow-up request ID doubles as this generation's
    /// correlation ID. It is distinct from the durable RunID.
    public let requestID: String
    /// The new invocation's explicit selection only. A previous invocation's
    /// provider override is never inherited by a follow-up.
    public let modelSelection: ModelInvocationSelection?
    /// Ranges refer to `visibleText`; prompt serialisation projects them onto
    /// `sourceText` after the operation token is removed.
    public let annotations: [OmniTextAnnotation]

    public init(
        runID: String,
        modelCommandID: String,
        sourceVersion: Int,
        sourceText: String,
        visibleText: String,
        operation: OmniFollowUpOperation,
        length: LengthValue? = nil,
        offline: Bool,
        requestID: String = UUID().uuidString.lowercased(),
        modelSelection: ModelInvocationSelection? = nil,
        annotations: [OmniTextAnnotation] = []
    ) {
        self.runID = runID
        self.modelCommandID = modelCommandID
        self.sourceVersion = sourceVersion
        self.sourceText = sourceText
        self.visibleText = visibleText
        self.operation = operation
        self.length = length
        self.offline = offline
        self.requestID = requestID
        self.modelSelection = modelSelection
        self.annotations = annotations
    }

    /// The request contains the one edited field after its explicit operation
    /// token has been removed. It deliberately never incorporates the
    /// originally selected text or prior rewrite prompts.
    public var prompt: String {
        prompt(annotationFormat: nil)
    }

    /// Explicit format supports the isolated prompt A/B through the same
    /// production builder. The environment is consulted only for noted input.
    public func prompt(annotationFormat: OmniAnnotationPromptFormat?) -> String {
        let guidance: String = switch operation {
        case .shorter:
            if let length {
                switch length.unit {
                case .percent:
                    "Produce one version whose length is about \(length.canonical) of the source that keeps the draft's purpose, facts, recipient address, register and sign-off shape. Cut words and redundancy, not meaning."
                case .words:
                    "Produce one version of about \(Self.render(length.magnitude)) words that keeps the draft's purpose, facts, recipient address, register and sign-off shape. Cut words and redundancy, not meaning."
                case .sentences:
                    "Produce one version of about \(Self.render(length.magnitude)) sentences that keeps the draft's purpose, facts, recipient address, register and sign-off shape. Cut words and redundancy, not meaning."
                }
            } else {
                "Produce one noticeably shorter version (roughly a third to a half shorter) that keeps the draft's purpose, facts, recipient address, register and sign-off shape. Cut words and redundancy, not meaning."
            }
        case .formal: "Produce one version in a formally courteous, direct register that keeps the draft's purpose, facts and structure. Do not add obligations, deadlines or pleasantries the draft does not contain."
        case .initial: "Produce one clean version of the draft as edited, preserving its purpose, facts and register."
        }
        let rendering: OmniAnnotationPromptRendering
        if annotations.isEmpty {
            rendering = OmniAnnotationPromptRendering(userText: sourceText, metaSuffix: "")
        } else {
            let projected = (try? OmniAnnotationProjection.followUp(
                from: visibleText,
                matching: sourceText,
                annotations: annotations
            )) ?? OmniAnnotationProjection.rawOnly(from: visibleText, annotations: annotations)
            rendering = OmniAnnotationPrompt.render(
                payloadText: sourceText,
                projected: projected,
                format: annotationFormat ?? .configuredDefault,
                sourceText: visibleText
            )
        }
        return """
        Rewrite the edited draft.
        Operation: \(operation.rawValue)
        \(guidance)

        \(ModelOutputDiscipline.instruction)

        Edited draft:\n\(rendering.userText)\(rendering.metaSuffix)
        """
    }

    private static func render(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value)
        if value == Decimal(number.intValue) { return String(number.intValue) }
        return number.stringValue
    }
}

public struct FollowUpGeneration: Sendable, Equatable {
    public let resultText: String
    public let modelRecord: ModelExecutionRecord?

    public init(resultText: String, modelRecord: ModelExecutionRecord? = nil) {
        self.resultText = resultText
        self.modelRecord = modelRecord
    }
}

/// The application service owns run identity, source selection, persistence,
/// and cancellation races. A generator only receives a bounded rewrite request.
public protocol FollowUpGenerating: Sendable {
    func generate(_ request: FollowUpGenerationRequest) async throws -> FollowUpGeneration
    func cancel(runID: String) async
}

public extension FollowUpGenerating {
    func cancel(runID: String) async {}
}
