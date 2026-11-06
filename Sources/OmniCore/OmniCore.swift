import Foundation

// MARK: - Syntax and visible-text contract

public enum TokenRole: String, Codable, Sendable, CaseIterable {
    case primary
    case modifier
    case alias
    case mode
    case settings
}

public enum ExecutionPath: String, Codable, Sendable {
    case deterministicLocal = "deterministic-local"
    case modelBacked = "model-backed"
    case settings
    case policy
}

public struct ManifestCommand: Codable, Sendable, Equatable {
    public let token: String
    public let role: TokenRole
    public let canonical: String?
    public let moduleID: String
    public let execution: ExecutionPath
    public let capabilities: [Capability]
    public let acceptedModifiers: [String]
    public let acceptedModes: [String]
    public let intentMarkers: [String]
    public let moduleVersion: Int
    public let value: TokenValueSpec?
    /// Guides composition binds to this command's prompt (amendment 1.4.0,
    /// D4): `identity` on every model-backed language command. Opting a
    /// command out of a guide is removing it here.
    public let boundGuides: [String]?

    enum CodingKeys: String, CodingKey {
        case token, role, canonical, moduleID = "module", execution, capabilities
        case acceptedModifiers = "accepted_modifiers"
        case acceptedModes = "accepted_modes"
        case intentMarkers = "intent_markers"
        case moduleVersion = "module_version"
        case value
        case boundGuides = "bound_guides"
    }

    public static let identityGuideBinding = "identity"
    public var bindsIdentityGuide: Bool { boundGuides?.contains(Self.identityGuideBinding) == true }

    public init(
        token: String,
        role: TokenRole,
        canonical: String? = nil,
        moduleID: String,
        execution: ExecutionPath,
        capabilities: [Capability],
        acceptedModifiers: [String] = [],
        acceptedModes: [String] = [],
        intentMarkers: [String] = [],
        moduleVersion: Int = 1,
        value: TokenValueSpec? = nil,
        boundGuides: [String]? = nil
    ) {
        self.token = token
        self.role = role
        self.canonical = canonical
        self.moduleID = moduleID
        self.execution = execution
        self.capabilities = capabilities
        self.acceptedModifiers = acceptedModifiers
        self.acceptedModes = acceptedModes
        self.intentMarkers = intentMarkers
        self.moduleVersion = moduleVersion
        self.value = value
        self.boundGuides = boundGuides
    }
}

public struct ManifestDocument: Codable, Sendable {
    public let schemaVersion: Int
    public let fixtureVersion: String?
    public let valueTypes: ManifestValueTypes?
    public let commands: [ManifestCommand]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case fixtureVersion = "fixture_version"
        case valueTypes = "value_types"
        case commands
    }

    public init(
        schemaVersion: Int,
        commands: [ManifestCommand],
        fixtureVersion: String? = nil,
        valueTypes: ManifestValueTypes? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.fixtureVersion = fixtureVersion
        self.valueTypes = valueTypes
        self.commands = commands
    }
}

public enum OmniCoreError: Error, Equatable, Sendable {
    case unsupportedManifestVersion(Int)
    case duplicateToken(String)
    case duplicateModuleID(String)
    case manifestRegistryMismatch(expected: Set<String>, actual: Set<String>)
    case duplicateReference(namespace: String, key: String)
    case unknownModule(String)
    case invalidProposal
    case confirmationMismatch
    case undeclaredCapability(Capability)
    case missingOwnerOperation(OwnerOperation)
    case ownerOperationPolicyDenied(OwnerOperation)
    case ownerOperationProfileMismatch(OwnerOperation)
    case offlineRouteDenied(OwnerOperation)
    case invalidFixtureRoot
    case missingContractFixture(String)
    case invalidContractFixture(String)
}

public struct CommandManifest: Sendable {
    private let values: [String: ManifestCommand]
    public let valueTypes: ManifestValueTypes
    public let fixtureVersion: String?

    public init(document: ManifestDocument) throws {
        guard document.schemaVersion == 1 else {
            throw OmniCoreError.unsupportedManifestVersion(document.schemaVersion)
        }
        var map: [String: ManifestCommand] = [:]
        for command in document.commands {
            guard map[command.token] == nil else { throw OmniCoreError.duplicateToken(command.token) }
            map[command.token] = command
        }
        values = map
        valueTypes = document.valueTypes ?? .empty
        fixtureVersion = document.fixtureVersion
    }

    public init(data: Data) throws {
        try self.init(document: JSONDecoder().decode(ManifestDocument.self, from: data))
    }

    public func command(for token: String) -> ManifestCommand? { values[token] }
    public func command(matchingAtom atom: String) -> ManifestCommand? {
        guard let slash = SlashAtom.parse(atom) else { return values[atom] }
        return values[slash.token]
    }
    public var commands: [ManifestCommand] { values.values.sorted { $0.token < $1.token } }
    public var moduleIDs: Set<String> { Set(values.values.lazy.map(\.moduleID).filter { !$0.isEmpty }) }
    public var primaryTokens: [String] {
        values.values.filter { $0.role == .primary }.map(\.token).sorted()
    }
}

/// Public access to the checked-in, verifier-backed Phase 1 corpus. Consumers
/// load package resources only; no production target needs a developer-machine
/// Phase 1 path at runtime.
public struct FrozenContractCorpus: Sendable {
    public static let fixtureNames: Set<String> = [
        "authority-policy", "contract-corpus-schema", "foreground-transitions",
        "freeze-index", "grammar-cases", "lifecycle-events", "manifest",
        "module-declarations", "reference-rules", "storage-semantics", "tier2-proposals"
    ]

    public init() {}

    public func fixtureURL(named name: String) throws -> URL {
        guard Self.fixtureNames.contains(name) else { throw OmniCoreError.missingContractFixture(name) }
        if let nested = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "ContractFixtures") {
            return nested
        }
        if let flattened = Bundle.module.url(forResource: name, withExtension: "json") {
            return flattened
        }
        throw OmniCoreError.missingContractFixture(name)
    }

    public func data(named name: String) throws -> Data {
        try Data(contentsOf: fixtureURL(named: name))
    }

    public func manifest() throws -> CommandManifest {
        try CommandManifest(data: data(named: "manifest"))
    }

    public func moduleDeclarations() throws -> ModuleDeclarationDocument {
        try JSONDecoder().decode(ModuleDeclarationDocument.self, from: data(named: "module-declarations"))
    }
}

public struct VisibleRewrite: Sendable, Equatable {
    public let from: String
    public let to: String
    public let undoable: Bool

    public init(from: String, to: String, undoable: Bool = true) {
        self.from = from
        self.to = to
        self.undoable = undoable
    }
}

public enum ParseDiagnostic: Sendable, Equatable {
    case unknownSlash(String)
    case unsupportedModifier(String)
    case unsupportedMode(String)
    case unsupportedMarker(String)
    case multipleDispatch
    case contradictoryMarkers
    case duplicateMarkers
    case missingRequiredValue(String)
    case invalidValue(String, String)
    case unexpectedValue(String, String)

    public var statusLabel: String {
        switch self {
        case .unknownSlash(let token): "unknown \(token)"
        case .unsupportedModifier(let token): "unsupported modifier \(token)"
        case .unsupportedMode(let token): "unsupported mode \(token)"
        case .unsupportedMarker(let token): "unsupported marker \(token)"
        case .multipleDispatch: "multiple commands"
        case .contradictoryMarkers: "contradictory markers"
        case .duplicateMarkers: "duplicate markers"
        case .missingRequiredValue(let token): "missing value \(token)"
        case .invalidValue(let token, _): "invalid value \(token)"
        case .unexpectedValue(let token, _): "unexpected value \(token)"
        }
    }
}

public struct ReferenceSnapshot: Codable, Sendable, Equatable {
    public let sourceVersion: String
    public let resolvedAt: Date

    public init(sourceVersion: String, resolvedAt: Date) {
        self.sourceVersion = sourceVersion
        self.resolvedAt = resolvedAt
    }
}

public struct PinnedReference: Codable, Sendable, Equatable {
    public let id: String
    public let namespace: String
    public let key: String
    public let snapshot: ReferenceSnapshot

    public init(id: String, namespace: String, key: String, snapshot: ReferenceSnapshot) {
        self.id = id
        self.namespace = namespace
        self.key = key
        self.snapshot = snapshot
    }
}

public enum ReferenceResolution: Sendable, Equatable {
    case binding(PinnedReference)
    case ambiguous(key: String)
    case plainText(String)
}

public struct ReferenceRegistry: Sendable {
    private let values: [String: PinnedReference]

    public init(_ references: [PinnedReference]) throws {
        var map: [String: PinnedReference] = [:]
        for reference in references {
            let composite = "\(reference.namespace):\(reference.key)"
            guard map[composite] == nil else {
                throw OmniCoreError.duplicateReference(namespace: reference.namespace, key: reference.key)
            }
            map[composite] = reference
        }
        values = map
    }

    public func qualified(namespace: String, key: String) -> PinnedReference? {
        values["\(namespace):\(key)"]
    }

    public func unique(key: String) -> PinnedReference? {
        let matches = values.values.filter { $0.key == key }
        return matches.count == 1 ? matches[0] : nil
    }

    public func isAmbiguous(key: String) -> Bool {
        values.values.lazy.filter { $0.key == key }.count > 1
    }

    public var all: [PinnedReference] {
        values.values.sorted { "\($0.namespace):\($0.key)" < "\($1.namespace):\($1.key)" }
    }
}

public struct ParsedIntent: Sendable, Equatable {
    public let rawText: String
    public let canonicalText: String
    public let primaryTokens: [String]
    public let settingsTokens: [String]
    public let modifiers: [String]
    public let modes: [String]
    public let references: [ReferenceResolution]
    public let diagnostics: [ParseDiagnostic]
    public let markers: [String]
    public let visibleRewrites: [VisibleRewrite]
    public let tokenValues: [String: TokenValue]
    public let isEmpty: Bool

    public var dispatchToken: String? {
        guard primaryTokens.count + settingsTokens.count == 1 else { return nil }
        return primaryTokens.first ?? settingsTokens.first
    }
}

public struct OmniParser: Sendable {
    public let manifest: CommandManifest
    public let references: ReferenceRegistry

    public init(manifest: CommandManifest, references: ReferenceRegistry) {
        self.manifest = manifest
        self.references = references
    }

    public func parse(_ text: String) -> ParsedIntent {
        let rawAtoms = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var rewrites: [VisibleRewrite] = []
        var atoms = rawAtoms.map { atom -> String in
            guard let command = manifest.command(for: atom),
                  command.role == .alias,
                  let canonical = command.canonical
            else { return atom }
            rewrites.append(VisibleRewrite(from: atom, to: canonical))
            return canonical
        }
        atoms = atoms.map { atom -> String in
            guard let reference = Self.parseReference(atom),
                  reference.namespace == nil,
                  let binding = references.unique(key: reference.key)
            else { return atom }
            let canonical = "@\(binding.namespace):\(binding.key)"
            rewrites.append(VisibleRewrite(from: atom, to: canonical))
            return canonical
        }

        var primaries: [String] = []
        var settings: [String] = []
        var modifiers: [String] = []
        var modes: [String] = []
        var resolved: [ReferenceResolution] = []
        var diagnostics: [ParseDiagnostic] = []
        var markers: [String] = []
        var tokenValues: [String: TokenValue] = [:]
        var canonicalAtoms: [String] = []

        for atom in atoms {
            if atom == "✓" || atom == "✗" {
                markers.append(atom)
                canonicalAtoms.append(atom)
                continue
            }
            if let slash = SlashAtom.parse(atom) {
                let classified = classifySlash(slash, literal: atom)
                rewrites.append(contentsOf: classified.rewrites)
                diagnostics.append(contentsOf: classified.diagnostics)
                if let value = classified.value {
                    tokenValues[slash.token] = value
                }
                if classified.countsTowardRole {
                    switch classified.role {
                    case .primary: primaries.append(classified.commandToken)
                    case .settings: settings.append(classified.commandToken)
                    case .modifier: modifiers.append(classified.canonicalAtom)
                    case .mode: modes.append(classified.canonicalAtom)
                    case .alias: break
                    }
                }
                canonicalAtoms.append(classified.canonicalAtom)
            } else if let reference = Self.parseReference(atom) {
                canonicalAtoms.append(atom)
                if let namespace = reference.namespace {
                    resolved.append(references.qualified(namespace: namespace, key: reference.key).map(ReferenceResolution.binding) ?? .plainText(atom))
                } else if references.isAmbiguous(key: reference.key) {
                    resolved.append(.ambiguous(key: reference.key))
                } else if let binding = references.unique(key: reference.key) {
                    resolved.append(.binding(binding))
                } else {
                    resolved.append(.plainText(atom))
                }
            } else {
                canonicalAtoms.append(atom)
            }
        }

        if primaries.count + settings.count > 1 { diagnostics.append(.multipleDispatch) }
        if let dispatch = (primaries + settings).first, let descriptor = manifest.command(for: dispatch) {
            for modifier in modifiers where !descriptor.acceptedModifiers.contains(modifier) {
                diagnostics.append(.unsupportedModifier(modifier))
            }
            for mode in modes where !descriptor.acceptedModes.contains(mode) {
                diagnostics.append(.unsupportedMode(mode))
            }
            for marker in markers where !descriptor.intentMarkers.contains(marker) {
                diagnostics.append(.unsupportedMarker(marker))
            }
        }
        if Set(markers).count > 1 { diagnostics.append(.contradictoryMarkers) }
        if markers.count > 1 && Set(markers).count == 1 { diagnostics.append(.duplicateMarkers) }

        return ParsedIntent(
            rawText: text,
            canonicalText: canonicalAtoms.joined(separator: " "),
            primaryTokens: primaries,
            settingsTokens: settings,
            modifiers: modifiers,
            modes: modes,
            references: resolved,
            diagnostics: diagnostics,
            markers: markers,
            visibleRewrites: rewrites,
            tokenValues: tokenValues,
            isEmpty: canonicalAtoms.isEmpty
        )
    }

    private struct ClassifiedSlash {
        let commandToken: String
        let canonicalAtom: String
        let role: TokenRole
        let countsTowardRole: Bool
        let value: TokenValue?
        let rewrites: [VisibleRewrite]
        let diagnostics: [ParseDiagnostic]
    }

    private func classifySlash(_ slash: SlashAtom, literal: String) -> ClassifiedSlash {
        guard let command = manifest.command(for: slash.token) else {
            return ClassifiedSlash(
                commandToken: slash.token,
                canonicalAtom: literal,
                role: .primary,
                countsTowardRole: false,
                value: nil,
                rewrites: [],
                diagnostics: [.unknownSlash(literal)]
            )
        }
        if let spec = command.value {
            switch TokenValueNormalizer.validate(raw: slash.value, spec: spec, types: manifest.valueTypes) {
            case .omitted:
                if spec.required {
                    return ClassifiedSlash(
                        commandToken: command.token,
                        canonicalAtom: literal,
                        role: command.role,
                        countsTowardRole: false,
                        value: nil,
                        rewrites: [],
                        diagnostics: [.missingRequiredValue(slash.token), .unknownSlash(literal)]
                    )
                }
                return ClassifiedSlash(
                    commandToken: command.token,
                    canonicalAtom: slash.token,
                    role: command.role,
                    countsTowardRole: true,
                    value: nil,
                    rewrites: [],
                    diagnostics: []
                )
            case .accepted(let value):
                let canonical = "\(slash.token):\(value.canonical)"
                let rewrite: [VisibleRewrite] = literal == canonical ? [] : [VisibleRewrite(from: literal, to: canonical)]
                return ClassifiedSlash(
                    commandToken: command.token,
                    canonicalAtom: canonical,
                    role: command.role,
                    countsTowardRole: true,
                    value: value,
                    rewrites: rewrite,
                    diagnostics: []
                )
            case .invalid:
                return ClassifiedSlash(
                    commandToken: command.token,
                    canonicalAtom: literal,
                    role: command.role,
                    countsTowardRole: false,
                    value: nil,
                    rewrites: [],
                    diagnostics: [.invalidValue(literal, slash.value ?? ""), .unknownSlash(literal)]
                )
            }
        }
        if let value = slash.value {
            return ClassifiedSlash(
                commandToken: command.token,
                canonicalAtom: literal,
                role: command.role,
                countsTowardRole: false,
                value: nil,
                rewrites: [],
                diagnostics: [.unexpectedValue(slash.token, value), .unknownSlash(literal)]
            )
        }
        return ClassifiedSlash(
            commandToken: command.token,
            canonicalAtom: slash.token,
            role: command.role,
            countsTowardRole: true,
            value: nil,
            rewrites: [],
            diagnostics: []
        )
    }

    public func selectAmbiguousReference(key: String, namespace: String) -> VisibleRewrite? {
        guard let reference = references.qualified(namespace: namespace, key: key) else { return nil }
        return VisibleRewrite(from: "@\(key)", to: "@\(reference.namespace):\(reference.key)")
    }

    public static func isSlashAtom(_ value: String) -> Bool {
        SlashAtom.parse(value) != nil
    }

    private static func parseReference(_ value: String) -> (namespace: String?, key: String)? {
        guard value.count > 1, value.first == "@" else { return nil }
        let parts = value.dropFirst().split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let keyPart = parts.last else { return nil }
        let namespace = parts.count == 2 ? String(parts[0]) : nil
        let key = String(keyPart)
        guard isLowerAtom(key, firstMayBeNumber: true),
              namespace.map({ isLowerAtom($0, firstMayBeNumber: false) }) ?? true
        else { return nil }
        return (namespace, key)
    }

    private static func isLowerAtom(_ value: String, firstMayBeNumber: Bool) -> Bool {
        guard let first = value.first,
              (first.isLetter && first.isLowercase) || (firstMayBeNumber && first.isNumber)
        else { return false }
        return value.allSatisfy { ($0.isLetter && $0.isLowercase) || $0.isNumber || $0 == "-" }
    }
}

public enum SubmissionTier: Sendable, Equatable {
    case tier1(dispatchToken: String)
    case tier2
    case disabled
    case referenceChoice
}

public struct SubmissionClassifier: Sendable {
    public init() {}

    public func classify(_ intent: ParsedIntent) -> SubmissionTier {
        if intent.isEmpty { return .disabled }
        if intent.references.contains(where: { if case .ambiguous = $0 { return true }; return false }) {
            return .referenceChoice
        }
        guard intent.diagnostics.isEmpty, let dispatch = intent.dispatchToken else { return .tier2 }
        return .tier1(dispatchToken: dispatch)
    }
}

// MARK: - Typed modules, policies, routing, and authority

public enum Capability: String, Codable, Sendable, CaseIterable, Hashable {
    case draftCommunication = "draft-communication"
    case openURL = "open-url"
    case captureLink = "capture-link"
    case appendLedger = "append-ledger"
    case appendOfficeQueue = "append-office-queue"
    case writeCurrentStash = "write-current-stash"
    case captureBaseNote = "capture-base-note"
    case readIndex = "read-index"
    case openTarget = "open-target"
    case revealTarget = "reveal-target"
    case writeSettings = "write-settings"
}

public struct NarrowCapabilityHandle: Sendable, Equatable {
    public let capability: Capability
    fileprivate init(capability: Capability) { self.capability = capability }
}

public struct CapabilityBroker: Sendable {
    public let declared: Set<Capability>
    public let profile: OmniExecutionProfile
    public let offline: Bool
    private let environment: CapabilityEnvironment?

    public init(declared: some Sequence<Capability>) {
        self.declared = Set(declared)
        profile = .pureFake
        offline = false
        environment = nil
    }

    public init(declared: some Sequence<Capability>, environment: CapabilityEnvironment, offline: Bool) {
        self.declared = Set(declared)
        profile = environment.profile
        self.offline = offline
        self.environment = environment
    }

    public func handle(for capability: Capability) throws -> NarrowCapabilityHandle {
        guard declared.contains(capability) else { throw OmniCoreError.undeclaredCapability(capability) }
        return NarrowCapabilityHandle(capability: capability)
    }

    public func handles() -> [NarrowCapabilityHandle] {
        declared.sorted { $0.rawValue < $1.rawValue }.map { NarrowCapabilityHandle(capability: $0) }
    }

    public func operationHandle(for operation: OwnerOperation) throws -> OwnerOperationHandle {
        if let capability = operation.capability, !declared.contains(capability) {
            throw OmniCoreError.undeclaredCapability(capability)
        }
        guard let environment else { throw OmniCoreError.missingOwnerOperation(operation) }
        guard environment.installedPolicy.contains(operation) else {
            throw OmniCoreError.ownerOperationPolicyDenied(operation)
        }
        guard let handle = environment.handle(for: operation) else {
            throw OmniCoreError.missingOwnerOperation(operation)
        }
        guard handle.profile == profile else {
            throw OmniCoreError.ownerOperationProfileMismatch(operation)
        }
        if offline && operation.mayUseNetwork {
            throw OmniCoreError.offlineRouteDenied(operation)
        }
        return handle
    }
}

public struct PolicyReference: Codable, Sendable, Equatable {
    public let profile: String
    public init(profile: String) { self.profile = profile }
}

public struct InputPolicy: Sendable, Equatable { public let profile: String; public init(profile: String) { self.profile = profile } }
public struct AuthorityPolicy: Sendable, Equatable { public let profile: String; public init(profile: String) { self.profile = profile } }
public struct ModelPolicy: Sendable, Equatable { public let profile: String; public init(profile: String) { self.profile = profile } }
public struct ReferencePolicy: Sendable, Equatable { public let profile: String; public init(profile: String) { self.profile = profile } }
public struct ResultPolicy: Sendable, Equatable { public let profile: String; public init(profile: String) { self.profile = profile } }
public struct RetryPolicy: Sendable, Equatable { public let profile: String; public init(profile: String) { self.profile = profile } }
public struct TimeoutPolicy: Sendable, Equatable { public let profile: String; public init(profile: String) { self.profile = profile } }

public struct TokenDeclaration: Codable, Sendable, Equatable {
    public let canonical: String
    public let role: TokenRole
    public let aliases: [String]
}

public struct ExecutionDeclaration: Codable, Sendable, Equatable {
    public let kind: ExecutionPath
}

public struct ModuleDeclaration: Codable, Sendable, Equatable {
    public let commandID: String
    public let moduleID: String
    public let moduleVersion: Int
    public let tokens: TokenDeclaration
    public let acceptedModifiers: [String]
    public let acceptedModes: [String]
    public let intentMarkers: [String]
    public let inputContract: PolicyReference
    public let executionPath: ExecutionDeclaration
    public let authorityPolicy: PolicyReference
    public let modelPolicy: PolicyReference
    public let referencePolicy: PolicyReference
    public let resultPolicy: PolicyReference
    public let retryPolicy: PolicyReference
    public let timeoutPolicy: PolicyReference

    enum CodingKeys: String, CodingKey {
        case commandID = "command_id", moduleID = "module_id", moduleVersion = "module_version", tokens
        case acceptedModifiers = "accepted_modifiers", acceptedModes = "accepted_modes", intentMarkers = "intent_markers"
        case inputContract = "input_contract", executionPath = "execution_path", authorityPolicy = "authority_policy"
        case modelPolicy = "model_policy", referencePolicy = "reference_policy", resultPolicy = "result_policy"
        case retryPolicy = "retry_policy", timeoutPolicy = "timeout_policy"
    }

    public var typedPolicies: ModulePolicies {
        ModulePolicies(
            input: InputPolicy(profile: inputContract.profile),
            authority: AuthorityPolicy(profile: authorityPolicy.profile),
            model: ModelPolicy(profile: modelPolicy.profile),
            references: ReferencePolicy(profile: referencePolicy.profile),
            result: ResultPolicy(profile: resultPolicy.profile),
            retry: RetryPolicy(profile: retryPolicy.profile),
            timeout: TimeoutPolicy(profile: timeoutPolicy.profile)
        )
    }
}

public struct ModuleDeclarationDocument: Codable, Sendable {
    public let schemaVersion: Int
    public let fixtureVersion: String
    public let declarations: [ModuleDeclaration]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", fixtureVersion = "fixture_version", declarations
    }
}

public struct ModuleInput: Codable, Sendable, Equatable {
    public let rawText: String
    public let canonicalText: String
    public let payloadText: String
    public let modes: Set<String>
    public let references: [PinnedReference]
    public let modifiers: Set<String>
    public let markers: [String]
    public let tokenValues: [String: TokenValue]
    /// The user's deliberate one-invocation model selection, recorded with the
    /// invocation. It is routing data only: it grants no capability, owner
    /// authority or effect, and follow-ups never inherit it.
    public let modelSelection: ModelInvocationSelection?

    enum CodingKeys: String, CodingKey {
        case rawText, canonicalText, payloadText, modes, references, modifiers, markers, tokenValues, modelSelection
    }

    public init(
        canonicalText: String,
        rawText: String? = nil,
        payloadText: String? = nil,
        modes: Set<String> = [],
        references: [PinnedReference] = [],
        modifiers: Set<String> = [],
        markers: [String] = [],
        tokenValues: [String: TokenValue] = [:],
        modelSelection: ModelInvocationSelection? = nil
    ) {
        self.rawText = rawText ?? canonicalText
        self.canonicalText = canonicalText
        self.payloadText = payloadText ?? canonicalText
        self.modes = modes
        self.references = references
        self.modifiers = modifiers
        self.markers = markers
        self.tokenValues = tokenValues
        self.modelSelection = modelSelection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawText = try container.decode(String.self, forKey: .rawText)
        canonicalText = try container.decode(String.self, forKey: .canonicalText)
        payloadText = try container.decode(String.self, forKey: .payloadText)
        modes = try container.decode(Set<String>.self, forKey: .modes)
        references = try container.decode([PinnedReference].self, forKey: .references)
        modifiers = try container.decode(Set<String>.self, forKey: .modifiers)
        markers = try container.decode([String].self, forKey: .markers)
        tokenValues = try container.decodeIfPresent([String: TokenValue].self, forKey: .tokenValues) ?? [:]
        modelSelection = try container.decodeIfPresent(ModelInvocationSelection.self, forKey: .modelSelection)
    }

    public func with(modelSelection: ModelInvocationSelection?) -> ModuleInput {
        ModuleInput(
            canonicalText: canonicalText,
            rawText: rawText,
            payloadText: payloadText,
            modes: modes,
            references: references,
            modifiers: modifiers,
            markers: markers,
            tokenValues: tokenValues,
            modelSelection: modelSelection
        )
    }
}

public struct ModuleResult: Sendable, Equatable {
    public let summary: String
    public let artifactReference: String?
    public let allowedActions: [ResultAction]
    public let fullText: String?
    public let modelRecord: ModelExecutionRecord?
    /// A `/find` picker result (D2): the query and the rows it found.
    public let find: OmniFindResult?
    public init(summary: String, artifactReference: String? = nil, allowedActions: [ResultAction] = [], fullText: String? = nil, modelRecord: ModelExecutionRecord? = nil, find: OmniFindResult? = nil) {
        self.summary = summary
        self.artifactReference = artifactReference
        self.allowedActions = allowedActions
        self.fullText = fullText
        self.modelRecord = modelRecord
        self.find = find
    }
}

public struct ModulePolicies: Sendable, Equatable {
    public let input: InputPolicy
    public let authority: AuthorityPolicy
    public let model: ModelPolicy
    public let references: ReferencePolicy
    public let result: ResultPolicy
    public let retry: RetryPolicy
    public let timeout: TimeoutPolicy

    public init(
        input: InputPolicy,
        authority: AuthorityPolicy,
        model: ModelPolicy,
        references: ReferencePolicy,
        result: ResultPolicy,
        retry: RetryPolicy,
        timeout: TimeoutPolicy
    ) {
        self.input = input
        self.authority = authority
        self.model = model
        self.references = references
        self.result = result
        self.retry = retry
        self.timeout = timeout
    }
}

public struct ModuleDescriptor: Sendable, Equatable {
    public let moduleID: String
    public let moduleVersion: Int
    public let execution: ExecutionPath
    public let capabilities: Set<Capability>
    public let policies: ModulePolicies

    public init(moduleID: String, moduleVersion: Int, execution: ExecutionPath, capabilities: Set<Capability>, policies: ModulePolicies) {
        self.moduleID = moduleID
        self.moduleVersion = moduleVersion
        self.execution = execution
        self.capabilities = capabilities
        self.policies = policies
    }
}

public struct CommandPlan: Sendable, Equatable {
    public let moduleID: String
    public let input: ModuleInput
    public let capabilitySet: Set<Capability>
    public let ownerOperation: OwnerOperation?
    public let offline: Bool
    public let expectedEffectCount: Int
    /// Model-facing guidance attached to raw editor spans, kept outside ModuleInput.
    public let annotations: [OmniTextAnnotation]
    /// The capture's source app, kept outside ModuleInput: `/stance` reads it
    /// as a material-type hint; every other module ignores it.
    public let materialSource: String?

    public init(
        moduleID: String,
        input: ModuleInput,
        capabilitySet: Set<Capability>,
        ownerOperation: OwnerOperation? = nil,
        offline: Bool = false,
        expectedEffectCount: Int = 0,
        annotations: [OmniTextAnnotation] = [],
        materialSource: String? = nil
    ) {
        self.moduleID = moduleID
        self.input = input
        self.capabilitySet = capabilitySet
        self.ownerOperation = ownerOperation
        self.offline = offline
        self.expectedEffectCount = expectedEffectCount
        self.annotations = annotations
        self.materialSource = materialSource
    }

    public func with(annotations: [OmniTextAnnotation]) -> CommandPlan {
        CommandPlan(
            moduleID: moduleID,
            input: input,
            capabilitySet: capabilitySet,
            ownerOperation: ownerOperation,
            offline: offline,
            expectedEffectCount: expectedEffectCount,
            annotations: annotations,
            materialSource: materialSource
        )
    }

    public func with(materialSource: String?) -> CommandPlan {
        CommandPlan(
            moduleID: moduleID,
            input: input,
            capabilitySet: capabilitySet,
            ownerOperation: ownerOperation,
            offline: offline,
            expectedEffectCount: expectedEffectCount,
            annotations: annotations,
            materialSource: materialSource
        )
    }
}

public enum EffectCertainty: String, Codable, Sendable, Equatable {
    case certain
    case uncertain
}

public struct CancellationAcknowledgement: Sendable, Equatable {
    public let requestObserved: Bool
    public let taskOrProcessStopped: Bool
    public let ownerAcknowledged: Bool
    public let effectCertainty: EffectCertainty

    public init(
        requestObserved: Bool,
        taskOrProcessStopped: Bool,
        ownerAcknowledged: Bool,
        effectCertainty: EffectCertainty
    ) {
        self.requestObserved = requestObserved
        self.taskOrProcessStopped = taskOrProcessStopped
        self.ownerAcknowledged = ownerAcknowledged
        self.effectCertainty = effectCertainty
    }

    public var permitsTerminalCancellation: Bool {
        requestObserved && taskOrProcessStopped && ownerAcknowledged && effectCertainty == .certain
    }
}

public enum ModuleExecutionOutcome: Sendable, Equatable {
    case succeeded(ModuleResult)
    case failed(summary: String)
    case interrupted(effectCertainty: EffectCertainty)
}

/// Run-bound execution contract. RunEngine owns persistence and decides whether
/// an acknowledgement permits cancellation or instead requires interruption.
public protocol RunExecutionHandle: Sendable {
    var runID: String { get }
    func value() async -> ModuleExecutionOutcome
    func requestCancellation() async -> CancellationAcknowledgement
    func modelExecutionRecord() async -> ModelExecutionRecord?
}

public extension RunExecutionHandle {
    func modelExecutionRecord() async -> ModelExecutionRecord? { nil }
}

public enum ReconciliationDisposition: Sendable, Equatable {
    case completed(ModuleResult)
    case interrupted(effectCertainty: EffectCertainty)
    case unavailable
}

/// A module validates and deterministically plans before a RunEngine persists
/// submitted. Only the engine starts the run-bound handle after that event.
public protocol CommandModule: Sendable {
    var descriptor: ModuleDescriptor { get }
    func validate(input: ModuleInput) throws
    func makePlan(input: ModuleInput) throws -> CommandPlan
    func start(plan: CommandPlan, capabilities: CapabilityBroker, runID: String) async throws -> any RunExecutionHandle
    func reconcile(runID: String, plan: CommandPlan) async -> ReconciliationDisposition
}

public struct AnyCommandModuleFactory: Sendable {
    public let moduleID: String
    private let make: @Sendable () -> any CommandModule

    public init(moduleID: String, make: @escaping @Sendable () -> any CommandModule) {
        self.moduleID = moduleID
        self.make = make
    }

    public func build() -> any CommandModule { make() }
}

public struct ModuleRegistry: Sendable {
    private let factories: [String: AnyCommandModuleFactory]

    public init(_ values: [AnyCommandModuleFactory]) throws {
        var map: [String: AnyCommandModuleFactory] = [:]
        for value in values {
            guard map[value.moduleID] == nil else { throw OmniCoreError.duplicateModuleID(value.moduleID) }
            map[value.moduleID] = value
        }
        factories = map
    }

    public var moduleIDs: Set<String> { Set(factories.keys) }
    public func factory(for moduleID: String) -> AnyCommandModuleFactory? { factories[moduleID] }
}

public struct ManifestParityValidator: Sendable {
    public init() {}

    public func validate(manifest: CommandManifest, declarations: [ModuleDeclaration], registry: ModuleRegistry) throws {
        let declared = Set(declarations.map(\.moduleID))
        guard manifest.moduleIDs == declared else {
            throw OmniCoreError.manifestRegistryMismatch(expected: manifest.moduleIDs, actual: declared)
        }
        guard manifest.moduleIDs == registry.moduleIDs else {
            throw OmniCoreError.manifestRegistryMismatch(expected: manifest.moduleIDs, actual: registry.moduleIDs)
        }
        for declaration in declarations {
            guard let command = manifest.command(for: declaration.tokens.canonical),
                  command.moduleID == declaration.moduleID,
                  command.moduleVersion == declaration.moduleVersion,
                  command.role == declaration.tokens.role
            else { throw OmniCoreError.invalidProposal }
        }
    }
}

/// The only Tier 1 binding: manifest dispatch token -> module identifier -> registry.
/// It deliberately contains no command-token switch and no model dependency.
public struct Tier1Router: Sendable {
    public let manifest: CommandManifest
    public let registry: ModuleRegistry

    public init(manifest: CommandManifest, registry: ModuleRegistry) {
        self.manifest = manifest
        self.registry = registry
    }

    public func module(for dispatchToken: String) throws -> any CommandModule {
        guard let command = manifest.command(for: dispatchToken),
              command.role == .primary || command.role == .settings,
              !command.moduleID.isEmpty,
              let factory = registry.factory(for: command.moduleID)
        else { throw OmniCoreError.unknownModule(dispatchToken) }
        return factory.build()
    }
}

// MARK: - Tier 2 and AppKit-independent presentation contracts

public struct Tier2Proposal: Codable, Sendable, Equatable {
    public let moduleID: String
    public let capabilities: [Capability]
    public let input: String
    public let inputDigest: String
    public let planHash: String

    public init(moduleID: String, capabilities: [Capability], input: String) {
        self.moduleID = moduleID
        self.capabilities = capabilities.sorted { $0.rawValue < $1.rawValue }
        self.input = input
        inputDigest = StableDigest.hash(input)
        planHash = StableDigest.hash("\(moduleID)|\(self.capabilities.map(\.rawValue).joined(separator: ","))|\(inputDigest)")
    }
}

public protocol Tier2ProposalSource: Sendable {
    func propose(for intent: ParsedIntent) async throws -> Tier2Proposal
}

public struct Tier2PlanValidator: Sendable {
    public let allowedCapabilities: Set<Capability>
    public let registry: ModuleRegistry

    public init(registry: ModuleRegistry, allowedCapabilities: Set<Capability> = Set(Capability.allCases)) {
        self.registry = registry
        self.allowedCapabilities = allowedCapabilities
    }

    public func validate(_ proposal: Tier2Proposal) throws {
        guard let factory = registry.factory(for: proposal.moduleID) else {
            throw OmniCoreError.unknownModule(proposal.moduleID)
        }
        let module = factory.build()
        guard !proposal.moduleID.isEmpty,
              Set(proposal.capabilities).isSubset(of: allowedCapabilities),
              Set(proposal.capabilities).isSubset(of: module.descriptor.capabilities)
        else { throw OmniCoreError.invalidProposal }
        guard proposal.inputDigest == StableDigest.hash(proposal.input),
              proposal.planHash == StableDigest.hash("\(proposal.moduleID)|\(proposal.capabilities.map(\.rawValue).joined(separator: ","))|\(proposal.inputDigest)"),
              module.descriptor.moduleID == proposal.moduleID
        else { throw OmniCoreError.invalidProposal }
    }

    public func confirm(_ proposal: Tier2Proposal, exactPlanHash: String) throws {
        try validate(proposal)
        guard proposal.planHash == exactPlanHash else { throw OmniCoreError.confirmationMismatch }
    }
}

public enum ResultAction: String, Codable, Sendable, CaseIterable {
    case copy
    case confirm
    case open
    case reveal
    case retry
    case cancel
    case edit
    case dismiss
    case openComposer
    case expand
    case collapse
}

public enum RunPresentationState: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
    case interrupted
    case proposing
    case proposalReady
    case confirmed
}

public struct RunReceipt: Codable, Sendable, Equatable {
    public let runID: String
    public let canonicalText: String
    public let moduleID: String?
    public let state: RunPresentationState
    public let summary: String
    public let artifactReference: String?
    public let executionProfile: String?
    public let offline: Bool?
    public let effectDisposition: String?
    public let fullText: String?
    public let modelRecord: ModelExecutionRecord?
    public let alternatives: [ProposalAlternativeDisplay]?

    public init(
        runID: String,
        canonicalText: String,
        moduleID: String?,
        state: RunPresentationState,
        summary: String,
        artifactReference: String? = nil,
        executionProfile: String? = nil,
        offline: Bool? = nil,
        effectDisposition: String? = nil,
        fullText: String? = nil,
        modelRecord: ModelExecutionRecord? = nil,
        alternatives: [ProposalAlternativeDisplay]? = nil
    ) {
        self.runID = runID
        self.canonicalText = canonicalText
        self.moduleID = moduleID
        self.state = state
        self.summary = summary
        self.artifactReference = artifactReference
        self.executionProfile = executionProfile
        self.offline = offline
        self.effectDisposition = effectDisposition
        self.fullText = fullText
        self.modelRecord = modelRecord
        self.alternatives = alternatives
    }
}

public struct ProposalAlternativeDisplay: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let steps: [String]
    public let planHash: String

    public init(id: String, title: String, steps: [String], planHash: String) {
        self.id = id
        self.title = title
        self.steps = steps
        self.planHash = planHash
    }
}

public struct ResultViewModel: Sendable, Equatable {
    public let runID: String
    public let title: String
    public let detail: String
    public let state: RunPresentationState
    public let actions: [ResultAction]
    public let fullText: String?
    public let effectiveModelSummary: String?
    /// The run's model record, when a model tier ran; the header names its
    /// provider (D3). Nil for runs that recorded no model attempt.
    public let modelRecord: ModelExecutionRecord?
    public let alternatives: [ProposalAlternativeDisplay]
    /// The executing module, for shape lookups against the manifest.
    public let moduleID: String?
    /// The canonical request text, for derived titles.
    public let commandText: String
    /// Durable submission time; `nil` for synthetic placeholder models.
    public let submittedAt: Date?
    /// In-run follow-up generation state; `.pending` counts as run activity.
    public let followUpKind: OmniFollowUpStateKind?
    /// The follow-up's own message when it failed or was cancelled.
    public let followUpMessage: String?
    /// Number of immutable result versions the run currently holds.
    public let versionCount: Int
    /// Where the request text came from, when capture identified a source.
    public let provenance: OmniRunProvenance?
    /// Guidance attached to the submitted input, for read-only history display.
    public let annotations: [OmniTextAnnotation]
    /// Explains when an annotation could not be carried to this input.
    public let annotationNotice: String?
    /// The run this one was drafted from (a `/stance` pick), when any.
    public let originRunID: String?
    /// A `/find` run's query and rows (D2); the picker acts on these.
    public let find: OmniFindResult?

    public init(
        receipt: RunReceipt,
        actions: [ResultAction],
        commandTitle: String? = nil,
        submittedAt: Date? = nil,
        followUpKind: OmniFollowUpStateKind? = nil,
        followUpMessage: String? = nil,
        versionCount: Int = 0,
        provenance: OmniRunProvenance? = nil,
        annotations: [OmniTextAnnotation] = [],
        annotationNotice: String? = nil,
        originRunID: String? = nil,
        find: OmniFindResult? = nil
    ) {
        self.originRunID = originRunID
        self.find = find
        runID = receipt.runID
        moduleID = receipt.moduleID
        commandText = receipt.canonicalText
        self.submittedAt = submittedAt
        self.followUpKind = followUpKind
        self.followUpMessage = followUpMessage
        self.versionCount = versionCount
        self.provenance = provenance
        self.annotations = annotations
        self.annotationNotice = annotationNotice
        title = commandTitle ?? receipt.moduleID ?? "Omni proposal"
        if receipt.state == .interrupted, let effectDisposition = receipt.effectDisposition {
            detail = "\(receipt.summary)\nEffect: \(effectDisposition)"
        } else {
            detail = receipt.summary
        }
        state = receipt.state
        self.actions = actions
        fullText = receipt.fullText
        modelRecord = receipt.modelRecord
        effectiveModelSummary = receipt.modelRecord.map { record in
            let attempt = record.attempts.last
            return (record.offline ? "Offline · " : "") + (attempt?.providerID ?? "No provider") + " · " + (attempt?.outcome.rawValue ?? "unavailable")
        }
        alternatives = receipt.alternatives ?? []
    }
}

private enum StableDigest {
    static func hash(_ value: String) -> String {
        var result: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            result ^= UInt64(byte)
            result &*= 1_099_511_628_211
        }
        return String(result, radix: 16)
    }
}
