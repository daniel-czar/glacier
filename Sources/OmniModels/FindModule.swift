import Foundation
import OmniCore

// `/find`, deterministic first (D2, decision surface 569d5a7cf925cbd7):
//
// 1. an exact id resolves through the registered resolver, as before;
// 2. filters alone run on the local docs-index executor;
// 3. free words go to the model, which writes a query in the same filter
//    grammar plus terms (typed filters stay as hard constraints); the
//    local index runs it, and the model never sees a row. Under `/offline`,
//    or where no model is composed, the words are plain title and summary
//    terms instead. Either way, when no row satisfies all of the query the
//    closest rows come back, labelled so (`FindIndex.rank`).
//
// Tiers 1 and 2 record no model attempt, so the header reads "On this
// Mac". The short-circuit lives here, not in the pad, so socket and drive
// submits get the same tiers.

public enum FindModuleError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyQuery
    case unsupportedSyntax(String)
    case indexUnavailable(String)
    case invalidPlan

    public var description: String {
        switch self {
        case .emptyQuery: "Find needs an id, a filter or some words"
        case .unsupportedSyntax(let reason): reason
        case .indexUnavailable(let reason): "The docs index is unavailable · \(reason)"
        case .invalidPlan: "find received a mismatched plan"
        }
    }
}

/// Builds the one `/find` module every composition registers.
public struct FindModuleCatalog: Sendable {
    public static let moduleID = "find.indexed"

    public let factory: AnyCommandModuleFactory

    public init(manifest: CommandManifest, declarations: [ModuleDeclaration], index: (any FindIndexProviding)?, broker: (any ModelGenerating)? = nil) throws {
        guard let declaration = declarations.first(where: { $0.moduleID == Self.moduleID }),
              let command = manifest.command(for: declaration.tokens.canonical)
        else { throw OmniCoreError.unknownModule(Self.moduleID) }
        let descriptor = ModuleDescriptor(
            moduleID: Self.moduleID,
            moduleVersion: declaration.moduleVersion,
            execution: declaration.executionPath.kind,
            capabilities: Set(command.capabilities),
            policies: declaration.typedPolicies
        )
        factory = AnyCommandModuleFactory(moduleID: Self.moduleID) {
            FindCommandModule(descriptor: descriptor, index: index, broker: broker)
        }
    }
}

public struct FindCommandModule: CommandModule {
    public let descriptor: ModuleDescriptor
    private let index: (any FindIndexProviding)?
    private let broker: (any ModelGenerating)?

    public init(descriptor: ModuleDescriptor, index: (any FindIndexProviding)?, broker: (any ModelGenerating)? = nil) {
        self.descriptor = descriptor
        self.index = index
        self.broker = broker
    }

    /// The output budget for a query reply: one short JSON object.
    public static let replyCharacterLimit = 800

    public func validate(input: ModuleInput) throws {
        guard input.modifiers.isEmpty else { throw FindModuleError.unsupportedSyntax("/find accepts no modifiers") }
        guard input.modes.allSatisfy({ $0 == "/offline" }) else { throw FindModuleError.unsupportedSyntax("/find accepts only /offline") }
        let query = FindQuery(payload: input.payloadText)
        if let refusal = query.refusal { throw FindModuleError.unsupportedSyntax(refusal) }
        guard !query.isEmpty else { throw FindModuleError.emptyQuery }
    }

    public func makePlan(input: ModuleInput) throws -> CommandPlan {
        try validate(input: input)
        let query = FindQuery(payload: input.payloadText)
        return CommandPlan(
            moduleID: descriptor.moduleID,
            input: input,
            capabilitySet: descriptor.capabilities,
            // Only tier 1 goes through an owner operation (the registered
            // resolver); tiers 2 and 3 read the docs index in process.
            ownerOperation: query.tier == .id ? .readRegisteredIndex : nil,
            offline: input.modes.contains("/offline")
        )
    }

    public func start(plan: CommandPlan, capabilities: CapabilityBroker, runID: String) async throws -> any RunExecutionHandle {
        guard plan.moduleID == descriptor.moduleID, plan.capabilitySet == descriptor.capabilities else { throw FindModuleError.invalidPlan }
        let query = FindQuery(payload: plan.input.payloadText)
        var resolver: OwnerOperationHandle?
        if query.tier == .id {
            do {
                resolver = try capabilities.operationHandle(for: .readRegisteredIndex)
            } catch OmniCoreError.missingOwnerOperation {
                // No resolver composed (fixture hosts): the docs index
                // answers documents. A policy denial is not this case.
                resolver = nil
            }
        }
        // Tier 3 only: words, online, with a model composed. The request is
        // completed with the facet vocabulary when the run starts.
        let model: FindExecutionHandle.ModelTier? = if query.asksModel, !plan.offline, let broker {
            FindExecutionHandle.ModelTier(broker: broker, commandID: descriptor.moduleID, input: plan.input)
        } else {
            nil
        }
        return FindExecutionHandle(runID: runID, query: query, typed: plan.input.payloadText, offline: plan.offline, index: index, resolver: resolver, model: model)
    }

    public func reconcile(runID: String, plan: CommandPlan) async -> ReconciliationDisposition { .unavailable }
}

public actor FindExecutionHandle: RunExecutionHandle {
    /// What tier 3 needs to ask the model for a query.
    struct ModelTier: Sendable {
        let broker: any ModelGenerating
        let commandID: String
        let input: ModuleInput
    }

    public nonisolated let runID: String
    private let query: FindQuery
    private let typed: String
    private let offline: Bool
    private let index: (any FindIndexProviding)?
    private let resolver: OwnerOperationHandle?
    private let model: ModelTier?
    private var task: Task<ModuleExecutionOutcome, Never>?
    private var cached: ModuleExecutionOutcome?
    private var record: ModelExecutionRecord?

    init(runID: String, query: FindQuery, typed: String, offline: Bool, index: (any FindIndexProviding)?, resolver: OwnerOperationHandle?, model: ModelTier? = nil) {
        self.runID = runID
        self.query = query
        self.typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        self.offline = offline
        self.index = index
        self.resolver = resolver
        self.model = model
    }

    /// Tier 3's model record; nil for every tier that asked no model.
    public func modelExecutionRecord() async -> ModelExecutionRecord? { record }

    public func value() async -> ModuleExecutionOutcome {
        if let cached { return cached }
        if let task { return await task.value }
        let work = Task { await self.perform() }
        task = work
        let outcome = await work.value
        cached = outcome
        task = nil
        return outcome
    }

    public func requestCancellation() async -> CancellationAcknowledgement {
        // Read-only work: nothing to undo, whether or not it finished.
        task?.cancel()
        return CancellationAcknowledgement(requestObserved: cached == nil, taskOrProcessStopped: true, ownerAcknowledged: true, effectCertainty: .certain)
    }

    private func perform() async -> ModuleExecutionOutcome {
        do {
            let result: OmniFindResult
            switch query.tier {
            case .id:
                result = try await resolveID()
            case .filters:
                result = try local(tier: .filters, query: query)
            case .words:
                guard let model else {
                    // `/offline`, or no model composed: plain terms (D2).
                    result = try local(tier: .localTerms, query: query)
                    break
                }
                return try await translate(model)
            }
            return .succeeded(Self.moduleResult(result))
        } catch let error as ModelBrokerError {
            record = error.record
            if case .cancelled = error { return .interrupted(effectCertainty: .certain) }
            return .failed(summary: error.description)
        } catch is CancellationError {
            return .interrupted(effectCertainty: .certain)
        } catch {
            return .failed(summary: String(describing: error))
        }
    }

    /// Tier 3 (D2): the model writes a query from the words, the typed
    /// filters stay as hard constraints, the local index runs it. The model's
    /// reply is parsed as a query and nothing else; it never sees a row.
    private func translate(_ model: ModelTier) async throws -> ModuleExecutionOutcome {
        guard let index else { throw FindModuleError.indexUnavailable("no docs index is composed") }
        let current = try index.currentIndex()
        let request = ModelGenerationRequest(
            runID: runID,
            commandID: model.commandID,
            // The vocabulary from rows not marked private, as the retrieval
            // surface built for models does.
            prompt: FindQueryPrompt.prompt(typed: query, facets: current.promptFacets),
            offline: false,
            input: model.input,
            outputConstraint: ModelOutputConstraint(shape: .findQuery, maximumCharacters: FindCommandModule.replyCharacterLimit),
            dispatch: ModelDispatchContext(generationID: UUID().uuidString.lowercased(), selection: model.input.modelSelection)
        )
        let generated: ModelBrokerResult
        do {
            generated = try await model.broker.execute(request)
        } catch ModelBrokerError.missingPolicy {
            // This composition's policy has no find row: no model tier, so
            // plain terms, as under `/offline`.
            return .succeeded(Self.moduleResult(try local(tier: .localTerms, query: query)))
        }
        record = generated.record
        // Both brokers validated the shape with this parser already.
        guard let reply = FindQueryReply.parse(generated.response.text) else {
            return .failed(summary: "The model did not return a query")
        }
        // A model filter goes on the facet that holds its value; one the
        // index does not hold at all can only empty the result, so it is
        // dropped. Typed filters are never touched.
        let known = FindQuery(filters: reply.filters.compactMap(current.facets.placed), terms: reply.terms)
        var merged = FindQuery.constrained(typed: query, translated: known)
        let addedNothing = merged.terms.isEmpty && merged.filters == query.filters
        if addedNothing, merged.filters.isEmpty || !(reply.filters.isEmpty && reply.terms.isEmpty) {
            // Nothing usable came back (every model filter dropped, no terms):
            // the person's words, as plain terms, beside the typed filters;
            // never an empty query that would match everything. A literally
            // empty reply beside typed filters is "the filters say it all".
            merged = FindQuery(filters: query.filters, terms: query.terms)
        }
        // Typed filters are hard; the model's part ranks (closest rows when
        // nothing satisfies all of it).
        let found = current.rank(hard: query.filters, soft: merged.filters.filter { !query.filters.contains($0) }, terms: merged.terms)
        let result = OmniFindResult(
            tier: .words,
            typed: typed,
            query: merged.text,
            modelOutput: generated.response.text,
            rows: found.rows.map(Self.row),
            total: found.total,
            exact: found.exact
        )
        return .succeeded(Self.moduleResult(result, modelRecord: generated.record))
    }

    /// Tier 1: the registered resolver, exactly as `/find <id>` worked before
    /// (D2); a namespace narrows its matches. Without a resolver composed
    /// (fixture hosts), the docs index answers documents by exact id.
    private func resolveID() async throws -> OmniFindResult {
        guard let address = query.address else { throw FindModuleError.invalidPlan }
        let rows: [OmniFindRow]
        if let resolver {
            let outcome = await resolver.invoke(OwnerOperationRequest(runID: runID, payload: address.id, offline: offline))
            switch outcome {
            case .succeeded(let result):
                guard let find = result.find else { throw FindModuleError.indexUnavailable("the resolver returned no rows") }
                rows = find.rows
            case .failed(let summary):
                throw FindModuleError.indexUnavailable(summary)
            case .interrupted:
                throw FindModuleError.indexUnavailable("the resolver was interrupted")
            }
        } else {
            guard let index else { throw FindModuleError.indexUnavailable("no resolver or docs index is composed") }
            rows = try index.currentIndex().document(id: address.id).map(Self.row)
        }
        let narrowed = rows.filter { row in address.namespace.map { row.namespace.rawValue == $0.rawValue } ?? true }
        let ordered = narrowed.filter { $0.namespace == .doc } + narrowed.filter { $0.namespace == .run }
        return OmniFindResult(tier: .id, typed: typed, query: query.text, rows: ordered, total: ordered.count)
    }

    private func local(tier: OmniFindResult.Tier, query: FindQuery) throws -> OmniFindResult {
        guard let index else { throw FindModuleError.indexUnavailable("no docs index is composed") }
        let current = try index.currentIndex()
        guard tier == .localTerms else {
            // Tier 2 stays strict: `retrieve docs` parity.
            let found = current.query(filters: query.filters, terms: query.terms)
            return OmniFindResult(tier: tier, typed: typed, query: query.text, rows: found.rows.map(Self.row), total: found.total)
        }
        // Plain words rank like tier 3's: typed filters hard, words soft.
        let found = current.rank(hard: query.filters, soft: [], terms: query.terms)
        return OmniFindResult(tier: tier, typed: typed, query: query.text, rows: found.rows.map(Self.row), total: found.total, exact: found.exact)
    }

    static func row(_ document: FindDocument) -> OmniFindRow {
        OmniFindRow(path: document.path, title: document.title, kind: document.kind.isEmpty ? "doc" : document.kind, namespace: .doc, id: document.documentID, modified: document.modified)
    }

    /// The receipt: the path list as `fullText` (what Copy and older binaries
    /// see), the query as the summary, the rows for the picker.
    static func moduleResult(_ result: OmniFindResult, modelRecord: ModelExecutionRecord? = nil) -> ModuleResult {
        ModuleResult(
            summary: result.summary,
            allowedActions: result.rows.isEmpty ? [.dismiss] : [.copy, .dismiss],
            // An empty result says so in words rather than as a blank text.
            fullText: result.rows.isEmpty ? result.summary : result.pathList,
            modelRecord: modelRecord,
            find: result
        )
    }
}
