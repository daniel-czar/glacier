import Foundation
import OmniCore

// `/span` (C82, spec 98b6b449394ee04e): a pure computation on this Mac. No
// model, no owner operation, no capability: the block is the whole result,
// shown as text and copied by the second Enter (C55).

public enum SpanModuleError: Error, Sendable, Equatable, CustomStringConvertible {
    case unparseable
    case unsupportedSyntax(String)
    case invalidPlan

    public var description: String {
        switch self {
        case .unparseable: SpanCalculator.hint
        case .unsupportedSyntax(let reason): reason
        case .invalidPlan: "span received a mismatched plan"
        }
    }
}

/// Builds the one `/span` module every composition registers. It needs only
/// the manifest and declarations, so installed, candidate and fixture hosts
/// all carry the real module.
public struct SpanModuleCatalog: Sendable {
    public static let moduleID = "compute.span"

    public let factory: AnyCommandModuleFactory

    public init(manifest: CommandManifest, declarations: [ModuleDeclaration]) throws {
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
            SpanCommandModule(descriptor: descriptor)
        }
    }
}

public struct SpanCommandModule: CommandModule {
    public let descriptor: ModuleDescriptor
    /// The clock `today` and `now` read; injected by tests.
    private let clock: @Sendable () -> Date
    private let timeZone: TimeZone

    public init(descriptor: ModuleDescriptor, clock: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current) {
        self.descriptor = descriptor
        self.clock = clock
        self.timeZone = timeZone
    }

    /// The payload with the newline between two endpoints kept, which
    /// `ModuleInput.payloadText` loses.
    static func payload(_ input: ModuleInput) -> String {
        SpanCalculator.payload(rawText: input.rawText, payloadText: input.payloadText)
    }

    public func validate(input: ModuleInput) throws {
        guard input.modifiers.isEmpty else { throw SpanModuleError.unsupportedSyntax("/span accepts no modifiers") }
        guard input.modes.allSatisfy({ $0 == "/offline" }) else { throw SpanModuleError.unsupportedSyntax("/span accepts only /offline") }
        guard SpanCalculator.result(payload: Self.payload(input), now: clock(), timeZone: timeZone) != nil else {
            throw SpanModuleError.unparseable
        }
    }

    public func makePlan(input: ModuleInput) throws -> CommandPlan {
        try validate(input: input)
        return CommandPlan(
            moduleID: descriptor.moduleID,
            input: input,
            capabilitySet: descriptor.capabilities,
            ownerOperation: nil,
            // Accepted and inert: nothing here reaches the network.
            offline: input.modes.contains("/offline")
        )
    }

    public func start(plan: CommandPlan, capabilities: CapabilityBroker, runID: String) async throws -> any RunExecutionHandle {
        guard plan.moduleID == descriptor.moduleID, plan.capabilitySet == descriptor.capabilities, plan.ownerOperation == nil else {
            throw SpanModuleError.invalidPlan
        }
        return SpanExecutionHandle(runID: runID, payload: Self.payload(plan.input), now: clock(), timeZone: timeZone)
    }

    public func reconcile(runID: String, plan: CommandPlan) async -> ReconciliationDisposition { .unavailable }
}

public actor SpanExecutionHandle: RunExecutionHandle {
    public nonisolated let runID: String
    private let payload: String
    private let now: Date
    private let timeZone: TimeZone
    private var cached: ModuleExecutionOutcome?

    init(runID: String, payload: String, now: Date, timeZone: TimeZone) {
        self.runID = runID
        self.payload = payload
        self.now = now
        self.timeZone = timeZone
    }

    public func value() async -> ModuleExecutionOutcome {
        if let cached { return cached }
        let outcome = Self.perform(payload: payload, now: now, timeZone: timeZone)
        cached = outcome
        return outcome
    }

    public func requestCancellation() async -> CancellationAcknowledgement {
        // A pure computation: nothing to stop and nothing to undo.
        CancellationAcknowledgement(requestObserved: cached == nil, taskOrProcessStopped: true, ownerAcknowledged: true, effectCertainty: .certain)
    }

    /// The headline as the summary (what the footer showed while typing),
    /// the block as the full text that Copy takes.
    static func perform(payload: String, now: Date, timeZone: TimeZone) -> ModuleExecutionOutcome {
        guard let span = SpanCalculator.result(payload: payload, now: now, timeZone: timeZone) else {
            return .failed(summary: SpanCalculator.hint)
        }
        return .succeeded(ModuleResult(summary: span.headline, allowedActions: [.copy, .dismiss], fullText: span.block))
    }
}
