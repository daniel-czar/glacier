import Foundation
import OmniCore
import OmniModels
import Testing

// Command-set amendment 1.2.0: `/slug` (module `title.slug`, output shape
// `.urlSlug`) joins the routine ladder. These tests pin the deterministic
// slug contract and its routing; live quality remains a qualification matter.

@Test(arguments: [
    ("common-european-language", "common-european-language"),
    ("  Common European Language\n", "common-european-language"),
    ("`common-european-language`", "common-european-language"),
    ("\"Common European Language.\"", "common-european-language"),
    ("Slug: common_european_language", "common-european-language"),
    ("URL slug: `common-european-language`", "common-european-language"),
    ("Über die Größe — Café Zürich", "uber-die-grosse-cafe-zurich"),
    ("common-european-language\n\nThis captures the central argument.", "common-european-language"),
    ("---", nil),
    ("", nil),
] as [(String, String?)])
func urlSlugNormalisationIsDeterministicAndKeepsOnlyTheFirstLine(input: String, expected: String?) {
    #expect(URLSlug.normalize(input) == expected)
}

@Test func urlSlugValidityRequiresTwoToSixHyphenatedAsciiWords() {
    #expect(URLSlug.isValid("common-european-language"))
    #expect(URLSlug.isValid("a-b"))
    #expect(URLSlug.isValid("one-two-three-four-five-six"))
    #expect(!URLSlug.isValid("single"))
    #expect(!URLSlug.isValid("one-two-three-four-five-six-seven"))
    #expect(!URLSlug.isValid("has--empty-word"))
    #expect(!URLSlug.isValid("Upper-case"))
    #expect(!URLSlug.isValid("under_score-word"))
}

@Test func slugCommandFollowsTheQuickLadderWithTheURLSlugShape() throws {
    let command = try #require(ModelProviderPolicy.v6.command(named: "title.slug"))
    #expect(command.outputShape == .urlSlug)
    #expect(command.ladder(offline: false) == [ProviderRuntimeCatalog.cerebrasFastProfileID, ProviderRuntimeCatalog.openRouterGPTOSSProfileID, ProviderRuntimeCatalog.localFastProfileID])
    #expect(command.ladder(offline: true) == [ProviderRuntimeCatalog.localFastProfileID])
    #expect(ProviderRuntimeCatalog.routineCommandIDs.contains("title.slug"))
    #expect(ProviderRuntimeCatalog.profile(ProviderRuntimeCatalog.cerebrasFastProfileID)?.eligibleCommandIDs.contains("title.slug") == true)
    #expect(ProviderRuntimeCatalog.profile(ProviderRuntimeCatalog.localFastProfileID)?.eligibleCommandIDs.contains("title.slug") == true)
    #expect(ProviderRuntimeCatalog.profile(ProviderRuntimeCatalog.localCapableProfileID)?.id == ProviderRuntimeCatalog.localFastProfileID)
    #expect(ProviderRuntimeSettings.freshDefaults().command("title.slug") != nil)
}

@Test func slugPromptAsksForOneLowercaseHyphenatedTitleWithoutGuides() throws {
    let builder = LanguagePromptBuilder()
    let input = ModuleInput(canonicalText: "/slug", payloadText: "The European languages are members of the same family.")
    let prompt = try builder.prompt(for: .slug, input: input)
    #expect(prompt.contains("2-4 meaningful lowercase words"))
    #expect(prompt.contains("Return only the slug"))
    #expect(prompt.contains("User text:\nThe European languages"))
    #expect(!prompt.contains("Adopted guide"))
    #expect(builder.styleGuide(for: .slug) == nil)
    #expect(builder.contextGuides(for: .slug).isEmpty)
}

@Test func brokerRejectsProseSlugRepliesAndFallsBackThenTheModuleNormalisesTheAcceptedValue() async throws {
    // Prose from Cerebras fails the shape; the hosted OpenRouter fallback
    // answers with a fenced slug that the same check accepts.
    let harness = try RoutingHarness(scripts: [
        .cerebrasHTTP: [.success(text: "Here is a good slug for the text you supplied: common european language")],
        .openRouterHTTP: [.success(text: "`Common European Language`\n\nThis captures the central argument.")],
    ])
    let broker = try harness.broker()
    let result = try await broker.execute(generationRequest("title.slug"))
    #expect(result.record.attempts.map(\.outcome) == [.failed, .succeeded])
    #expect(result.record.attempts.first?.identity?.failure == .invalidResponse)
    #expect(result.record.attempts.last?.identity?.profileID == ProviderRuntimeCatalog.openRouterGPTOSSProfileID)
    #expect(await harness.driver(.ollamaHTTP).callCount() == 0)
    #expect(LanguageWorkflow.slug.finalize(result.response.text) == "common-european-language")

    let corpus = FrozenContractCorpus()
    let catalog = try ProductionLanguageModuleCatalog(
        manifest: try corpus.manifest(),
        declarations: try corpus.moduleDeclarations().declarations,
        broker: ProviderRuntimeBrokerStore(broker: try RoutingHarness(scripts: [.cerebrasHTTP: [.success(text: "\"Common European Language\"\n")]]).broker())
    )
    let module = try #require(catalog.factories.first { $0.moduleID == "title.slug" }).build()
    let plan = try module.makePlan(input: ModuleInput(canonicalText: "/slug", payloadText: "The European languages are members of the same family."))
    let handle = try await module.start(plan: plan, capabilities: CapabilityBroker(declared: []), runID: "run-slug")
    guard case .succeeded(let moduleResult) = await handle.value() else {
        Issue.record("expected a slug result")
        return
    }
    #expect(moduleResult.fullText == "common-european-language")
    #expect(moduleResult.summary == "Slug ready")
    #expect(moduleResult.allowedActions == [.copy, .dismiss])
    #expect(moduleResult.modelRecord?.attempts.last?.outcome == .succeeded)
}
