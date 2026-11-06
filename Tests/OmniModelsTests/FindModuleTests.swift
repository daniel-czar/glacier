import Foundation
import OmniCore
@testable import OmniModels
import Testing

// The `/find` module's deterministic tiers (D2, decision surface
// 569d5a7cf925cbd7): ids and filters answer with no model attempt, and the
// short-circuit lives in the module, so every caller gets it.

private let index = FindIndex(documents: [
    FindDocument(path: "/Users/fixture/Base/a.md", title: "Adversarial review of an ML run", kind: "review", documentID: "569d5a7cf925cbd7", summary: "Helios", projectValues: ["project_helios"], tagValues: ["ml"]),
    FindDocument(path: "/Users/fixture/Base/b.md", title: "A report", kind: "report", projectValues: ["project_helios"]),
    FindDocument(path: "/Users/fixture/Base/c.md", title: "Another review", kind: "review", projectValues: ["project_cassandra"]),
])

private func module(index: (any FindIndexProviding)? = StaticFindIndex(index)) throws -> any CommandModule {
    let corpus = FrozenContractCorpus()
    let catalog = try FindModuleCatalog(manifest: try corpus.manifest(), declarations: try corpus.moduleDeclarations().declarations, index: index)
    return catalog.factory.build()
}

private func run(_ payload: String, modes: [String] = [], module: any CommandModule) async throws -> (CommandPlan, ModuleResult) {
    let input = ModuleInput(canonicalText: "/find \(payload)", rawText: "/find \(payload)", payloadText: payload, modes: Set(modes))
    let plan = try module.makePlan(input: input)
    let handle = try await module.start(plan: plan, capabilities: CapabilityBroker(declared: plan.capabilitySet), runID: "run-\(UUID().uuidString)")
    guard case .succeeded(let result) = await handle.value() else { throw FindModuleError.invalidPlan }
    #expect(await handle.modelExecutionRecord() == nil, "no model attempt")
    return (plan, result)
}

@Test func filtersOnlyRunsLocallyWithNoModelAttempt() async throws {
    let module = try module()
    #expect(module.descriptor.execution == .modelBacked, "declared model-backed for tier 3 (amendment 1.5.0)")
    let (plan, result) = try await run("kind:review in:helios", module: module)
    #expect(plan.ownerOperation == nil)
    #expect(result.modelRecord == nil)
    let find = try #require(result.find)
    #expect(find.tier == .filters)
    #expect(find.query == "kind:review in:helios")
    #expect(find.rows.map(\.path) == ["/Users/fixture/Base/a.md"])
    #expect(find.rows.first?.id == "569d5a7cf925cbd7" && find.rows.first?.kind == "review")
    #expect(result.fullText == "/Users/fixture/Base/a.md", "the path list, as retrieve docs prints it")
    #expect(result.summary == "1 found · kind:review in:helios")
    #expect(result.allowedActions == [.copy, .dismiss])
}

@Test func anIDTheResolverPolicyDeniesFailsInsteadOfFallingBackToTheIndex() async throws {
    let module = try module()
    let input = ModuleInput(canonicalText: "/find 569d5a7cf925cbd7", rawText: "/find 569d5a7cf925cbd7", payloadText: "569d5a7cf925cbd7")
    let plan = try module.makePlan(input: input)
    #expect(plan.ownerOperation == .readRegisteredIndex)
    let denying = CapabilityBroker(declared: plan.capabilitySet, environment: try CapabilityEnvironment(profile: .replica, installedPolicy: [], handles: []), offline: false)
    await #expect(throws: OmniCoreError.ownerOperationPolicyDenied(.readRegisteredIndex)) {
        _ = try await module.start(plan: plan, capabilities: denying, runID: "run-denied")
    }
    // With no resolver composed at all (fixture hosts), the index answers.
    let (_, result) = try await run("569d5a7cf925cbd7", module: module)
    #expect(result.find?.rows.map(\.path) == ["/Users/fixture/Base/a.md"])
}

@Test func anEmptyResultSaysSoInWords() async throws {
    let (_, result) = try await run("kind:nothing", module: try module())
    #expect(result.find?.rows.isEmpty == true)
    #expect(result.fullText == "No match · kind:nothing", "never a blank result view")
    #expect(result.allowedActions == [.dismiss])
}

@Test func offlineBehavesIdenticallyForFilters() async throws {
    let module = try module()
    let (online, onlineResult) = try await run("kind:review", module: module)
    let (offline, offlineResult) = try await run("kind:review", modes: ["/offline"], module: module)
    #expect(!online.offline && offline.offline)
    #expect(onlineResult.find?.rows == offlineResult.find?.rows)
    #expect(offlineResult.find?.tier == .filters && offlineResult.modelRecord == nil)
}

@Test func freeWordsWithNoModelTierMatchTitlesAndSummaries() async throws {
    let (_, result) = try await run("kind:review adversarial", modes: ["/offline"], module: try module())
    #expect(result.find?.tier == .localTerms)
    #expect(result.find?.rows.map(\.title) == ["Adversarial review of an ML run"])
    #expect(result.modelRecord == nil)
}

@Test func anIDWithNoResolverComposedAnswersFromTheIndex() async throws {
    let module = try module()
    let (plan, result) = try await run("569d5a7cf925cbd7", module: module)
    #expect(plan.ownerOperation == .readRegisteredIndex, "tier 1 keeps the registered resolver's route")
    #expect(result.find?.tier == .id)
    #expect(result.find?.rows.map(\.path) == ["/Users/fixture/Base/a.md"])
    let (_, runOnly) = try await run("run:569d5a7cf925cbd7", module: module)
    #expect(runOnly.find?.rows.isEmpty == true, "a run: prefix narrows to run folders")
    let (_, miss) = try await run("0000000000000000", module: module)
    #expect(miss.find?.rows.isEmpty == true && miss.summary == "No match · 0000000000000000")
    #expect(miss.allowedActions == [.dismiss])
}

@Test func anEmptyQueryOrAModifierIsRefused() throws {
    let module = try module()
    #expect(throws: FindModuleError.emptyQuery) { try module.validate(input: ModuleInput(canonicalText: "/find", rawText: "/find", payloadText: " ")) }
    #expect(throws: (any Error).self) { try module.validate(input: ModuleInput(canonicalText: "/find x /formal", rawText: "/find x /formal", payloadText: "x", modifiers: ["/formal"])) }
}

@Test func withoutAnIndexFiltersFailClosed() async throws {
    let module = try module(index: nil)
    let input = ModuleInput(canonicalText: "/find kind:review", rawText: "/find kind:review", payloadText: "kind:review")
    let plan = try module.makePlan(input: input)
    let handle = try await module.start(plan: plan, capabilities: CapabilityBroker(declared: plan.capabilitySet), runID: "run-1")
    guard case .failed(let summary) = await handle.value() else {
        Issue.record("expected a failure")
        return
    }
    #expect(summary.contains("docs index is unavailable"))
}
