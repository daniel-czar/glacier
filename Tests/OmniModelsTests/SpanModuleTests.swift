import Foundation
import OmniCore
@testable import OmniModels
import Testing

// The `/span` module (C82, spec 98b6b449394ee04e): a pure local computation,
// refused before admission when the payload does not parse, with the block
// as the full text and no model record.

private let utc = TimeZone(secondsFromGMT: 0)!
private let fixedNow: Date = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    return calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 12))!
}()

private func module() throws -> SpanCommandModule {
    let corpus = FrozenContractCorpus()
    let catalog = try SpanModuleCatalog(manifest: try corpus.manifest(), declarations: try corpus.moduleDeclarations().declarations)
    let built = try #require(catalog.factory.build() as? SpanCommandModule)
    // The catalog's module, on the injected clock.
    return SpanCommandModule(descriptor: built.descriptor, clock: { fixedNow }, timeZone: utc)
}

private func input(_ raw: String, payload: String? = nil, modes: Set<String> = [], modifiers: Set<String> = []) -> ModuleInput {
    ModuleInput(canonicalText: raw, rawText: raw, payloadText: payload ?? SlashTokenSyntax.payloadText(from: raw), modes: modes, modifiers: modifiers)
}

private func run(_ input: ModuleInput, module: SpanCommandModule) async throws -> (CommandPlan, ModuleResult, SpanExecutionHandle) {
    let plan = try module.makePlan(input: input)
    let handle = try await module.start(plan: plan, capabilities: CapabilityBroker(declared: plan.capabilitySet), runID: "run-\(UUID().uuidString)")
    let span = try #require(handle as? SpanExecutionHandle)
    guard case .succeeded(let result) = await span.value() else { throw SpanModuleError.invalidPlan }
    return (plan, result, span)
}

@Test func theCatalogDeclaresALocalCommandWithNoCapability() throws {
    let module = try module()
    #expect(module.descriptor.moduleID == "compute.span")
    #expect(module.descriptor.execution == .deterministicLocal)
    #expect(module.descriptor.capabilities.isEmpty)
    #expect(module.descriptor.policies.model.profile == "none")
}

@Test func aRangeRunsLocallyIntoTheBlock() async throws {
    let module = try module()
    let (plan, result, handle) = try await run(input("/span 1 october 2014 to 30 september 2016"), module: module)
    #expect(plan.ownerOperation == nil)
    #expect(plan.capabilitySet.isEmpty)
    #expect(!plan.offline)
    #expect(result.fullText == """
    Total period: 2 years (1 Oct 2014 – 30 Sep 2016, both days counted)
    = 2.00 years
    = 24.0 months
    = 104 weeks
    = 731 days
    ≈ 17.5k hours
    """)
    #expect(result.summary == "1 Oct 2014 – 30 Sep 2016 · 2 years · 731 days")
    #expect(result.allowedActions == [.copy, .dismiss])
    #expect(result.modelRecord == nil && result.find == nil)
    #expect(await handle.modelExecutionRecord() == nil, "no model attempt")
}

@Test func endpointsOnSeparateLinesReadFromTheRawText() async throws {
    // `payloadText` joins the lines with a space; the module reads the
    // newline from the raw text it came from.
    let raw = "/span 24 october 23:59\n26 october 14:46"
    #expect(SlashTokenSyntax.payloadText(from: raw) == "24 october 23:59 26 october 14:46")
    let (_, result, _) = try await run(input(raw), module: try module())
    #expect(result.fullText == """
    Total period: 1 day, 14 hours, 47 minutes (24 Oct 2026 23:59 – 26 Oct 2026 14:46)
    = 1.62 days
    = 38.8 hours
    = 2,327 minutes
    """)
}

@Test func offlineIsAcceptedAndChangesNothing() async throws {
    let module = try module()
    let (online, onlineResult, _) = try await run(input("/span 24 dec to 2 jan"), module: module)
    let (offline, offlineResult, _) = try await run(input("/span 24 dec to 2 jan /offline", modes: ["/offline"]), module: module)
    #expect(!online.offline && offline.offline)
    #expect(onlineResult == offlineResult)
}

@Test func offsetRunsLocallyWithTheAnswerAndNoModelRecord() async throws {
    let module = try module()
    let (plan, result, handle) = try await run(input("/span 5 months after 19 october 2026"), module: module)
    #expect(plan.ownerOperation == nil)
    #expect(plan.capabilitySet.isEmpty)
    #expect(result.fullText == "Result: 19 Mar 2027\n5 months after 19 Oct 2026")
    #expect(result.summary == "19 Mar 2027 · 5 months after 19 Oct 2026")
    #expect(result.allowedActions == [.copy, .dismiss])
    #expect(result.modelRecord == nil && result.find == nil)
    #expect(await handle.modelExecutionRecord() == nil)
}

@Test func beforeOffsetIsIdenticalOffline() async throws {
    let module = try module()
    let (_, online, _) = try await run(input("/span 5 months before 19 october 2026"), module: module)
    let (offlinePlan, offline, handle) = try await run(input("/span 5 months before 19 october 2026 /offline", modes: ["/offline"]), module: module)
    #expect(offlinePlan.offline)
    #expect(online == offline)
    #expect(offline.fullText == "Result: 19 May 2026\n5 months before 19 Oct 2026")
    #expect(offline.summary == "19 May 2026 · 5 months before 19 Oct 2026")
    #expect(await handle.modelExecutionRecord() == nil)
}

@Test func modifiersOtherModesAndUnparseablePayloadsAreRefused() throws {
    let module = try module()
    #expect(throws: SpanModuleError.unsupportedSyntax("/span accepts no modifiers")) {
        try module.validate(input: input("/span 1 oct 2014 /style:formal", payload: "1 oct 2014", modifiers: ["/style:formal"]))
    }
    #expect(throws: SpanModuleError.unsupportedSyntax("/span accepts only /offline")) {
        try module.validate(input: input("/span 1 oct 2014 /later", payload: "1 oct 2014", modes: ["/later"]))
    }
    for raw in ["/span", "/span hello", "/span 1 oct 2014 to 2 oct 2014 to 3 oct 2014", "/span 1/10/14"] {
        #expect(throws: SpanModuleError.unparseable, "\(raw)") { try module.validate(input: input(raw)) }
    }
    // The refusal reads as the hint the pad shows.
    #expect(String(describing: SpanModuleError.unparseable) == "Two dates or times, one date for time since, or an offset, e.g. 5 months after 19 oct 2026")
}

@Test func aMismatchedPlanIsRefusedAtStart() async throws {
    let module = try module()
    let plan = CommandPlan(moduleID: "compute.span", input: input("/span today"), capabilitySet: [.openURL])
    await #expect(throws: SpanModuleError.invalidPlan) {
        _ = try await module.start(plan: plan, capabilities: CapabilityBroker(declared: plan.capabilitySet), runID: "run-1")
    }
}

@Test func cancellationIsCertainAndReconciliationHasNothingToFind() async throws {
    let module = try module()
    let plan = try module.makePlan(input: input("/span 14 march 1990"))
    let handle = try await module.start(plan: plan, capabilities: CapabilityBroker(declared: plan.capabilitySet), runID: "run-2")
    let early = await handle.requestCancellation()
    #expect(early.permitsTerminalCancellation)
    _ = await handle.value()
    let late = await handle.requestCancellation()
    #expect(late.effectCertainty == .certain && late.taskOrProcessStopped && late.ownerAcknowledged)
    #expect(await module.reconcile(runID: "run-2", plan: plan) == .unavailable)
}

@Test func aPayloadThatStopsParsingBeforeTheRunFailsWithTheHint() {
    // Defensive: validation already refused such a payload; the handle says
    // the same if it ever sees one.
    #expect(SpanExecutionHandle.perform(payload: "hello", now: fixedNow, timeZone: utc) == .failed(summary: SpanCalculator.hint))
}
