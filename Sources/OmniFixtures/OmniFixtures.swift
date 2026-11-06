import Foundation
import OmniCore
import OmniRun

public enum FixtureModuleError: Error, Sendable, Equatable, CustomStringConvertible {
    case validationRequested
    case executionRequested
    case missingBehavior(String)

    public var description: String {
        switch self {
        case .validationRequested: "fixture validation failure requested"
        case .executionRequested: "fixture execution failure requested"
        case .missingBehavior(let moduleID): "fixture behavior missing for \(moduleID)"
        }
    }
}

public enum FixtureBehavior: Sendable, Equatable {
    case todo
    case remind
    case stash
    case capture
    case favorite
    case result(prefix: String, artifactScheme: String? = nil)
}

/// The only filesystem-capable fake owner. Actor serialization prevents concurrent
/// fixture mutations from racing, and the private storage adapter confines every operation.
public actor FixtureOwnerStore {
    public nonisolated let root: URL
    private let storage: ConfinedFixtureStorage

    init(root: URL) throws {
        storage = try ConfinedFixtureStorage(root: root)
        self.root = storage.root
    }

    public func execute(behavior: FixtureBehavior, payload: String, runID: String, source: String? = nil) throws -> ModuleResult {
        switch behavior {
        case .todo:
            try storage.appendTodo(payload)
            return ModuleResult(summary: "Added to fake Ledger", allowedActions: [.dismiss])
        case .remind:
            try storage.appendReminder(payload)
            return ModuleResult(summary: "Added to fake Office queue", allowedActions: [.dismiss])
        case .stash:
            let (artifact, outcome) = try storage.pushStash(payload, runID: runID, source: source)
            return ModuleResult(summary: OmniStashReceipt.summary(for: outcome), artifactReference: artifact, allowedActions: [.copy, .dismiss])
        case .capture:
            let artifact = try storage.capture(payload, runID: runID)
            return ModuleResult(summary: "Captured in fake Base", artifactReference: artifact, allowedActions: [.open, .reveal, .dismiss])
        case .favorite:
            let artifact = try storage.favorite(payload, runID: runID)
            return ModuleResult(summary: "Captured by fake Link Collector", artifactReference: artifact, allowedActions: [.open, .dismiss])
        case .result(let prefix, let artifactScheme):
            let artifact: String?
            switch artifactScheme {
            case "fixture-search": artifact = try storage.searchURL(query: payload)
            case let scheme?: artifact = try storage.resultArtifact(kind: scheme, payload: payload, runID: runID)
            case nil: artifact = nil
            }
            return ModuleResult(summary: "\(prefix): \(payload)", artifactReference: artifact, allowedActions: actions(for: prefix))
        }
    }

    public func contents(relativePath: String) throws -> String {
        try storage.contents(relativePath: relativePath)
    }

    private func actions(for prefix: String) -> [ResultAction] {
        if prefix.contains("draft") { return [.copy, .edit, .dismiss] }
        if prefix.contains("reveal") { return [.reveal, .dismiss] }
        if prefix.contains("open") || prefix.contains("find") { return [.open, .dismiss] }
        return [.copy, .dismiss]
    }
}

public struct FixtureModule: CommandModule {
    public let descriptor: ModuleDescriptor
    private let behavior: FixtureBehavior
    private let owner: FixtureOwnerStore

    public init(descriptor: ModuleDescriptor, behavior: FixtureBehavior, owner: FixtureOwnerStore) {
        self.descriptor = descriptor
        self.behavior = behavior
        self.owner = owner
    }

    public func validate(input: ModuleInput) throws {
        guard !input.canonicalText.contains("[fixture:validation-failure]") else {
            throw FixtureModuleError.validationRequested
        }
    }

    public func makePlan(input: ModuleInput) throws -> CommandPlan {
        try validate(input: input)
        return CommandPlan(moduleID: descriptor.moduleID, input: input, capabilitySet: descriptor.capabilities)
    }

    public func start(plan: CommandPlan, capabilities: CapabilityBroker, runID: String) async throws -> any RunExecutionHandle {
        guard plan.moduleID == descriptor.moduleID, plan.capabilitySet == descriptor.capabilities else {
            throw OmniCoreError.invalidProposal
        }
        for capability in descriptor.capabilities {
            _ = try capabilities.handle(for: capability)
        }
        return FixtureExecutionHandle(runID: runID, plan: plan, behavior: behavior, owner: owner)
    }

    public func reconcile(runID: String, plan: CommandPlan) async -> ReconciliationDisposition {
        .interrupted(effectCertainty: .uncertain)
    }
}

public actor FixtureExecutionHandle: RunExecutionHandle {
    public nonisolated let runID: String
    private let plan: CommandPlan
    private let behavior: FixtureBehavior
    private let owner: FixtureOwnerStore
    private var cancellationRequested = false
    private var effectStarted = false
    private var effectFinished = false
    private var executionFinished = false
    private var cachedOutcome: ModuleExecutionOutcome?
    private var inFlight: Task<ModuleExecutionOutcome, Never>?

    public init(runID: String, plan: CommandPlan, behavior: FixtureBehavior, owner: FixtureOwnerStore) {
        self.runID = runID
        self.plan = plan
        self.behavior = behavior
        self.owner = owner
    }

    public func value() async -> ModuleExecutionOutcome {
        if let cachedOutcome { return cachedOutcome }
        if let inFlight { return await inFlight.value }
        let task = Task { await self.perform() }
        inFlight = task
        let outcome = await task.value
        cachedOutcome = outcome
        executionFinished = true
        inFlight = nil
        return outcome
    }

    private func perform() async -> ModuleExecutionOutcome {
        if plan.input.canonicalText.contains("[fixture:slow]") {
            for _ in 0..<10_000 {
                if cancellationRequested { return .interrupted(effectCertainty: .certain) }
                do { try await Task.sleep(for: .milliseconds(2)) }
                catch { return .interrupted(effectCertainty: .certain) }
            }
        }
        if cancellationRequested { return .interrupted(effectCertainty: .certain) }
        if plan.input.canonicalText.contains("[fixture:execution-failure]") {
            return .failed(summary: FixtureModuleError.executionRequested.description)
        }
        if plan.input.canonicalText.contains("[fixture:interruption]") {
            return .interrupted(effectCertainty: .uncertain)
        }
        effectStarted = true
        do {
            let result = try await owner.execute(
                behavior: behavior,
                payload: Self.payload(from: plan.input.canonicalText),
                runID: runID,
                source: plan.materialSource
            )
            effectFinished = true
            if plan.input.canonicalText.contains("[fixture:post-effect-delay]") {
                try? await Task.sleep(for: .milliseconds(150))
            }
            return .succeeded(result)
        } catch {
            effectFinished = true
            return .failed(summary: "fixture failed: \(error)")
        }
    }

    private static func payload(from canonicalText: String) -> String {
        canonicalText
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.hasPrefix("/") && !$0.hasPrefix("[fixture:") }
            .joined(separator: " ")
    }

    public func requestCancellation() async -> OmniCore.CancellationAcknowledgement {
        if executionFinished || effectFinished {
            return OmniCore.CancellationAcknowledgement(
                requestObserved: false,
                taskOrProcessStopped: true,
                ownerAcknowledged: true,
                effectCertainty: .certain
            )
        }
        cancellationRequested = true
        let uncertain = effectStarted && !effectFinished
        return OmniCore.CancellationAcknowledgement(
            requestObserved: true,
            taskOrProcessStopped: !uncertain,
            ownerAcknowledged: !uncertain,
            effectCertainty: uncertain ? .uncertain : .certain
        )
    }
}

public struct FakeTier2ProposalSource: Tier2ProposalSource {
    public let moduleID: String
    public let capabilities: [Capability]

    public init(moduleID: String = "capture.todo", capabilities: [Capability] = [.appendLedger]) {
        self.moduleID = moduleID
        self.capabilities = capabilities
    }

    public func propose(for intent: ParsedIntent) async throws -> Tier2Proposal {
        Tier2Proposal(moduleID: moduleID, capabilities: capabilities, input: intent.canonicalText)
    }
}

public enum FakeNotificationAuthorization: String, Sendable, Equatable {
    case authorized
    case denied
    case notDetermined
}

public enum FakeNotificationError: Error, Sendable, Equatable {
    case notAuthorized
    case missingDurableRun
    case nonterminalRun
}

/// Compile/test boundary only: no UserNotifications import or system delivery.
/// The bridge looks up the actual durable run and fails closed on permission state.
public actor FakeRunNotificationBridge {
    private let store: OmniRunStore
    private let authorization: FakeNotificationAuthorization
    private var deliveredRunIDs: [RunID] = []

    public init(store: OmniRunStore, authorization: FakeNotificationAuthorization) {
        self.store = store
        self.authorization = authorization
    }

    @discardableResult
    public func publish(runID: RunID) async throws -> String {
        guard authorization == .authorized else { throw FakeNotificationError.notAuthorized }
        guard let receipt = await store.receipt(for: runID) else { throw FakeNotificationError.missingDurableRun }
        guard receipt.status.isTerminal else { throw FakeNotificationError.nonterminalRun }
        deliveredRunIDs.append(runID)
        return "fixture://notification/\(runID.rawValue)"
    }

    public func delivered() -> [RunID] { deliveredRunIDs }
}

public struct FixtureModuleCatalog: Sendable {
    public let owner: FixtureOwnerStore
    public let registry: ModuleRegistry

    public init(manifest: CommandManifest, declarations: [ModuleDeclaration], developmentRoot: OmniDevelopmentRoot) throws {
        try Self.requireIsolatedEnvelope(developmentRoot.url)
        let ownerRoot = try developmentRoot.containedURL(relativePath: "fake-owners")
        let owner = try FixtureOwnerStore(root: ownerRoot)
        let behaviors: [String: FixtureBehavior] = [
            "draft.email": .result(prefix: "fake email draft"),
            "draft.message": .result(prefix: "fake message draft"),
            "answer.quick": .result(prefix: "fake quick answer"),
            "translate": .result(prefix: "fake translation"),
            "title.slug": .result(prefix: "fake slug"),
            "decide.stance": .result(prefix: "fake stance"),
            "think.structure": .result(prefix: "fake structure"),
            "think.expand": .result(prefix: "fake expansion"),
            "think.meaning": .result(prefix: "fake meaning"),
            "open.search": .result(prefix: "fake open search", artifactScheme: "fixture-search"),
            "capture.favorite": .favorite,
            "capture.todo": .todo,
            "cache.remind": .remind,
            "cache.stash": .stash,
            "capture.base": .capture,
            "find.indexed": .result(prefix: "fake find", artifactScheme: "fixture-find"),
            // Replaced by the real module wherever `composedRegistry` runs.
            "compute.span": .result(prefix: "fake span"),
            "open.target": .result(prefix: "fake open target", artifactScheme: "fixture-open"),
            "reveal.target": .result(prefix: "fake reveal target", artifactScheme: "fixture-reveal"),
            "settings.omni": .result(prefix: "fake Omni settings"),
            "settings.model": .result(prefix: "fake model settings")
        ]
        let declarationsByID = Dictionary(uniqueKeysWithValues: declarations.map { ($0.moduleID, $0) })
        let factories = try manifest.moduleIDs.sorted().map { moduleID -> AnyCommandModuleFactory in
            guard let declaration = declarationsByID[moduleID],
                  let behavior = behaviors[moduleID],
                  let command = manifest.command(for: declaration.tokens.canonical)
            else { throw FixtureModuleError.missingBehavior(moduleID) }
            let descriptor = ModuleDescriptor(
                moduleID: moduleID,
                moduleVersion: declaration.moduleVersion,
                execution: declaration.executionPath.kind,
                capabilities: Set(command.capabilities),
                policies: declaration.typedPolicies
            )
            return AnyCommandModuleFactory(moduleID: moduleID) {
                FixtureModule(descriptor: descriptor, behavior: behavior, owner: owner)
            }
        }
        let registry = try ModuleRegistry(factories)
        try ManifestParityValidator().validate(manifest: manifest, declarations: declarations, registry: registry)
        self.owner = owner
        self.registry = registry
    }

    private static func requireIsolatedEnvelope(_ candidate: URL) throws {
        let manager = FileManager.default
        let envelope = OmniLayout.candidateEnvelope
        let temporary = manager.temporaryDirectory
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard contains(envelope, resolved) || contains(temporary, resolved) else {
            throw OmniRunError.forbiddenDevelopmentRoot(resolved.path)
        }
    }

    private static func contains(_ envelope: URL, _ candidate: URL) -> Bool {
        let root = envelope.standardizedFileURL.resolvingSymlinksInPath().path
        let path = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root + "/")
    }
}

private struct ConfinedFixtureStorage: Sendable {
    let root: URL

    init(root: URL) throws {
        guard root.isFileURL, root.path.hasPrefix("/") else { throw OmniCoreError.invalidFixtureRoot }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    func appendTodo(_ text: String) throws { try write(text + "\n", relativePath: "ledger/capture.txt", append: true) }

    func appendReminder(_ text: String) throws {
        let item = text.trimmingCharacters(in: .whitespaces)
        guard !item.isEmpty, item.rangeOfCharacter(from: .newlines) == nil, !item.hasPrefix("#") else {
            throw OmniCoreError.invalidFixtureRoot
        }
        try write(item + "\n", relativePath: "office/QUEUE.md", append: true)
    }

    /// The fake stash is the real stack in the fake root; `current.txt`
    /// mirrors the top entry for tests that read plain text.
    func pushStash(_ text: String, runID: String, source: String?) throws -> (String, OmniStashPushOutcome) {
        let receipt = try file("stash/current.json")
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stack = OmniStashStack(url: receipt)
        let outcome = try OmniStashReceipt.push(text, runID: runID, source: source, into: stack)
        try write(try stack.entry(at: 1)?.text ?? "", relativePath: "stash/current.txt", append: false)
        return (receipt.path, outcome)
    }

    func capture(_ text: String, runID: String) throws -> String {
        let relative = "base-artifacts/\(runID).txt"
        try write(text, relativePath: relative, append: false)
        return try file(relative).path
    }

    func favorite(_ url: String, runID: String) throws -> String {
        let relative = "favorites/\(runID).txt"
        try write(url, relativePath: relative, append: false)
        return try file(relative).path
    }

    func resultArtifact(kind: String, payload: String, runID: String) throws -> String {
        let relative = "result-artifacts/\(kind)/\(runID).txt"
        try write(payload, relativePath: relative, append: false)
        return try file(relative).path
    }

    func searchURL(query: String) throws -> String {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query.isEmpty ? "fixture-search" : query)]
        guard let url = components?.url else { throw OmniCoreError.invalidFixtureRoot }
        return url.absoluteString
    }

    func contents(relativePath: String) throws -> String {
        try String(contentsOf: file(relativePath), encoding: .utf8)
    }

    private func file(_ relativePath: String) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !relativePath.hasPrefix("/"), !components.contains(".."), !components.isEmpty else {
            throw OmniCoreError.invalidFixtureRoot
        }
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let resolvedParent = candidate.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedParent.path == root.path || resolvedParent.path.hasPrefix(root.path + "/"),
              resolvedCandidate.path == root.path || resolvedCandidate.path.hasPrefix(root.path + "/")
        else { throw OmniCoreError.invalidFixtureRoot }
        return candidate
    }

    private func write(_ text: String, relativePath: String, append: Bool) throws {
        let target = try file(relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if append && FileManager.default.fileExists(atPath: target.path) {
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.synchronize()
        } else {
            try Data(text.utf8).write(to: target, options: .atomic)
        }
    }
}
