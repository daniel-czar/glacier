import Foundation

/// Where a run's request text came from. Best-effort: every field may be
/// absent when the run was typed directly or capture could not identify the
/// source.
public struct OmniRunProvenance: Codable, Sendable, Equatable {
    public let appName: String?
    public let windowTitle: String?
    public let wordCount: Int
    /// The source app's bundle identifier, for its icon in the header (D3).
    /// Optional and decoded if present: records written before it existed
    /// decode unchanged and fall back to a lookup by name.
    public let bundleIdentifier: String?

    public init(appName: String?, windowTitle: String?, wordCount: Int, bundleIdentifier: String? = nil) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.wordCount = wordCount
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Versioned runtime data accompanies the frozen receipt contract. Old events
/// lack this optional envelope and retain their original interpretation.
public struct RuntimeRunContext: Codable, Sendable, Equatable {
    public static let currentVersion = 2

    public var version: Int
    public var input: ModuleInput?
    public var proposal: ProposalEnvelope?
    public var approvedPlanHash: String?
    public var parentRunID: String?
    public var stepIndex: Int?
    public var childRunIDs: [String]
    public var completedSteps: [Int]
    public var fullText: String?
    public var modelRecords: [ModelExecutionRecord]
    /// Immutable result history for terminal runs. Version one of a newly
    /// completed model-backed result is written with its terminal receipt;
    /// later in-run rewrites append here without reopening the run.
    public var resultVersions: [OmniResultVersion]
    /// A follow-up has no separate run lifecycle. Its small, durable view
    /// state survives a host restart and is intentionally independent from
    /// the terminal state of the parent run.
    public var followUpState: OmniFollowUpState?
    /// Where the request text came from, when capture identified a source.
    public var provenance: OmniRunProvenance?
    /// Guidance ranges are measured against the original editor text in
    /// `input.rawText`, never against its canonical or token-stripped form.
    public var annotations: [OmniTextAnnotation]
    /// User-visible explanation when notes could not be transferred safely.
    public var annotationNotice: String?
    /// The run this one was drafted from: a `/stance` run whose chosen
    /// position became this run's request note (D6). Additive and optional;
    /// older events decode without it and `currentVersion` is unchanged.
    public var originRunID: String?
    /// A `/find` run's query and rows (D2). Additive and optional: older
    /// binaries ignore it and read the path list in `fullText`.
    public var find: OmniFindResult?

    public init(
        input: ModuleInput? = nil,
        proposal: ProposalEnvelope? = nil,
        approvedPlanHash: String? = nil,
        parentRunID: String? = nil,
        stepIndex: Int? = nil,
        childRunIDs: [String] = [],
        completedSteps: [Int] = [],
        fullText: String? = nil,
        modelRecords: [ModelExecutionRecord] = [],
        resultVersions: [OmniResultVersion] = [],
        followUpState: OmniFollowUpState? = nil,
        provenance: OmniRunProvenance? = nil,
        annotations: [OmniTextAnnotation] = [],
        annotationNotice: String? = nil,
        originRunID: String? = nil,
        find: OmniFindResult? = nil
    ) {
        version = Self.currentVersion
        self.input = input
        self.proposal = proposal
        self.approvedPlanHash = approvedPlanHash
        self.parentRunID = parentRunID
        self.stepIndex = stepIndex
        self.childRunIDs = childRunIDs
        self.completedSteps = completedSteps
        self.fullText = fullText
        self.modelRecords = modelRecords
        self.resultVersions = resultVersions
        self.followUpState = followUpState
        self.provenance = provenance
        self.annotations = annotations
        self.annotationNotice = annotationNotice
        self.originRunID = originRunID
        self.find = find
    }

    enum CodingKeys: String, CodingKey {
        case version, input, proposal, approvedPlanHash, parentRunID, stepIndex
        case childRunIDs, completedSteps, fullText, modelRecords, resultVersions, followUpState, provenance, annotations, annotationNotice
        case originRunID
        case find
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard (1...Self.currentVersion).contains(decodedVersion) else {
            throw RuntimeRunContextError.unsupportedVersion(decodedVersion)
        }
        version = decodedVersion
        input = try values.decodeIfPresent(ModuleInput.self, forKey: .input)
        proposal = try values.decodeIfPresent(ProposalEnvelope.self, forKey: .proposal)
        approvedPlanHash = try values.decodeIfPresent(String.self, forKey: .approvedPlanHash)
        parentRunID = try values.decodeIfPresent(String.self, forKey: .parentRunID)
        stepIndex = try values.decodeIfPresent(Int.self, forKey: .stepIndex)
        childRunIDs = try values.decodeIfPresent([String].self, forKey: .childRunIDs) ?? []
        completedSteps = try values.decodeIfPresent([Int].self, forKey: .completedSteps) ?? []
        fullText = try values.decodeIfPresent(String.self, forKey: .fullText)
        modelRecords = try values.decodeIfPresent([ModelExecutionRecord].self, forKey: .modelRecords) ?? []
        resultVersions = try values.decodeIfPresent([OmniResultVersion].self, forKey: .resultVersions) ?? []
        followUpState = try values.decodeIfPresent(OmniFollowUpState.self, forKey: .followUpState)
        provenance = try values.decodeIfPresent(OmniRunProvenance.self, forKey: .provenance)
        annotations = try values.decodeIfPresent([OmniTextAnnotation].self, forKey: .annotations) ?? []
        annotationNotice = try values.decodeIfPresent(String.self, forKey: .annotationNotice)
        originRunID = try values.decodeIfPresent(String.self, forKey: .originRunID)
        find = try values.decodeIfPresent(OmniFindResult.self, forKey: .find)
    }

    public func encode(to encoder: any Encoder) throws {
        guard (1...Self.currentVersion).contains(version) else {
            throw RuntimeRunContextError.unsupportedVersion(version)
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encodeIfPresent(input, forKey: .input)
        try values.encodeIfPresent(proposal, forKey: .proposal)
        try values.encodeIfPresent(approvedPlanHash, forKey: .approvedPlanHash)
        try values.encodeIfPresent(parentRunID, forKey: .parentRunID)
        try values.encodeIfPresent(stepIndex, forKey: .stepIndex)
        try values.encode(childRunIDs, forKey: .childRunIDs)
        try values.encode(completedSteps, forKey: .completedSteps)
        try values.encodeIfPresent(fullText, forKey: .fullText)
        try values.encode(modelRecords, forKey: .modelRecords)
        try values.encode(resultVersions, forKey: .resultVersions)
        try values.encodeIfPresent(followUpState, forKey: .followUpState)
        try values.encodeIfPresent(provenance, forKey: .provenance)
        if !annotations.isEmpty { try values.encode(annotations, forKey: .annotations) }
        try values.encodeIfPresent(annotationNotice, forKey: .annotationNotice)
        try values.encodeIfPresent(originRunID, forKey: .originRunID)
        try values.encodeIfPresent(find, forKey: .find)
    }
}

public enum RuntimeRunContextError: Error, Sendable, Equatable {
    case unsupportedVersion(Int)
}

/// Proposal providers return only a small JSON language, never execution tools.
/// Run identity supervises inference; validation owns every executable field.
public protocol ProposalGenerating: Sendable {
    func generate(intent: ParsedIntent, runID: String) async throws -> ProposalGeneration
    /// Proposal generation with this invocation's explicit model selection.
    /// Selection is routing data only; it grants no proposal authority.
    func generate(intent: ParsedIntent, runID: String, modelSelection: ModelInvocationSelection?) async throws -> ProposalGeneration
    func cancel(runID: String) async
    func modelExecutionRecord(runID: String) async -> ModelExecutionRecord?
}

public extension ProposalGenerating {
    func generate(intent: ParsedIntent, runID: String, modelSelection: ModelInvocationSelection?) async throws -> ProposalGeneration {
        try await generate(intent: intent, runID: runID)
    }
    func cancel(runID: String) async {}
    func modelExecutionRecord(runID: String) async -> ModelExecutionRecord? { nil }
}

public struct ProposalGeneration: Sendable {
    public let json: Data
    public let modelRecord: ModelExecutionRecord?
    public init(json: Data, modelRecord: ModelExecutionRecord? = nil) {
        self.json = json
        self.modelRecord = modelRecord
    }
}
