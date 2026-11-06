import CryptoKit
import Foundation

/// A versioned, locally-validated Tier 2 plan. The model never constructs this
/// value directly: it supplies only command strings, which `ProposalPlanValidator`
/// parses and turns into typed steps.
public struct ProposalEnvelope: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let alternatives: [ValidatedProposalAlternative]
    public let rawText: String
    public let canonicalText: String
    public let modifiers: Set<String>
    public let modes: Set<String>
    public let markers: [String]
    public let references: [PinnedReference]
    public let createdAt: Date
    public let expiresAt: Date
    public let authorityDigest: String
    public let runtimeVersion: String

    public init(
        alternatives: [ValidatedProposalAlternative],
        rawText: String,
        canonicalText: String,
        modifiers: Set<String>,
        modes: Set<String>,
        markers: [String],
        references: [PinnedReference],
        createdAt: Date,
        expiresAt: Date,
        authorityDigest: String,
        runtimeVersion: String,
        schemaVersion: Int = ProposalEnvelope.schemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.alternatives = alternatives
        self.rawText = rawText
        self.canonicalText = canonicalText
        self.modifiers = modifiers
        self.modes = modes
        self.markers = markers
        self.references = references
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.authorityDigest = authorityDigest
        self.runtimeVersion = runtimeVersion
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, alternatives, rawText, canonicalText, modifiers, modes, markers, references
        case createdAt, expiresAt, authorityDigest, runtimeVersion
    }

    public init(from decoder: any Decoder) throws {
        try ProposalCoding.requireOnlyKnownKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        alternatives = try values.decode([ValidatedProposalAlternative].self, forKey: .alternatives)
        rawText = try values.decode(String.self, forKey: .rawText)
        canonicalText = try values.decode(String.self, forKey: .canonicalText)
        modifiers = try values.decode(Set<String>.self, forKey: .modifiers)
        modes = try values.decode(Set<String>.self, forKey: .modes)
        markers = try values.decode([String].self, forKey: .markers)
        references = try values.decode([ProposalPinnedReference].self, forKey: .references).map(\.value)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        expiresAt = try values.decode(Date.self, forKey: .expiresAt)
        authorityDigest = try values.decode(String.self, forKey: .authorityDigest)
        runtimeVersion = try values.decode(String.self, forKey: .runtimeVersion)
    }
}

public struct ValidatedProposalAlternative: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let planHash: String
    public let steps: [ValidatedProposalStep]

    public init(id: String, title: String, planHash: String, steps: [ValidatedProposalStep]) {
        self.id = id
        self.title = title
        self.planHash = planHash
        self.steps = steps
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case id, title, planHash, steps }

    public init(from decoder: any Decoder) throws {
        try ProposalCoding.requireOnlyKnownKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        planHash = try values.decode(String.self, forKey: .planHash)
        steps = try values.decode([ValidatedProposalStep].self, forKey: .steps)
    }
}

public struct ValidatedProposalStep: Codable, Sendable, Equatable {
    public let moduleID: String
    public let input: ModuleInput
    public let capabilities: [Capability]
    public let ownerOperation: OwnerOperation?
    public let offline: Bool

    public init(
        moduleID: String,
        input: ModuleInput,
        capabilities: [Capability],
        ownerOperation: OwnerOperation?,
        offline: Bool
    ) {
        self.moduleID = moduleID
        self.input = input
        self.capabilities = capabilities.sorted { $0.rawValue < $1.rawValue }
        self.ownerOperation = ownerOperation
        self.offline = offline
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case moduleID, input, capabilities, ownerOperation, offline
    }

    public init(from decoder: any Decoder) throws {
        try ProposalCoding.requireOnlyKnownKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        moduleID = try values.decode(String.self, forKey: .moduleID)
        input = try ProposalModuleInput(from: values.superDecoder(forKey: .input)).value
        capabilities = try values.decode([Capability].self, forKey: .capabilities)
            .sorted { $0.rawValue < $1.rawValue }
        ownerOperation = try values.decodeIfPresent(OwnerOperation.self, forKey: .ownerOperation)
        offline = try values.decode(Bool.self, forKey: .offline)
    }
}

/// The authority and reference snapshot used to bind a proposal to the exact
/// execution surface that existed when it was generated.
public struct ProposalAuthoritySnapshot: Codable, Sendable, Equatable {
    public let allowedCapabilities: Set<Capability>
    public let allowedOwnerOperations: Set<OwnerOperation>
    public let referenceDigest: String
    public let offline: Bool
    public let digest: String

    public init(
        allowedCapabilities: Set<Capability>,
        allowedOwnerOperations: Set<OwnerOperation>,
        references: [PinnedReference],
        offline: Bool
    ) {
        self.allowedCapabilities = allowedCapabilities
        self.allowedOwnerOperations = allowedOwnerOperations
        referenceDigest = ProposalHashing.referenceDigest(references)
        self.offline = offline
        digest = ProposalHashing.authorityDigest(
            allowedCapabilities: allowedCapabilities,
            allowedOwnerOperations: allowedOwnerOperations,
            referenceDigest: referenceDigest,
            offline: offline
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case allowedCapabilities, allowedOwnerOperations, referenceDigest, offline, digest
    }

    public init(from decoder: any Decoder) throws {
        try ProposalCoding.requireOnlyKnownKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        allowedCapabilities = try values.decode(Set<Capability>.self, forKey: .allowedCapabilities)
        allowedOwnerOperations = try values.decode(Set<OwnerOperation>.self, forKey: .allowedOwnerOperations)
        referenceDigest = try values.decode(String.self, forKey: .referenceDigest)
        offline = try values.decode(Bool.self, forKey: .offline)
        digest = try values.decode(String.self, forKey: .digest)
        guard digest == ProposalHashing.authorityDigest(
            allowedCapabilities: allowedCapabilities,
            allowedOwnerOperations: allowedOwnerOperations,
            referenceDigest: referenceDigest,
            offline: offline
        ) else { throw OmniCoreError.invalidProposal }
    }
}

/// Pure schema and authority validator for a Tier 2 proposal. It never starts a
/// module or opens an owner handle; the application layer owns durable, one-use
/// confirmation and sequential execution.
public struct ProposalPlanValidator: Sendable {
    public static let defaultRuntimeVersion = "omni-phase4-proposal-v1"

    public let parser: OmniParser
    public let registry: ModuleRegistry
    public let runtimeVersion: String
    public let proposalLifetime: TimeInterval
    public let maximumStepsPerAlternative: Int

    public init(
        parser: OmniParser,
        registry: ModuleRegistry,
        runtimeVersion: String = ProposalPlanValidator.defaultRuntimeVersion,
        proposalLifetime: TimeInterval = 300,
        maximumStepsPerAlternative: Int = 4
    ) {
        self.parser = parser
        self.registry = registry
        self.runtimeVersion = runtimeVersion
        self.proposalLifetime = proposalLifetime
        self.maximumStepsPerAlternative = maximumStepsPerAlternative
    }

    public func makeAuthoritySnapshot(
        allowedCapabilities: Set<Capability>,
        allowedOwnerOperations: Set<OwnerOperation>,
        offline: Bool
    ) -> ProposalAuthoritySnapshot {
        ProposalAuthoritySnapshot(
            allowedCapabilities: allowedCapabilities,
            allowedOwnerOperations: allowedOwnerOperations,
            references: parser.references.all,
            offline: offline
        )
    }

    /// Decodes only the tiny model schema `{ alternatives: [{ id, title,
    /// commands }] }`. All envelopes, timestamps, authority bindings, typed
    /// inputs, capability sets, owner operations, and hashes are created here.
    public func decodeModelProposal(
        _ data: Data,
        for intent: ParsedIntent,
        authority: ProposalAuthoritySnapshot,
        now: Date
    ) throws -> ProposalEnvelope {
        let draft = try JSONDecoder().decode(ModelProposalDraft.self, from: data)
        let submission = try validatedSubmission(for: intent)
        guard draft.alternatives.count >= 1, draft.alternatives.count <= 3 else {
            throw OmniCoreError.invalidProposal
        }
        guard Set(draft.alternatives.map(\.id)).count == draft.alternatives.count else {
            throw OmniCoreError.invalidProposal
        }

        let expiresAt = now.addingTimeInterval(proposalLifetime)
        let inheritedOffline = authority.offline || submission.modes.contains("/offline")
        var alternatives: [ValidatedProposalAlternative] = []
        for draftAlternative in draft.alternatives {
            try validateAlternativeIdentity(draftAlternative.id, title: draftAlternative.title)
            guard draftAlternative.commands.count >= 1,
                  draftAlternative.commands.count <= maximumStepsPerAlternative
            else { throw OmniCoreError.invalidProposal }
            let steps = try draftAlternative.commands.map {
                try makeStep(
                    commandText: $0,
                    submission: submission,
                    authority: authority,
                    inheritedOffline: inheritedOffline
                )
            }
            let planHash = try ProposalHashing.planHash(
                submission: submission,
                authorityDigest: authority.digest,
                runtimeVersion: runtimeVersion,
                createdAt: now,
                expiresAt: expiresAt,
                alternativeID: draftAlternative.id,
                title: draftAlternative.title,
                steps: steps
            )
            alternatives.append(ValidatedProposalAlternative(
                id: draftAlternative.id,
                title: draftAlternative.title,
                planHash: planHash,
                steps: steps
            ))
        }

        let envelope = ProposalEnvelope(
            alternatives: alternatives,
            rawText: submission.rawText,
            canonicalText: submission.canonicalText,
            modifiers: submission.modifiers,
            modes: submission.modes,
            markers: submission.markers,
            references: submission.references,
            createdAt: now,
            expiresAt: expiresAt,
            authorityDigest: authority.digest,
            runtimeVersion: runtimeVersion
        )
        try validate(envelope: envelope, authority: authority, now: now)
        return envelope
    }

    public func validate(
        envelope: ProposalEnvelope,
        authority: ProposalAuthoritySnapshot,
        now: Date
    ) throws {
        guard envelope.schemaVersion == ProposalEnvelope.schemaVersion,
              envelope.runtimeVersion == runtimeVersion,
              envelope.authorityDigest == authority.digest,
              envelope.createdAt <= envelope.expiresAt,
              envelope.createdAt <= now,
              envelope.expiresAt.timeIntervalSince(envelope.createdAt) <= proposalLifetime,
              now <= envelope.expiresAt,
              envelope.alternatives.count >= 1,
              envelope.alternatives.count <= 3
        else { throw OmniCoreError.invalidProposal }

        let submission = try validatedSubmission(from: envelope)
        guard Set(envelope.alternatives.map(\.id)).count == envelope.alternatives.count else {
            throw OmniCoreError.invalidProposal
        }
        let inheritedOffline = authority.offline || submission.modes.contains("/offline")
        for alternative in envelope.alternatives {
            try validateAlternativeIdentity(alternative.id, title: alternative.title)
            guard alternative.steps.count >= 1, alternative.steps.count <= maximumStepsPerAlternative else {
                throw OmniCoreError.invalidProposal
            }
            for step in alternative.steps {
                try validate(step: step, submission: submission, authority: authority, inheritedOffline: inheritedOffline)
            }
            let expectedHash = try ProposalHashing.planHash(
                submission: submission,
                authorityDigest: authority.digest,
                runtimeVersion: runtimeVersion,
                createdAt: envelope.createdAt,
                expiresAt: envelope.expiresAt,
                alternativeID: alternative.id,
                title: alternative.title,
                steps: alternative.steps
            )
            guard alternative.planHash == expectedHash else { throw OmniCoreError.invalidProposal }
        }
    }

    /// This performs validation only. A caller must persist and consume the
    /// confirmation separately before starting the returned sequence.
    public func confirm(
        envelope: ProposalEnvelope,
        exactPlanHash: String,
        authority: ProposalAuthoritySnapshot,
        now: Date
    ) throws -> ValidatedProposalAlternative {
        try validate(envelope: envelope, authority: authority, now: now)
        guard let alternative = envelope.alternatives.first(where: { $0.planHash == exactPlanHash }) else {
            throw OmniCoreError.confirmationMismatch
        }
        return alternative
    }

    private func makeStep(
        commandText: String,
        submission: ProposalSubmission,
        authority: ProposalAuthoritySnapshot,
        inheritedOffline: Bool
    ) throws -> ValidatedProposalStep {
        guard commandText.utf8.count <= 4_096, !ProposalCoding.containsForbiddenModelSyntax(commandText) else {
            throw OmniCoreError.invalidProposal
        }
        let parsed = parser.parse(commandText)
        let input = try moduleInput(from: parsed, rawText: commandText)
        guard references(input.references, areSubsetOf: submission.references) else {
            throw OmniCoreError.invalidProposal
        }
        guard !submission.modes.contains("/offline") || input.modes.contains("/offline") else {
            throw OmniCoreError.invalidProposal
        }
        return try validatedStep(input: input, authority: authority, inheritedOffline: inheritedOffline)
    }

    private func validate(
        step: ValidatedProposalStep,
        submission: ProposalSubmission,
        authority: ProposalAuthoritySnapshot,
        inheritedOffline: Bool
    ) throws {
        let parsed = parser.parse(step.input.rawText)
        let expectedInput = try moduleInput(from: parsed, rawText: step.input.rawText)
        guard step.input == expectedInput,
              references(step.input.references, areSubsetOf: submission.references),
              !submission.modes.contains("/offline") || step.input.modes.contains("/offline")
        else { throw OmniCoreError.invalidProposal }
        let expected = try validatedStep(input: expectedInput, authority: authority, inheritedOffline: inheritedOffline)
        guard step == expected else { throw OmniCoreError.invalidProposal }
    }

    private func validatedStep(
        input: ModuleInput,
        authority: ProposalAuthoritySnapshot,
        inheritedOffline: Bool
    ) throws -> ValidatedProposalStep {
        let parsed = parser.parse(input.rawText)
        guard case let .tier1(dispatchToken) = SubmissionClassifier().classify(parsed),
              let command = parser.manifest.command(for: dispatchToken),
              let factory = registry.factory(for: command.moduleID)
        else { throw OmniCoreError.invalidProposal }

        let module = factory.build()
        guard module.descriptor.moduleID == command.moduleID,
              module.descriptor.execution == command.execution
        else { throw OmniCoreError.invalidProposal }
        try module.validate(input: input)
        let plan = try module.makePlan(input: input)
        let capabilities = plan.capabilitySet
        guard plan.moduleID == command.moduleID,
              plan.input == input,
              capabilities.isSubset(of: module.descriptor.capabilities),
              capabilities.isSubset(of: authority.allowedCapabilities)
        else { throw OmniCoreError.invalidProposal }
        if let operation = plan.ownerOperation {
            guard authority.allowedOwnerOperations.contains(operation),
                  operation.capability.map(capabilities.contains) ?? true
            else { throw OmniCoreError.invalidProposal }
        }
        return ValidatedProposalStep(
            moduleID: command.moduleID,
            input: input,
            capabilities: Array(capabilities),
            ownerOperation: plan.ownerOperation,
            offline: inheritedOffline
        )
    }

    private func validatedSubmission(for intent: ParsedIntent) throws -> ProposalSubmission {
        let reparsed = parser.parse(intent.rawText)
        guard intent.rawText == reparsed.rawText,
              intent.canonicalText == reparsed.canonicalText,
              intent.modifiers == reparsed.modifiers,
              intent.modes == reparsed.modes,
              intent.markers == reparsed.markers,
              resolvedBindings(intent.references) == resolvedBindings(reparsed.references)
        else { throw OmniCoreError.invalidProposal }
        return ProposalSubmission(intent: intent)
    }

    private func validatedSubmission(from envelope: ProposalEnvelope) throws -> ProposalSubmission {
        let parsed = parser.parse(envelope.rawText)
        let submission = ProposalSubmission(intent: parsed)
        guard envelope.canonicalText == submission.canonicalText,
              envelope.modifiers == submission.modifiers,
              envelope.modes == submission.modes,
              envelope.markers == submission.markers,
              envelope.references == submission.references
        else { throw OmniCoreError.invalidProposal }
        return submission
    }

    private func moduleInput(from parsed: ParsedIntent, rawText: String) throws -> ModuleInput {
        guard case .tier1 = SubmissionClassifier().classify(parsed) else { throw OmniCoreError.invalidProposal }
        let references = resolvedBindings(parsed.references)
        return ModuleInput(
            canonicalText: parsed.canonicalText,
            rawText: rawText,
            payloadText: ProposalCoding.payloadText(from: parsed, manifest: parser.manifest),
            modes: Set(parsed.modes),
            references: references,
            modifiers: Set(parsed.modifiers),
            markers: parsed.markers,
            tokenValues: parsed.tokenValues
        )
    }

    private func validateAlternativeIdentity(_ id: String, title: String) throws {
        guard !id.isEmpty, id.utf8.count <= 64, id.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 160
        else { throw OmniCoreError.invalidProposal }
    }

    private func resolvedBindings(_ values: [ReferenceResolution]) -> [PinnedReference] {
        values.compactMap {
            guard case let .binding(value) = $0 else { return nil }
            return value
        }
            .sorted { ProposalHashing.referenceKey($0) < ProposalHashing.referenceKey($1) }
    }

    private func references(_ values: [PinnedReference], areSubsetOf allowed: [PinnedReference]) -> Bool {
        values.allSatisfy { allowed.contains($0) }
    }
}

private struct ProposalSubmission: Sendable, Equatable {
    let rawText: String
    let canonicalText: String
    let modifiers: Set<String>
    let modes: Set<String>
    let markers: [String]
    let references: [PinnedReference]

    init(intent: ParsedIntent) {
        rawText = intent.rawText
        canonicalText = intent.canonicalText
        modifiers = Set(intent.modifiers)
        modes = Set(intent.modes)
        markers = intent.markers
        references = intent.references.compactMap {
            guard case let .binding(value) = $0 else { return nil }
            return value
        }
            .sorted { ProposalHashing.referenceKey($0) < ProposalHashing.referenceKey($1) }
    }
}

private struct ModelProposalDraft: Decodable {
    let alternatives: [ModelProposalAlternative]

    private enum CodingKeys: String, CodingKey, CaseIterable { case alternatives }

    init(from decoder: any Decoder) throws {
        try ProposalCoding.requireOnlyKnownKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        alternatives = try values.decode([ModelProposalAlternative].self, forKey: .alternatives)
    }
}

/// `ModuleInput` is shared with Tier 1 and therefore keeps ordinary Codable
/// behavior. Proposal persistence is a hostile boundary, so it uses this strict
/// mirror to reject unknown nested keys too.
private struct ProposalModuleInput: Decodable {
    let value: ModuleInput

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case rawText, canonicalText, payloadText, modes, references, modifiers, markers, tokenValues, modelSelection
    }

    init(from decoder: any Decoder) throws {
        try ProposalCoding.requireOnlyKnownKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = ModuleInput(
            canonicalText: try values.decode(String.self, forKey: .canonicalText),
            rawText: try values.decode(String.self, forKey: .rawText),
            payloadText: try values.decode(String.self, forKey: .payloadText),
            modes: try values.decode(Set<String>.self, forKey: .modes),
            references: try values.decode([ProposalPinnedReference].self, forKey: .references).map(\.value),
            modifiers: try values.decode(Set<String>.self, forKey: .modifiers),
            markers: try values.decode([String].self, forKey: .markers),
            tokenValues: try values.decodeIfPresent([String: ProposalTokenValue].self, forKey: .tokenValues)?.mapValues(\.value) ?? [:],
            modelSelection: try values.decodeIfPresent(ModelInvocationSelection.self, forKey: .modelSelection)
        )
    }
}

private struct ProposalTokenValue: Decodable {
    let value: TokenValue

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case type, value, unit, magnitude
    }

    init(from decoder: any Decoder) throws {
        try ProposalCoding.requireOnlyKnownKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .type) {
        case "enum":
            guard !values.contains(.unit), !values.contains(.magnitude) else { throw OmniCoreError.invalidProposal }
            value = .enumMember(try values.decode(String.self, forKey: .value))
        case "langcode":
            guard !values.contains(.unit), !values.contains(.magnitude) else { throw OmniCoreError.invalidProposal }
            value = .langcode(try values.decode(String.self, forKey: .value))
        case "int":
            guard !values.contains(.unit), !values.contains(.magnitude) else { throw OmniCoreError.invalidProposal }
            value = .int(try values.decode(Int.self, forKey: .value))
        case "length":
            guard !values.contains(.value) else { throw OmniCoreError.invalidProposal }
            value = .length(LengthValue(
                magnitude: try values.decode(Decimal.self, forKey: .magnitude),
                unit: try values.decode(LengthUnit.self, forKey: .unit)
            ))
        default:
            throw OmniCoreError.invalidProposal
        }
    }
}

private struct ProposalPinnedReference: Decodable {
    let value: PinnedReference

    private enum CodingKeys: String, CodingKey, CaseIterable { case id, namespace, key, snapshot }

    init(from decoder: any Decoder) throws {
        try ProposalCoding.requireOnlyKnownKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = PinnedReference(
            id: try values.decode(String.self, forKey: .id),
            namespace: try values.decode(String.self, forKey: .namespace),
            key: try values.decode(String.self, forKey: .key),
            snapshot: try ProposalReferenceSnapshot(from: values.superDecoder(forKey: .snapshot)).value
        )
    }
}

private struct ProposalReferenceSnapshot: Decodable {
    let value: ReferenceSnapshot

    private enum CodingKeys: String, CodingKey, CaseIterable { case sourceVersion, resolvedAt }

    init(from decoder: any Decoder) throws {
        try ProposalCoding.requireOnlyKnownKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = ReferenceSnapshot(
            sourceVersion: try values.decode(String.self, forKey: .sourceVersion),
            resolvedAt: try values.decode(Date.self, forKey: .resolvedAt)
        )
    }
}

private struct ModelProposalAlternative: Decodable {
    let id: String
    let title: String
    let commands: [String]

    private enum CodingKeys: String, CodingKey, CaseIterable { case id, title, commands }

    init(from decoder: any Decoder) throws {
        try ProposalCoding.requireOnlyKnownKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        commands = try values.decode([String].self, forKey: .commands)
    }
}

private enum ProposalCoding {
    static func requireOnlyKnownKeys(_ decoder: any Decoder, allowed: [String]) throws {
        let values = try decoder.container(keyedBy: DynamicCodingKey.self)
        let known = Set(allowed)
        guard values.allKeys.allSatisfy({ known.contains($0.stringValue) }) else {
            throw OmniCoreError.invalidProposal
        }
    }

    static func payloadText(from intent: ParsedIntent, manifest: CommandManifest) -> String {
        SlashTokenSyntax.payloadText(from: intent.rawText)
    }

    static func containsForbiddenModelSyntax(_ command: String) -> Bool {
        for atom in command.split(whereSeparator: \.isWhitespace) {
            let value = String(atom)
            if value.hasPrefix("--") || value.hasPrefix("./") || value.hasPrefix("../") || value.hasPrefix("~/") ||
                value.contains("://") || value.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { stringValue = "\(intValue)"; self.intValue = intValue }
}

private enum ProposalHashing {
    private struct PlanPayload: Encodable {
        let schema: Int
        let rawText: String
        let canonicalText: String
        let modifiers: [String]
        let modes: [String]
        let markers: [String]
        let references: [ReferencePayload]
        let authorityDigest: String
        let runtimeVersion: String
        let createdAt: TimeInterval
        let expiresAt: TimeInterval
        let alternativeID: String
        let title: String
        let steps: [StepPayload]
    }

    private struct StepPayload: Encodable {
        let moduleID: String
        let rawText: String
        let canonicalText: String
        let payloadText: String
        let modifiers: [String]
        let modes: [String]
        let markers: [String]
        let references: [ReferencePayload]
        let tokenValues: [String: TokenValue]
        let capabilities: [String]
        let ownerOperation: String?
        let offline: Bool
    }

    private struct ReferencePayload: Encodable {
        let id: String
        let namespace: String
        let key: String
        let sourceVersion: String
        let resolvedAt: TimeInterval
    }

    static func planHash(
        submission: ProposalSubmission,
        authorityDigest: String,
        runtimeVersion: String,
        createdAt: Date,
        expiresAt: Date,
        alternativeID: String,
        title: String,
        steps: [ValidatedProposalStep]
    ) throws -> String {
        let payload = PlanPayload(
            schema: 1,
            rawText: submission.rawText,
            canonicalText: submission.canonicalText,
            modifiers: submission.modifiers.sorted(),
            modes: submission.modes.sorted(),
            markers: submission.markers,
            references: submission.references.map(referencePayload),
            authorityDigest: authorityDigest,
            runtimeVersion: runtimeVersion,
            createdAt: createdAt.timeIntervalSince1970,
            expiresAt: expiresAt.timeIntervalSince1970,
            alternativeID: alternativeID,
            title: title,
            steps: steps.map(stepPayload)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(payload)).map { String(format: "%02x", $0) }.joined()
    }

    static func referenceDigest(_ references: [PinnedReference]) -> String {
        hash(referencePayloads(references))
    }

    static func authorityDigest(
        allowedCapabilities: Set<Capability>,
        allowedOwnerOperations: Set<OwnerOperation>,
        referenceDigest: String,
        offline: Bool
    ) -> String {
        hash(AuthorityPayload(
            capabilities: allowedCapabilities.map(\.rawValue).sorted(),
            operations: allowedOwnerOperations.map(\.rawValue).sorted(),
            referenceDigest: referenceDigest,
            offline: offline
        ))
    }

    static func referenceKey(_ reference: PinnedReference) -> String {
        "\(reference.namespace):\(reference.key):\(reference.id):\(reference.snapshot.sourceVersion):\(reference.snapshot.resolvedAt.timeIntervalSince1970)"
    }

    private struct AuthorityPayload: Encodable {
        let capabilities: [String]
        let operations: [String]
        let referenceDigest: String
        let offline: Bool
    }

    private static func referencePayloads(_ references: [PinnedReference]) -> [ReferencePayload] {
        references.sorted { referenceKey($0) < referenceKey($1) }.map(referencePayload)
    }

    private static func referencePayload(_ reference: PinnedReference) -> ReferencePayload {
        ReferencePayload(
            id: reference.id,
            namespace: reference.namespace,
            key: reference.key,
            sourceVersion: reference.snapshot.sourceVersion,
            resolvedAt: reference.snapshot.resolvedAt.timeIntervalSince1970
        )
    }

    private static func stepPayload(_ step: ValidatedProposalStep) -> StepPayload {
        StepPayload(
            moduleID: step.moduleID,
            rawText: step.input.rawText,
            canonicalText: step.input.canonicalText,
            payloadText: step.input.payloadText,
            modifiers: step.input.modifiers.sorted(),
            modes: step.input.modes.sorted(),
            markers: step.input.markers,
            references: step.input.references.map(referencePayload),
            tokenValues: step.input.tokenValues,
            capabilities: step.capabilities.map(\.rawValue).sorted(),
            ownerOperation: step.ownerOperation?.rawValue,
            offline: step.offline
        )
    }

    private static func hash<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try! encoder.encode(value)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
